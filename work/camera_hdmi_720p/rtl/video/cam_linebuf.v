/*******************************************************************************
 * camera_hdmi_720p — 摄像头行缓存（自研，M4）
 *
 * 作用：把 MIPI 解包出来的像素流（字节时钟域，103.5MHz，突发写入）缓存成整行，
 *       供 HDMI 侧（像素时钟域，75MHz）按 x 坐标逐点读出，实现灰度直通显示。
 *
 * 结构：双 bank（ping-pong）行缓存
 *   写侧（I_clk_wr = D-PHY 字节时钟）：raw10_unpack 每拍给一组 4 个 10bit 像素，
 *          在行首（I_wr_line_start = CSI-2 负载首拍）翻转 bank 并把写地址清零，
 *          行内每拍写一组。
 *   读侧（I_clk_rd = HDMI 像素域）：由 hdmi_timing 的 de/x/vs 驱动，
 *          地址 = x[11:2]（组号），字段 = x[1:0]（组内像素号）。
 *   切换：写侧在行尾（I_wr_line_end = CSI-2 负载末拍）把"本行所在的 bank"连同
 *          一个翻转标志送到读侧（2 级同步 + 边沿检测），读侧据此切 bank。
 *          ⇒ 读侧永远读「已完成的那一行」，不会读到正在写的行。
 *
 * 时延：读侧 BRAM 1 拍 + 输出寄存 1 拍 = 2 拍，de/vs 同步延迟 2 拍，与 data 对齐
 *       （与 test_pattern 的"data/de_o 同拍"约定一致，供 hdmi_tx 直连）。
 *
 * 灰度映射：亮度 = (RAW10 - 黑电平) 高 8 位，R=G=B 输出（去马赛克在 M6）。
 ******************************************************************************/
