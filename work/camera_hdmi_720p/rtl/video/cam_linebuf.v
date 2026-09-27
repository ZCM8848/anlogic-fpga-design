/*******************************************************************************
 * camera_hdmi_720p — 摄像头行缓存（自研，M4）
 *
 * 作用：把 MIPI 解包出来的像素流缓存成整行，供 HDMI 侧按 x 逐点读出（灰度直通）。
 *
 * v2（跨域结构加固，上板事故后重写）：
 *   M4 首版把行缓存 BRAM 写口直接挂在 D-PHY 恢复时钟（字节域）上，上板后整条
 *   MIPI 链路停摆：串口 LPA=1（传感器在发）但 RX=0（字节域从不推进）。对比 M3
 *   （当时该域只有触发器）和厂商 lab（字节域同样只有触发器，存储体一律在全局
 *   时钟域），判定写口挂恢复时钟是根因 —— 大容量存储会把恢复时钟推到全局时钟
 *   资源上，破坏 IP 内部 CDR/字节对齐。
 *
 *   v2 三段域结构：
 *     字节域（I_clk_wr = 恢复时钟）：只做「入队」——纯触发器实现的异步 FIFO
 *          （8 x 42bit）。行首/行尾作为独立条目与像素组**同序**穿过 FIFO
 *          （顺序错乱会翻错 bank）。该域内不出现任何大容量存储宏。
 *     缓冲域（I_clk_buf = 全局 100MHz）：FIFO 出队 → 写行缓存 BRAM 写口；
 *          行首翻 bank、行尾发「本行完成」翻转信号给像素域。
 *     像素域（I_clk_rd = HDMI 75MHz）：按 x 读 BRAM、按 x[1:0] 选像素、灰度映射。
 *
 *   流量核算：一行 320 组在 7.7us 内到达（≈41.4M 组/s，突发），缓冲域可吞
 *   100M 组/s，FIFO 占用长期 ≤2，深度 8 留 3 倍余量。
 *
 *   时延：读侧 BRAM 1 拍 + 输出寄存 1 拍 = 2 拍，de/vs 延迟 1 拍与 data 对齐
 *         （与 test_pattern「data/de_o 同拍」约定一致，供 hdmi_tx 直连）。
 *   灰度映射：亮度 = (RAW10 - 黑电平) >> 2，R=G=B 输出（去马赛克在 M6）。
 ******************************************************************************/
