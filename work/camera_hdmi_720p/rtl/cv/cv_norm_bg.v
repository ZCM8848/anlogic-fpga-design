`timescale 1ns / 1ps
//=============================================================================
// cv_norm_bg.v — 光照归一化 + IIR 背景 + 阈值（1bit 前景掩膜）
//   对应 Python: Python/impl_hw/hw_ops.{illum_norm, iir_update, fg_mask}
//
//   为避免整帧缓存，背景/照度估计都放在 **1/16 降采样块域**（BW x BH），
//   逐像素时按块最近邻取值（impl_hw 用双线性，此处为省资源用最近邻）。
//
//   空间照度图 sp_mem: 本帧块均值(16x16)，读时为上一帧值 -> 1 帧滞后（可接受）
//     归一化: norm = I_y * 128 / max(sp,1)  （倒数 ROM + 乘法）
//   IIR 背景图 bg_mem: bg += (mean_norm - bg) >>> ALPHA_SH（一阶 IIR，取代 MOG2）
//     前景: mask = |norm - bg| > THRESH
//
//   存储: 2 块 3600x8bit BRAM（各约 2 个 ERAM20K），无整帧缓存。
//   流水: 3 级（读/归一化/比较），O_de 与 O_norm/O_mask 对齐。
//=============================================================================
module cv_norm_bg #(
    parameter IMG_W    = 1280,
    parameter BW       = 80,         // = IMG_W / 16
    parameter BH       = 45,         // = IMG_H / 16
    parameter NORM_TGT = 128,
    parameter ALPHA_SH = 5,          // IIR 步进 = 8/256 = 1/32
    parameter THRESH   = 26,
    parameter WARM     = 2           // 预热帧数：预热期内不出检测、背景直接载入块均值
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_de,
    input  wire        I_vs,
    input  wire [7:0]  I_y,
    output wire        O_de,
    output wire        O_vs,
    output wire [7:0]  O_norm,
    output wire        O_mask
);
    // ---------- 倒数 ROM：rec_rom[d] ≈ 65536/d ----------
    reg [15:0] rec_rom [0:255];
    integer ii;
    initial begin
        rec_rom[0] = 16'd0;
        for (ii = 1; ii < 256; ii = ii + 1)
            rec_rom[ii] = 16'd65536 / ii;
    end

    // ---------- x / y ----------
    reg [11:0] r_x, r_y;
    reg        r_vs_d;
    wire       vs_rise = I_vs & ~r_vs_d;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin r_x <= 0; r_y <= 0; r_vs_d <= 0; end
        else begin
            r_vs_d <= I_vs;
            if (vs_rise) begin r_x <= 0; r_y <= 0; end
            else if (I_de) begin
                if (r_x == IMG_W - 1) begin r_x <= 0; r_y <= r_y + 1'b1; end
                else r_x <= r_x + 1'b1;
            end
        end
    end

    wire [11:0] blk_addr = ({4'd0, r_y[11:4]} * 12'd80) + {4'd0, r_x[11:4]};
    wire        blk_end  = I_de & (r_x[3:0] == 4'hF) & (r_y[3:0] == 4'hF);

    // ---------- 两块背景 RAM（同步读）----------
    (* ram_style="block" *) reg [7:0] sp_mem [0:4095];
    (* ram_style="block" *) reg [7:0] bg_mem [0:4095];
    reg [7:0] rd_sp, rd_bg;
    always @(posedge I_clk) begin
        rd_sp <= sp_mem[blk_addr];
        rd_bg <= bg_mem[blk_addr];
    end

    // ---------- 空间块均值累加（写 sp_mem）----------
    reg  [15:0] acc_sp;
    reg         sp_we;  reg [11:0] sp_wa;  reg [7:0] sp_wd;
    wire [15:0] sp_sum  = acc_sp + {8'd0, I_y};
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin acc_sp <= 0; sp_we <= 0; sp_wa <= 0; sp_wd <= 0; end
        else begin
            sp_we <= 1'b0;
            if (I_de) begin
                if (blk_end) begin
                    sp_we <= 1'b1; sp_wa <= blk_addr; sp_wd <= sp_sum[15:8];
                    acc_sp <= 16'd0;
                end else begin
                    acc_sp <= sp_sum;
                end
            end
        end
    end
    always @(posedge I_clk) if (sp_we) sp_mem[sp_wa] <= sp_wd;

    // ---------- 流水：读数据 -> 归一化 -> 比较 ----------
    reg  [7:0] y_d1, norm_b, bg_b;
    reg  [1:0] r_de, r_vs;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin y_d1 <= 0; norm_b <= 0; bg_b <= 0; r_de <= 0; r_vs <= 0; end
        else begin
            r_de <= {r_de[0], I_de};
            r_vs <= {r_vs[0], I_vs};
            if (I_de) y_d1 <= I_y;          // 与 rd_sp 同拍对齐
            if (r_de[0]) begin              // 该拍 rd_sp/rd_bg/y_d1 对应当前像素
                norm_b <= w_norm;
                bg_b   <= rd_bg;
            end
        end
    end

    wire [15:0] w_recip = rec_rom[(rd_sp == 8'd0) ? 8'd1 : rd_sp];
    wire [23:0] w_prod  = {8'd0, y_d1} * w_recip;
    wire [14:0] w_nraw  = w_prod[23:9];                       // = y*128/den
    wire [7:0]  w_norm  = (w_nraw > 15'd255) ? 8'd255 : w_nraw[7:0];

    wire [8:0]  w_diff  = (norm_b > bg_b) ? (norm_b - bg_b) : (bg_b - norm_b);

    assign O_de   = r_de[1];
    assign O_vs   = r_vs[1];
    assign O_norm = norm_b;
    assign O_mask = w_warm ? 1'b0 : (w_diff > THRESH);

    // ---------- 预热计数器 ----------
    reg [3:0] r_frm;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) r_frm <= 4'd0;
        else if (vs_rise && r_frm != 4'hF) r_frm <= r_frm + 1'b1;
    end
    wire w_warm = (r_frm < WARM);

    // ---------- IIR 背景更新（延迟到归一化输出拍）----------
    reg         blk_end_d1, blk_end_d2;
    reg  [11:0] addr_d1, addr_d2;
    always @(posedge I_clk) begin
        blk_end_d1 <= blk_end;      blk_end_d2 <= blk_end_d1;
        addr_d1    <= blk_addr;     addr_d2    <= addr_d1;
    end

    reg  [15:0] acc_bg;
    reg         bg_we;  reg [11:0] bg_wa;  reg [7:0] bg_wd;
    wire [15:0] bg_sum  = acc_bg + {8'd0, norm_b};
    wire [7:0]  bg_mean = bg_sum[15:8];
    wire signed [8:0]  w_dbg  = $signed({1'b0, bg_mean}) - $signed({1'b0, bg_b});
    wire signed [8:0]  w_step = w_dbg >>> ALPHA_SH;
    wire signed [9:0]  w_nbg  = $signed({1'b0, bg_b}) + w_step;
    wire [7:0]  w_newbg = w_nbg[9] ? 8'd0 : (w_nbg[8] ? 8'd255 : w_nbg[7:0]);
    wire [7:0]  w_bgwr  = w_warm ? bg_mean : w_newbg;   // 预热期直接载入块均值

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin acc_bg <= 0; bg_we <= 0; bg_wa <= 0; bg_wd <= 0; end
        else begin
            bg_we <= 1'b0;
            if (r_de[1]) begin
                if (blk_end_d2) begin
                    bg_we <= 1'b1; bg_wa <= addr_d2; bg_wd <= w_bgwr;
                    acc_bg <= 16'd0;
                end else begin
                    acc_bg <= bg_sum;
                end
            end
        end
    end
    always @(posedge I_clk) if (bg_we) bg_mem[bg_wa] <= bg_wd;

endmodule