`timescale 1ns / 1ps

module cam_linebuf #(
    parameter H_ACTIVE    = 1280,
    parameter PX_W        = 10,
    parameter GRP         = 4,                       // 每地址存放的像素数
    parameter ENTRIES     = H_ACTIVE / GRP,          // 320
    parameter AW          = 9,                       // $clog2(320) = 9
    parameter BLACK_LEVEL = 10'd64                   // RAW10 黑电平（可调）
) (
    // ---------------- 写侧：字节时钟域 ----------------
    input  wire                I_clk_wr,
    input  wire                I_rst_n_wr,
    input  wire                I_wr_line_start,      // 本行负载首拍 → 翻 bank + 清零写地址
    input  wire                I_wr_line_end,        // 本行负载末拍 → 通知读侧可以切 bank
    input  wire                I_wr_grp_valid,       // 一组 4 像素有效（1 拍）
    input  wire [GRP*PX_W-1:0] I_wr_grp,             // {P3,P2,P1,P0}

    // ---------------- 读侧：HDMI 像素域 ----------------
    input  wire                I_clk_rd,
    input  wire                I_rst_n_rd,
    input  wire                I_rd_de,              // 来自 hdmi_timing
    input  wire [11:0]         I_rd_x,               // 0..1279
    input  wire                I_rd_vs,              // 来自 hdmi_timing

    output reg  [23:0]         O_rd_data,            // {R,G,B}，灰度
    output reg                 O_rd_de,
    output reg                 O_rd_vs,

    // ---------------- 诊断 ----------------
    output reg  [15:0]         O_line_cnt,           // 写侧收到的行数
    output reg  [15:0]         O_rd_switch_cnt       // 读侧切换过的行数
);

    // ================================================== 写侧
    reg                    wr_bank;
    reg  [AW-1:0]          wr_addr;
    reg  [GRP*PX_W-1:0]    mem0 [0:ENTRIES-1];
    reg  [GRP*PX_W-1:0]    mem1 [0:ENTRIES-1];

    reg                    wr_done_tgl;
    reg                    wr_bank_at_done;

    always @(posedge I_clk_wr) begin
        if (!I_rst_n_wr) begin
            wr_bank         <= 1'b0;
            wr_addr         <= {AW{1'b0}};
            wr_done_tgl     <= 1'b0;
            wr_bank_at_done <= 1'b0;
            O_line_cnt      <= 16'd0;
        end else begin
            if (I_wr_line_start) begin
                wr_bank <= ~wr_bank;                 // 本行写另一个 bank
                wr_addr <= {AW{1'b0}};
            end

            if (I_wr_grp_valid && (wr_addr < ENTRIES[AW-1:0])) begin
                if (wr_bank)
                    mem1[wr_addr] <= I_wr_grp;
                else
                    mem0[wr_addr] <= I_wr_grp;
                wr_addr <= wr_addr + 1'b1;
            end

            if (I_wr_line_end) begin
                wr_done_tgl     <= ~wr_done_tgl;
                wr_bank_at_done <= wr_bank;
                O_line_cnt      <= O_line_cnt + 1'b1;
            end
        end
    end

    // ================================================== 跨域：翻转标志 + bank
    // 两位信号都只在行首/行尾变化（间隔 20µs 级），2 级同步后一起采样，无需握手。
    reg [2:0] sync_tgl;
    reg [2:0] sync_bank;

    always @(posedge I_clk_rd) begin
        if (!I_rst_n_rd) begin
            sync_tgl  <= 3'd0;
            sync_bank <= 3'd0;
        end else begin
            sync_tgl  <= {sync_tgl[1:0],  wr_done_tgl};
            sync_bank <= {sync_bank[1:0], wr_bank_at_done};
        end
    end

    // ================================================== 读侧
    reg                   rd_bank;
    reg  [GRP*PX_W-1:0]   rd_q;
    reg  [11:0]           x_d1;
    reg                   de_d1;
    reg                   vs_d1;
    reg  [PX_W-1:0]       px_sel;
    wire [PX_W-1:0]       px_raw;
    reg  [7:0]            gray;

    // 组内字段选择（x[1:0]：0 → P0 … 3 → P3）
    integer i;
    always @* begin
        px_sel = {PX_W{1'b0}};
        for (i = 0; i < GRP; i = i + 1)
            if (x_d1[1:0] == i[1:0])
                px_sel = rd_q[i*PX_W +: PX_W];
    end

    // 黑电平扣除 + 10bit → 8bit
    always @* begin
        if (px_raw > BLACK_LEVEL)
            gray = (px_raw - BLACK_LEVEL) >> 2;
        else
            gray = 8'd0;
    end
    assign px_raw = px_sel;

    always @(posedge I_clk_rd) begin
        if (!I_rst_n_rd) begin
            rd_bank        <= 1'b0;
            rd_q           <= {GRP*PX_W{1'b0}};
            x_d1           <= 12'd0;
            de_d1          <= 1'b0;
            vs_d1          <= 1'b0;
            O_rd_data      <= 24'd0;
            O_rd_de        <= 1'b0;
            O_rd_vs        <= 1'b0;
            O_rd_switch_cnt<= 16'd0;
        end else begin
            // 同步后的"本行已写完"边沿 → 切到刚写完的 bank
            // 注意：边沿由 sync_tgl[2]^sync_tgl[1] 检测，此刻 sync_bank[1] 才是
            //       与边沿同级的「新」bank 值（sync_bank[2] 是上一拍前的旧值）。
            if (sync_tgl[2] ^ sync_tgl[1]) begin
                rd_bank         <= sync_bank[1];
                O_rd_switch_cnt <= O_rd_switch_cnt + 1'b1;
            end

            // 组读取（BRAM 1 拍），字段用上一拍的 x
            rd_q  <= rd_bank ? mem1[I_rd_x[11:2]] : mem0[I_rd_x[11:2]];
            x_d1  <= I_rd_x;

            // de/vs 延迟 1 拍，与 data 对齐
            de_d1 <= I_rd_de;
            vs_d1 <= I_rd_vs;

            O_rd_data <= {gray, gray, gray};
            O_rd_de   <= de_d1;      // 与 data 同拍：data 来自 x(t-1)，de 也必须延迟 1 拍
            O_rd_vs   <= vs_d1;
        end
    end

endmodule
