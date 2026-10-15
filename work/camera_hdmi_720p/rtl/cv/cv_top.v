`timescale 1ns / 1ps
//=============================================================================
// cv_top.v — CV 像素级前端 + OSD 叠加（v2：CCL/跟踪/计数转 MCU）
// ============================================================
// 本模块只保留像素级实时部分：
//   1) Sobel 3x3 边缘检测（2 行缓存 BRAM）
//   2) 自适应阈值（min/max midpoint）+ 用户偏置（K3/K4 调）
//   3) run 提取 → 写 run_mem（双口 BRAM：A 口 pixel 写，B 口 ahb_clk 读）
//   4) min/max Y 累加（给 MCU 算自适应阈值）
//   5) OSD 叠加：读 I_overlay（8 项 bbox+ID，MCU 算）画绿框+ID；读 I_count 画 4 位 hex Count
//
// CCL / 形状筛选 / a-b 跟踪 / exit 计数 全部由 MCU 固件完成：
//   MCU 经 ahb_status_slave 的 RUN_IDX/RUN_DAT 间接读 run_mem，
//   软件做 CCL + 筛选 + 跟踪 + exit 计数，结果写 overlay 寄存器组 + count。
//
// run_mem 项（32bit）：{row_y[9:0], xs[10:0], xe[10:0]}
// overlay 项（64bit）：{valid, id[3:0], x0[11:0], y0[11:0], x1[11:0], y1[11:0], pad}
//=============================================================================
module cv_top #(
    parameter IMG_W            = 1280,
    parameter IMG_H            = 720,
    parameter [7:0]  BIN_THR   = 8'd91,
    parameter [10:0] EDGE_THR  = 11'd80,
    parameter         MASK_SRC = 1,        // 1=Sobel 边缘；0=亮阈值
    parameter         MAX_RUNS = 1024,
    parameter         MASK_VIEW= 1,        // 1=机器视角（mask 黑白）；0=叠原画
    parameter [11:0] FBOX_W   = 12'd2,
    parameter         MAX_OV   = 8
)(
    input  wire        I_clk,          // pixel 75MHz
    input  wire        I_rst_n,
    input  wire        I_cv_on,
    input  wire        I_thr_up,
    input  wire        I_thr_dn,
    input  wire        I_de,
    input  wire        I_vs,
    input  wire [23:0] I_data,

    // run_mem B 口（ahb_clk 域读，给 MCU）
    input  wire        I_ahb_clk,
    input  wire [9:0]  I_run_rd_addr,
    output reg  [31:0] O_run_rd_data,

    // overlay + count（来自 ahb_status_slave）
    input  wire [511:0] I_overlay,
    input  wire [15:0]  I_count,

    // meta（给 ahb_status_slave）
    output wire [10:0] O_run_cnt,
    output wire [7:0]  O_min_y,
    output wire [7:0]  O_max_y,

    // 视频输出
    output wire        O_de,
    output wire        O_vs,
    output wire [23:0] O_data,

    // 调试
    output wire        O_run_overflow,
    output wire [7:0]  O_bin_thr
);

    // ---------- x/y ----------
    reg [11:0] r_x, r_y; reg r_vs_d;
    wire vs_rise = I_vs & ~r_vs_d;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin r_x<=0; r_y<=0; r_vs_d<=0; end
        else begin
            r_vs_d<=I_vs;
            if (vs_rise) begin r_x<=0; r_y<=0; end
            else if (I_de) begin
                if (r_x==IMG_W-1) begin r_x<=0; r_y<=r_y+1; end else r_x<=r_x+1;
            end
        end
    end

    // ---------- 亮度 ----------
    wire [7:0] w_y = {2'b0,I_data[23:18]} + {1'b0,I_data[15:9]} + {2'b0,I_data[7:2]};

    // ---------- 自适应阈值 + 用户偏置 ----------
    reg [7:0] r_user_off;
    reg [7:0] r_min_y, r_max_y;       // 本帧 min/max Y（run extractor 累加）
    // midpoint 由上帧 min/max 算
    wire [8:0] mid_plus = {1'b0, r_min_y} + {1'b0, r_max_y};
    wire [7:0] r_otsu_thr = mid_plus[8:1];   // (min+max)/2
    wire [7:0] base_thr = MASK_SRC ? EDGE_THR[7:0] : r_otsu_thr;
    wire [8:0] thr_plus = {1'b0,base_thr} + {1'b0,r_user_off};
    wire [7:0] eff_thr  = (thr_plus>9'd255) ? 8'd255 : (thr_plus[8] ? 8'd0 : thr_plus[7:0]);

    // ---------- Sobel 3x3（2 行缓存 BRAM，async read，仿 edge_detect_96）----------
    (* ram_style="block" *) reg [7:0] sob_l1 [0:IMG_W-1];
    (* ram_style="block" *) reg [7:0] sob_l2 [0:IMG_W-1];
    wire [7:0] mid_word = sob_l1[r_x];
    wire [7:0] top_word = sob_l2[r_x];
    reg [7:0] top_p2, top_p1, mid_p2, mid_p1, bot_p2, bot_p1;
    wire signed [13:0] gx = $signed({5'b0,top_p2}) + ($signed({5'b0,top_p1})<<<1) + $signed({5'b0,top_word})
                         - $signed({5'b0,bot_p2}) - ($signed({5'b0,bot_p1})<<<1) - $signed({5'b0,w_y});
    wire signed [13:0] gy = $signed({5'b0,top_p2}) + ($signed({5'b0,mid_p2})<<<1) + $signed({5'b0,bot_p2})
                         - $signed({5'b0,top_word}) - ($signed({5'b0,mid_word})<<<1) - $signed({5'b0,w_y});
    wire [13:0] abs_gx = gx[13] ? (~gx + 1) : gx;
    wire [13:0] abs_gy = gy[13] ? (~gy + 1) : gy;
    wire [14:0] w_sobel_mag = {1'b0,abs_gx} + {1'b0,abs_gy};
    wire        w_edge_mask = (r_y >= 12'd2) && (r_x >= 12'd2) && (w_sobel_mag > {4'b0, eff_thr});
    wire        w_mask = MASK_SRC ? w_edge_mask : (w_y > eff_thr);

    always @(posedge I_clk) begin
        if (I_de) begin
            sob_l1[r_x] <= w_y;
            sob_l2[r_x] <= mid_word;
            top_p2 <= top_p1; top_p1 <= top_word;
            mid_p2 <= mid_p1; mid_p1 <= mid_word;
            bot_p2 <= bot_p1; bot_p1 <= w_y;
        end
    end

    // ---------- run_mem（双口 BRAM：A 口 pixel 写，B 口 ahb 读）----------
    // 项 = {row_y[9:0], xs[10:0], xe[10:0]} = 32bit
    (* ram_style="block" *) reg [31:0] run_mem [0:MAX_RUNS-1];

    // A 口写（pixel 域）
    reg [10:0] r_run_wr, r_run_cnt;
    reg        r_run_act, r_run_overflow, r_de_d;
    reg [10:0] r_run_xs, r_run_xe;
    wire       row_last = I_de & (r_x==IMG_W-1);

    // min/max Y 在自适应阈值段声明（run extractor 累加）

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r_run_wr<=0; r_run_cnt<=0; r_run_act<=0; r_run_xs<=0; r_run_xe<=0;
            r_run_overflow<=0; r_de_d<=0; r_user_off<=0;
            r_min_y<=8'hFF; r_max_y<=8'd0;
        end else begin
            r_de_d<=I_de;
            if (I_thr_up && r_user_off!=8'h7F) r_user_off<=r_user_off+8'd1;
            else if (I_thr_dn && r_user_off!=8'h80) r_user_off<=r_user_off-8'd1;
            if (vs_rise) begin
                if (r_run_act && r_run_wr<MAX_RUNS) begin
                    run_mem[r_run_wr]<={r_y[9:0], r_run_xs[10:0], r_run_xe[10:0]};
                    r_run_wr<=r_run_wr+1;
                end
                r_run_cnt<=r_run_wr; r_run_wr<=0; r_run_act<=0; r_run_overflow<=0;
                r_min_y<=8'hFF; r_max_y<=8'd0;
            end else if (I_cv_on && I_de) begin
                if (w_y < r_min_y) r_min_y <= w_y;
                if (w_y > r_max_y) r_max_y <= w_y;
                if (row_last && r_run_act) begin
                    r_run_xe<=r_x;
                    if (r_run_wr<MAX_RUNS) begin
                        run_mem[r_run_wr]<={r_y[9:0], r_run_xs[10:0], r_run_xe[10:0]};
                        r_run_wr<=r_run_wr+1;
                    end else r_run_overflow<=1;
                    r_run_act<=0;
                end else begin
                    if (w_mask) begin
                        if (!r_run_act) begin r_run_act<=1; r_run_xs<=r_x; r_run_xe<=r_x; end
                        else r_run_xe<=r_x;
                    end else if (r_run_act) begin
                        if (r_run_wr<MAX_RUNS) begin
                            run_mem[r_run_wr]<={r_y[9:0], r_run_xs[10:0], r_run_xe[10:0]};
                            r_run_wr<=r_run_wr+1;
                        end else r_run_overflow<=1;
                        r_run_act<=0;
                    end
                end
            end
        end
    end

    // B 口读（ahb_clk 域，给 MCU 间接读）
    always @(posedge I_ahb_clk) begin
        O_run_rd_data <= run_mem[I_run_rd_addr];
    end

    assign O_run_cnt      = r_run_cnt;
    assign O_min_y        = r_min_y;
    assign O_max_y        = r_max_y;
    assign O_run_overflow = r_run_overflow;
    assign O_bin_thr      = eff_thr;

    //=============================================================================
    // OSD 叠加：绿框 + ID 字模（来自 I_overlay）；Count（来自 I_count，4 位 hex）
    //=============================================================================

    // 0-F 字模（5x7），复用原 f_digit
    function [4:0] f_digit;
        input [3:0] id; input [2:0] row;
        begin
            case(id)
                4'd0: case(row) 0:f_digit=5'b01110;1:f_digit=5'b10001;2:f_digit=5'b10011;3:f_digit=5'b10101;4:f_digit=5'b11001;5:f_digit=5'b10001;6:f_digit=5'b01110;default:f_digit=0;endcase
                4'd1: case(row) 0:f_digit=5'b00100;1:f_digit=5'b01100;2:f_digit=5'b00100;3:f_digit=5'b00100;4:f_digit=5'b00100;5:f_digit=5'b00100;6:f_digit=5'b01110;default:f_digit=0;endcase
                4'd2: case(row) 0:f_digit=5'b01110;1:f_digit=5'b10001;2:f_digit=5'b00001;3:f_digit=5'b00010;4:f_digit=5'b00100;5:f_digit=5'b01000;6:f_digit=5'b11111;default:f_digit=0;endcase
                4'd3: case(row) 0:f_digit=5'b11110;1:f_digit=5'b00001;2:f_digit=5'b00001;3:f_digit=5'b01110;4:f_digit=5'b00001;5:f_digit=5'b00001;6:f_digit=5'b11110;default:f_digit=0;endcase
                4'd4: case(row) 0:f_digit=5'b00010;1:f_digit=5'b00110;2:f_digit=5'b01010;3:f_digit=5'b10010;4:f_digit=5'b11111;5:f_digit=5'b00010;6:f_digit=5'b00010;default:f_digit=0;endcase
                4'd5: case(row) 0:f_digit=5'b11111;1:f_digit=5'b10000;2:f_digit=5'b11110;3:f_digit=5'b00001;4:f_digit=5'b00001;5:f_digit=5'b10001;6:f_digit=5'b01110;default:f_digit=0;endcase
                4'd6: case(row) 0:f_digit=5'b00110;1:f_digit=5'b01000;2:f_digit=5'b10000;3:f_digit=5'b11110;4:f_digit=5'b10001;5:f_digit=5'b10001;6:f_digit=5'b01110;default:f_digit=0;endcase
                4'd7: case(row) 0:f_digit=5'b11111;1:f_digit=5'b00001;2:f_digit=5'b00010;3:f_digit=5'b00100;4:f_digit=5'b01000;5:f_digit=5'b01000;6:f_digit=5'b01000;default:f_digit=0;endcase
                4'd8: case(row) 0:f_digit=5'b01110;1:f_digit=5'b10001;2:f_digit=5'b10001;3:f_digit=5'b01110;4:f_digit=5'b10001;5:f_digit=5'b10001;6:f_digit=5'b01110;default:f_digit=0;endcase
                4'd9: case(row) 0:f_digit=5'b01110;1:f_digit=5'b10001;2:f_digit=5'b10001;3:f_digit=5'b01111;4:f_digit=5'b00001;5:f_digit=5'b00010;6:f_digit=5'b11100;default:f_digit=0;endcase
                4'ha: case(row) 0:f_digit=5'b01110;1:f_digit=5'b10001;2:f_digit=5'b10001;3:f_digit=5'b11111;4:f_digit=5'b10001;5:f_digit=5'b10001;6:f_digit=5'b10001;default:f_digit=0;endcase
                4'hb: case(row) 0:f_digit=5'b11110;1:f_digit=5'b10001;2:f_digit=5'b10001;3:f_digit=5'b11110;4:f_digit=5'b10001;5:f_digit=5'b10001;6:f_digit=5'b11110;default:f_digit=0;endcase
                4'hc: case(row) 0:f_digit=5'b01110;1:f_digit=5'b10001;2:f_digit=5'b10000;3:f_digit=5'b10000;4:f_digit=5'b10000;5:f_digit=5'b10001;6:f_digit=5'b01110;default:f_digit=0;endcase
                4'hd: case(row) 0:f_digit=5'b11110;1:f_digit=5'b10001;2:f_digit=5'b10001;3:f_digit=5'b10001;4:f_digit=5'b10001;5:f_digit=5'b10001;6:f_digit=5'b11110;default:f_digit=0;endcase
                4'he: case(row) 0:f_digit=5'b11111;1:f_digit=5'b10000;2:f_digit=5'b10000;3:f_digit=5'b11110;4:f_digit=5'b10000;5:f_digit=5'b10000;6:f_digit=5'b11111;default:f_digit=0;endcase
                4'hf: case(row) 0:f_digit=5'b11111;1:f_digit=5'b10000;2:f_digit=5'b10000;3:f_digit=5'b11110;4:f_digit=5'b10000;5:f_digit=5'b10000;6:f_digit=5'b10000;default:f_digit=0;endcase
                default: f_digit=0;
            endcase
        end
    endfunction

    // overlay 项解析（8 项，每项 64bit）
    // 字段：[63]valid [62:59]id [58:47]x0 [46:35]y0 [31:20]x1 [19:8]y1
    wire [63:0] ov0 = I_overlay[63:0];
    wire [63:0] ov1 = I_overlay[127:64];
    wire [63:0] ov2 = I_overlay[191:128];
    wire [63:0] ov3 = I_overlay[255:192];
    wire [63:0] ov4 = I_overlay[319:256];
    wire [63:0] ov5 = I_overlay[383:320];
    wire [63:0] ov6 = I_overlay[447:384];
    wire [63:0] ov7 = I_overlay[511:448];

    // Count 显示：左上 (24,56)，4 位 hex，每位 8px（5 字模 + 3 间隙），共 32px
    localparam [11:0] CNT_X = 12'd24;
    localparam [11:0] CNT_Y = 12'd56;
    localparam [11:0] CNT_W = 12'd32;

    integer oi;
    reg r_border, r_id_digit, r_cnt_digit;
    reg [4:0] dg_bits;
    reg [11:0] dg_row, dg_col;
    reg [3:0]  cnt_nib;
    reg [1:0]  cnt_idx;
    always @(*) begin
        r_border=1'b0; r_id_digit=1'b0; r_cnt_digit=1'b0;
        // ---- overlay 绿框 + ID ----
        // 8 项展开（避免循环内数组变址导致的组合复杂度）
        if (ov0[63]) begin
            if ((((r_x>=ov0[58:47])&&(r_x<ov0[58:47]+FBOX_W)) || ((r_x<=ov0[31:20])&&(r_x>ov0[31:20]-FBOX_W))) &&
                (r_y>=ov0[46:35])&&(r_y<=ov0[19:8])) r_border=1;
            if ((((r_y>=ov0[46:35])&&(r_y<ov0[46:35]+FBOX_W)) || ((r_y<=ov0[19:8])&&(r_y>ov0[19:8]-FBOX_W))) &&
                (r_x>=ov0[58:47])&&(r_x<=ov0[31:20])) r_border=1;
            if (r_x>=ov0[58:47] && r_x<ov0[58:47]+5 && r_y>=ov0[46:35] && r_y<ov0[46:35]+7) begin
                dg_row=r_y-ov0[46:35]; dg_col=r_x-ov0[58:47];
                dg_bits=f_digit(ov0[62:59], dg_row[2:0]);
                if (dg_bits[4-dg_col[2:0]]) r_id_digit=1;
            end
        end
        if (ov1[63]) begin
            if ((((r_x>=ov1[58:47])&&(r_x<ov1[58:47]+FBOX_W)) || ((r_x<=ov1[31:20])&&(r_x>ov1[31:20]-FBOX_W))) &&
                (r_y>=ov1[46:35])&&(r_y<=ov1[19:8])) r_border=1;
            if ((((r_y>=ov1[46:35])&&(r_y<ov1[46:35]+FBOX_W)) || ((r_y<=ov1[19:8])&&(r_y>ov1[19:8]-FBOX_W))) &&
                (r_x>=ov1[58:47])&&(r_x<=ov1[31:20])) r_border=1;
            if (r_x>=ov1[58:47] && r_x<ov1[58:47]+5 && r_y>=ov1[46:35] && r_y<ov1[46:35]+7) begin
                dg_row=r_y-ov1[46:35]; dg_col=r_x-ov1[58:47];
                dg_bits=f_digit(ov1[62:59], dg_row[2:0]);
                if (dg_bits[4-dg_col[2:0]]) r_id_digit=1;
            end
        end
        if (ov2[63]) begin
            if ((((r_x>=ov2[58:47])&&(r_x<ov2[58:47]+FBOX_W)) || ((r_x<=ov2[31:20])&&(r_x>ov2[31:20]-FBOX_W))) &&
                (r_y>=ov2[46:35])&&(r_y<=ov2[19:8])) r_border=1;
            if ((((r_y>=ov2[46:35])&&(r_y<ov2[46:35]+FBOX_W)) || ((r_y<=ov2[19:8])&&(r_y>ov2[19:8]-FBOX_W))) &&
                (r_x>=ov2[58:47])&&(r_x<=ov2[31:20])) r_border=1;
            if (r_x>=ov2[58:47] && r_x<ov2[58:47]+5 && r_y>=ov2[46:35] && r_y<ov2[46:35]+7) begin
                dg_row=r_y-ov2[46:35]; dg_col=r_x-ov2[58:47];
                dg_bits=f_digit(ov2[62:59], dg_row[2:0]);
                if (dg_bits[4-dg_col[2:0]]) r_id_digit=1;
            end
        end
        if (ov3[63]) begin
            if ((((r_x>=ov3[58:47])&&(r_x<ov3[58:47]+FBOX_W)) || ((r_x<=ov3[31:20])&&(r_x>ov3[31:20]-FBOX_W))) &&
                (r_y>=ov3[46:35])&&(r_y<=ov3[19:8])) r_border=1;
            if ((((r_y>=ov3[46:35])&&(r_y<ov3[46:35]+FBOX_W)) || ((r_y<=ov3[19:8])&&(r_y>ov3[19:8]-FBOX_W))) &&
                (r_x>=ov3[58:47])&&(r_x<=ov3[31:20])) r_border=1;
            if (r_x>=ov3[58:47] && r_x<ov3[58:47]+5 && r_y>=ov3[46:35] && r_y<ov3[46:35]+7) begin
                dg_row=r_y-ov3[46:35]; dg_col=r_x-ov3[58:47];
                dg_bits=f_digit(ov3[62:59], dg_row[2:0]);
                if (dg_bits[4-dg_col[2:0]]) r_id_digit=1;
            end
        end
        if (ov4[63]) begin
            if ((((r_x>=ov4[58:47])&&(r_x<ov4[58:47]+FBOX_W)) || ((r_x<=ov4[31:20])&&(r_x>ov4[31:20]-FBOX_W))) &&
                (r_y>=ov4[46:35])&&(r_y<=ov4[19:8])) r_border=1;
            if ((((r_y>=ov4[46:35])&&(r_y<ov4[46:35]+FBOX_W)) || ((r_y<=ov4[19:8])&&(r_y>ov4[19:8]-FBOX_W))) &&
                (r_x>=ov4[58:47])&&(r_x<=ov4[31:20])) r_border=1;
            if (r_x>=ov4[58:47] && r_x<ov4[58:47]+5 && r_y>=ov4[46:35] && r_y<ov4[46:35]+7) begin
                dg_row=r_y-ov4[46:35]; dg_col=r_x-ov4[58:47];
                dg_bits=f_digit(ov4[62:59], dg_row[2:0]);
                if (dg_bits[4-dg_col[2:0]]) r_id_digit=1;
            end
        end
        if (ov5[63]) begin
            if ((((r_x>=ov5[58:47])&&(r_x<ov5[58:47]+FBOX_W)) || ((r_x<=ov5[31:20])&&(r_x>ov5[31:20]-FBOX_W))) &&
                (r_y>=ov5[46:35])&&(r_y<=ov5[19:8])) r_border=1;
            if ((((r_y>=ov5[46:35])&&(r_y<ov5[46:35]+FBOX_W)) || ((r_y<=ov5[19:8])&&(r_y>ov5[19:8]-FBOX_W))) &&
                (r_x>=ov5[58:47])&&(r_x<=ov5[31:20])) r_border=1;
            if (r_x>=ov5[58:47] && r_x<ov5[58:47]+5 && r_y>=ov5[46:35] && r_y<ov5[46:35]+7) begin
                dg_row=r_y-ov5[46:35]; dg_col=r_x-ov5[58:47];
                dg_bits=f_digit(ov5[62:59], dg_row[2:0]);
                if (dg_bits[4-dg_col[2:0]]) r_id_digit=1;
            end
        end
        if (ov6[63]) begin
            if ((((r_x>=ov6[58:47])&&(r_x<ov6[58:47]+FBOX_W)) || ((r_x<=ov6[31:20])&&(r_x>ov6[31:20]-FBOX_W))) &&
                (r_y>=ov6[46:35])&&(r_y<=ov6[19:8])) r_border=1;
            if ((((r_y>=ov6[46:35])&&(r_y<ov6[46:35]+FBOX_W)) || ((r_y<=ov6[19:8])&&(r_y>ov6[19:8]-FBOX_W))) &&
                (r_x>=ov6[58:47])&&(r_x<=ov6[31:20])) r_border=1;
            if (r_x>=ov6[58:47] && r_x<ov6[58:47]+5 && r_y>=ov6[46:35] && r_y<ov6[46:35]+7) begin
                dg_row=r_y-ov6[46:35]; dg_col=r_x-ov6[58:47];
                dg_bits=f_digit(ov6[62:59], dg_row[2:0]);
                if (dg_bits[4-dg_col[2:0]]) r_id_digit=1;
            end
        end
        if (ov7[63]) begin
            if ((((r_x>=ov7[58:47])&&(r_x<ov7[58:47]+FBOX_W)) || ((r_x<=ov7[31:20])&&(r_x>ov7[31:20]-FBOX_W))) &&
                (r_y>=ov7[46:35])&&(r_y<=ov7[19:8])) r_border=1;
            if ((((r_y>=ov7[46:35])&&(r_y<ov7[46:35]+FBOX_W)) || ((r_y<=ov7[19:8])&&(r_y>ov7[19:8]-FBOX_W))) &&
                (r_x>=ov7[58:47])&&(r_x<=ov7[31:20])) r_border=1;
            if (r_x>=ov7[58:47] && r_x<ov7[58:47]+5 && r_y>=ov7[46:35] && r_y<ov7[46:35]+7) begin
                dg_row=r_y-ov7[46:35]; dg_col=r_x-ov7[58:47];
                dg_bits=f_digit(ov7[62:59], dg_row[2:0]);
                if (dg_bits[4-dg_col[2:0]]) r_id_digit=1;
            end
        end
        // ---- Count（4 位 hex，每位 8px）----
        if (r_x>=CNT_X && r_x<CNT_X+CNT_W && r_y>=CNT_Y && r_y<CNT_Y+7) begin
            dg_row = r_y - CNT_Y;
            dg_col = r_x - CNT_X;          // 0..31
            cnt_idx = dg_col[4:3];         // 0..3（每 8px 一位）
            case (cnt_idx)
                2'd0: cnt_nib = I_count[15:12];
                2'd1: cnt_nib = I_count[11:8];
                2'd2: cnt_nib = I_count[7:4];
                2'd3: cnt_nib = I_count[3:0];
                default: cnt_nib = 4'h0;
            endcase
            if (dg_col[2:0] < 5) begin     // 位内 col 0-4 画字模，5-7 间隙
                dg_bits = f_digit(cnt_nib, dg_row[2:0]);
                if (dg_bits[4 - dg_col[2:0]]) r_cnt_digit=1;
            end
        end
    end

    wire [23:0] cv_base = (MASK_VIEW!=0) ? (w_mask ? 24'hFFFFFF : 24'h000000) : I_data;
    assign O_de=I_de; assign O_vs=I_vs;
    // 优先级：Count 字模 > ID 字模 > 绿框边 > 机器视角/原画
    assign O_data = (I_cv_on && I_de) ? (r_cnt_digit ? 24'hFFFFFF :
                                         (r_id_digit ? 24'hFFFFFF :
                                          (r_border ? 24'h00FF00 : cv_base))) : I_data;

endmodule