`timescale 1ns / 1ps

module cam_linebuf #(
    parameter H_ACTIVE    = 1280,
    parameter PX_W        = 10,
    parameter GRP         = 4,                       // 每地址存放的像素数
    parameter ENTRIES     = H_ACTIVE / GRP,          // 320
    parameter AW          = 9,                       // $clog2(320) = 9
    parameter BLACK_LEVEL = 10'd64,                  // RAW10 黑电平（可调）
    parameter FDEPTH      = 8                        // 跨域 FIFO 深度（2 的幂）
) (
    // ---------------- 字节域（MIPI 恢复时钟；只许触发器/查找表） ----------------
    input  wire                I_clk_wr,
    input  wire                I_rst_n_wr,
    input  wire                I_wr_line_start,      // 负载首拍 → 条目 K_START
    input  wire                I_wr_line_end,        // 负载末拍 → 条目 K_END
    input  wire                I_wr_grp_valid,       // 一组 4 像素有效（1 拍）
    input  wire [GRP*PX_W-1:0] I_wr_grp,             // {P3,P2,P1,P0}

    // ---------------- 缓冲域（全局 100MHz） ----------------
    input  wire                I_clk_buf,
    input  wire                I_rst_n_buf,

    // ---------------- 像素域（HDMI 75MHz） ----------------
    input  wire                I_clk_rd,
    input  wire                I_rst_n_rd,
    input  wire                I_rd_de,              // 来自 hdmi_timing
    input  wire [11:0]         I_rd_x,               // 0..1279
    input  wire                I_rd_vs,              // 来自 hdmi_timing

    output reg  [23:0]         O_rd_data,            // {R,G,B}，灰度
    output reg                 O_rd_de,
    output reg                 O_rd_vs,

    // ---------------- 诊断 ----------------
    output reg  [15:0]         O_line_cnt,           // 缓冲域完成的行数
    output reg  [15:0]         O_rd_switch_cnt       // 读侧切换过的行数
);

    localparam FA = 3;                               // FDEPTH = 8 → 地址 3 位
    localparam EW = GRP * PX_W;                      // 40
    localparam W  = EW + 3;                          // 条目 = {start, end, dvalid, data[39:0]}

    // ================================================== 字节域：入队
    // 纯触发器 FIFO（8 x 43bit）。条目自带标志位，一拍一条，天然保序：
    //   行首与数据同拍 → 同一条目 {start,dvalid}，缓冲域先翻 bank 再写第 0 字；
    //   行尾与数据同拍 → 同一条目 {end,dvalid}，缓冲域先写数据再报完成
    //   （否则每行最后一组 4 个像素会变成残影）。
    // 本域内禁止出现大容量存储宏（BRAM/EBR）：写口一旦落在恢复时钟上，工具会
    // 把恢复时钟提升为全局时钟资源，破坏 D-PHY 内部 CDR。
    reg  [W-1:0]  fifo [0:FDEPTH-1];
    reg  [FA:0]   wr_bin, wr_gray;                   // 多一位做回绕
    reg  [FA:0]   rd_gray_s1, rd_gray_s2;            // 读指针同步（缓冲域 → 字节域）
    reg  [FA:0]   rd_bin, rd_gray;                   // 缓冲域出队指针（在此先声明：字节域要同步它）

    function [FA:0] bin2gray (input [FA:0] b);
        bin2gray = b ^ (b >> 1);
    endfunction

    function [FA:0] gray2bin (input [FA:0] g);
        integer i;
        begin
            gray2bin[FA] = g[FA];
            for (i = FA - 1; i >= 0; i = i - 1)
                gray2bin[i] = gray2bin[i+1] ^ g[i];
        end
    endfunction

    wire [FA:0]   rd_bin_s  = gray2bin(rd_gray_s2);
    wire          fifo_full = (wr_bin[FA] != rd_bin_s[FA]) &&
                              (wr_bin[FA-1:0] == rd_bin_s[FA-1:0]);

    wire [W-1:0]  enq_d = {I_wr_line_start, I_wr_line_end, I_wr_grp_valid, I_wr_grp};
    wire          enq_v = I_wr_line_start | I_wr_line_end | I_wr_grp_valid;
    wire          enq_do= enq_v & ~fifo_full;

    always @(posedge I_clk_wr) begin
        if (!I_rst_n_wr) begin
            wr_bin     <= {FA+1{1'b0}};
            wr_gray    <= {FA+1{1'b0}};
            rd_gray_s1 <= {FA+1{1'b0}};
            rd_gray_s2 <= {FA+1{1'b0}};
        end else begin
            rd_gray_s1 <= rd_gray;
            rd_gray_s2 <= rd_gray_s1;

            // 入队（满则丢，正常不会发生：出队 100M/s ≫ 入队 41.4M/s）
            if (enq_do) begin
                fifo[wr_bin[FA-1:0]] <= enq_d;
                wr_bin  <= wr_bin + 1'b1;
                wr_gray <= bin2gray(wr_bin + 1'b1);
            end
        end
    end

    // ================================================== 缓冲域：出队 + 写
    reg  [W-1:0]        item;
    reg                 item_v;
    reg  [FA:0]         wr_gray_s1, wr_gray_s2;      // 写指针同步（字节域 → 缓冲域）
    reg  [GRP*PX_W-1:0] mem0 [0:ENTRIES-1];          // 双 bank 行缓存（写口=缓冲域）
    reg  [GRP*PX_W-1:0] mem1 [0:ENTRIES-1];          // （读口=像素域）
    reg                 wr_bank;
    reg                 wr_bank_c;                   // 行尾时刻的 bank，随完成信号跨到像素域
    reg  [AW-1:0]       wr_addr;
    reg                 done_tgl;                    // 「本行完整」翻转信号

    wire [FA:0] rd_bin_p1 = rd_bin + 1'b1;
    wire        fifo_ne   = (rd_gray != wr_gray_s2);
    wire        ev_start  = item_v &&  item[EW+2];
    wire        ev_end    = item_v &&  item[EW+1];
    wire        ev_dval   = item_v &&  item[EW];
    wire [EW-1:0] ev_data = item[EW-1:0];

    always @(posedge I_clk_buf) begin
        if (!I_rst_n_buf) begin
            item       <= {W{1'b0}};
            item_v     <= 1'b0;
            rd_bin     <= {FA+1{1'b0}};
            rd_gray    <= {FA+1{1'b0}};
            wr_gray_s1 <= {FA+1{1'b0}};
            wr_gray_s2 <= {FA+1{1'b0}};
            wr_bank    <= 1'b0;
            wr_bank_c  <= 1'b0;
            wr_addr    <= {AW{1'b0}};
            done_tgl   <= 1'b0;
            O_line_cnt <= 16'd0;
        end else begin
            wr_gray_s1 <= wr_gray;
            wr_gray_s2 <= wr_gray_s1;

            // 出队（寄存一拍）
            item   <= fifo[rd_bin[FA-1:0]];
            item_v <= fifo_ne;
            if (fifo_ne) begin
                rd_bin  <= rd_bin_p1;
                rd_gray <= bin2gray(rd_bin_p1);
            end

            // 条目处理，顺序固定：行首（翻 bank、清地址）→ 数据 → 行尾（报完成）
            // 同一条目里三者可同时有效（行首/行尾与最后/第一组数据同拍）。
            if (ev_start) begin
                wr_bank <= ~wr_bank;
                if (ev_dval) begin
                    if (~wr_bank) mem1[0] <= ev_data;   // 写「新 bank」的第 0 字
                    else          mem0[0] <= ev_data;
                    wr_addr <= {{(AW-1){1'b0}}, 1'b1};
                end else begin
                    wr_addr <= {AW{1'b0}};
                end
            end else if (ev_dval && (wr_addr < ENTRIES)) begin
                if (wr_bank) mem1[wr_addr] <= ev_data;
                else         mem0[wr_addr] <= ev_data;
                wr_addr <= wr_addr + 1'b1;
            end

            if (ev_end) begin
                done_tgl   <= ~done_tgl;
                wr_bank_c  <= ev_start ? ~wr_bank : wr_bank;   // 零长行时完成的是新 bank
                O_line_cnt <= O_line_cnt + 1'b1;
            end
        end
    end

    // ================================================== 像素域：读 + 灰度输出
    reg  [2:0]              sync_tgl, sync_bank;
    reg                     rd_bank;
    reg  [GRP*PX_W-1:0]     rd_q;
    reg  [11:0]             x_d1;
    reg                     de_d1, vs_d1;
    reg  [PX_W-1:0]         px_sel;
    wire [PX_W-1:0]         px_raw;
    reg  [7:0]              gray;
    integer                 i;

    always @(posedge I_clk_rd) begin
        if (!I_rst_n_rd) begin
            sync_tgl  <= 3'd0;
            sync_bank <= 3'd0;
        end else begin
            sync_tgl  <= {sync_tgl[1:0],  done_tgl};
            sync_bank <= {sync_bank[1:0], wr_bank_c};
        end
    end

    // 组内字段选择（x[1:0]：0 → P0 … 3 → P3）
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
            // 同步后的「本行已写完」边沿 → 切到刚写完的 bank
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
