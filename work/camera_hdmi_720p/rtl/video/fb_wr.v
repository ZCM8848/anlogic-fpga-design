/*******************************************************************************
 * camera_hdmi_720p — DDR 帧缓存写引擎（自研，M5-②）
 *
 * 数据通路：RAW10 组（字节域）→ 异步 FIFO(8×44) → 用户域打包 128bit 字
 *          （16 像素/字，字节序 = 像素序）→ 行缓冲乒乓(2×128×128) →
 *          排空引擎逐字写入 DDR（经 ddr_arb）。
 *
 * 关键设计（M5-② 计划）：
 *   · 字节域（D-PHY 恢复时钟）只做入队 —— 纯触发器 FIFO，条目
 *     {fs, fe, line_start, grp_valid, data[39:0]} 一拍一条，天然保序。
 *     该域内不出现大容量存储（M4 教训：写口挂恢复时钟会破坏 D-PHY CDR）。
 *   · 用户域打包：每 4 组（16 像素）拼成一个 128bit 字。移位方式：
 *     每处理一组右移 32bit：w <= {g3,g2,g1,g0, w[127:32]}，
 *     16 个像素落定后 像素 n 恰在 byte n（显示侧按 x[3:0] 选字节即得像素）。
 *   · 行缓冲乒乓：pack_tgl/drain_tgl 双相握手。打包第 L 行前要求
 *     bank(L&1) 上一轮（第 L-2 行）已排空；否则冻结出队等排空
 *     （DDR 短暂忙容忍窗口 ≈ 一整行时间；超时由帧完整性核对记 ER）。
 *     行地址在行首（st）锁存：line_addr[bank] = I_wr_base + line*640。
 *   · 帧完整性：在 st / fe / fs 三个事件点核对
 *     line_cnt==720 && pack_ptr==80 && grp_cnt==320 && !bad_latch；
 *     不满足 → O_frame_bad（fb_ctrl 计 ER），不发 O_frame_done（帧不上屏）。
 *
 * 地址布局（2 字节单位，见 docs/plan.md 与 IPUG035 表 3-5）：
 *   一帧 460800(0x70800)；行步长 640；行 y、字 k 的地址 = base + y*640 + k*8。
 *   基址三缓冲由 fb_ctrl 提供（0 / 0x80000 / 0x100000）。
 ******************************************************************************/
`timescale 1ns / 1ps

module fb_wr #(
    parameter FDEPTH = 8,          // 跨域 FIFO 深度（2 的幂）
    parameter FA     = 3,          // FIFO 地址位数
    parameter PROBE_OVL = 1'b0     // 【M5-② 诊断 v1】打包坐标白框探针（定位后置 0）
) (
    // ---------------- 字节域（MIPI 恢复时钟）----------------
    input  wire         I_clk_b,
    input  wire         I_rst_n_b,
    input  wire         I_fs,          // FS 短包（帧开始）
    input  wire         I_fe,          // FE 短包（帧结束）
    input  wire         I_line_start,  // 行包负载首拍
    input  wire         I_grp_valid,   // RAW10 像素组有效（每拍 4 像素）
    input  wire [39:0]  I_grp,         // {P3,P2,P1,P0}

    // ---------------- 用户域（S_ddr_clk = dhi_clk 66.67MHz）----------------
    input  wire         I_clk_d,
    input  wire         I_rst_n_d,
    input  wire [24:0]  I_wr_base,     // 当前写帧基址（2 字节单位）

    output wire         O_frame_start, // 组合脉冲：fs 处理当拍（顶层转 fb_ctrl）
    output wire         O_frame_done,  // 1 拍脉冲：一帧完整收齐
    output wire         O_frame_bad,   // 1 拍脉冲：帧异常（不完整/行数错）

    // ---- 写请求（→ ddr_arb）----
    output wire         O_wr_req,
    output wire [24:0]  O_wr_addr,
    output wire [127:0] O_wr_data,
    input  wire         I_wr_gnt
);

    localparam EW = 40;                // 组数据宽
    localparam W  = EW + 4;            // 条目 = {fs, fe, st, dv, data[39:0]}

    // ---------------- 函数 ----------------
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

    // 灰度映射：亮度 = (RAW10 - 黑电平) >> 2（与 M4 一致；去马赛克在 M6）
    function [7:0] gray8 (input [9:0] p);
        reg [9:0] t10;
        begin
            t10   = (p > 10'd64) ? (p - 10'd64) : 10'd0;
            gray8 = t10[9:2];
        end
    endfunction

    // ================================================== 字节域：入队
    reg  [W-1:0]  fifo [0:FDEPTH-1];
    reg  [FA:0]   wr_bin, wr_gray;
    reg  [FA:0]   rd_gray_s1, rd_gray_s2;      // 读指针同步（用户域 → 字节域）
    reg  [FA:0]   rd_bin, rd_gray;             // 用户域出队指针（先声明：字节域要同步它）

    wire [FA:0]   rd_bin_s  = gray2bin(rd_gray_s2);
    wire          fifo_full = (wr_bin[FA] != rd_bin_s[FA]) &&
                              (wr_bin[FA-1:0] == rd_bin_s[FA-1:0]);

    wire [W-1:0]  enq_d = {I_fs, I_fe, I_line_start, I_grp_valid, I_grp};
    wire          enq_v = I_fs | I_fe | I_line_start | I_grp_valid;
    wire          enq_do= enq_v & ~fifo_full;   // 满则丢（正常不会发生；
                                                // 丢失由用户域 grp_cnt 核对记 ER）

    always @(posedge I_clk_b) begin
        if (!I_rst_n_b) begin
            wr_bin     <= {FA+1{1'b0}};
            wr_gray    <= {FA+1{1'b0}};
            rd_gray_s1 <= {FA+1{1'b0}};
            rd_gray_s2 <= {FA+1{1'b0}};
        end else begin
            rd_gray_s1 <= rd_gray;
            rd_gray_s2 <= rd_gray_s1;
            if (enq_do) begin
                fifo[wr_bin[FA-1:0]] <= enq_d;
                wr_bin  <= wr_bin + 1'b1;
                wr_gray <= bin2gray(wr_bin + 1'b1);
            end
        end
    end

    // ================================================== 用户域：打包 + 排空
    reg  [W-1:0]  item;
    reg           item_v;
    reg  [FA:0]   wr_gray_s1, wr_gray_s2;      // 写指针同步（字节域 → 用户域）

    // 帧/行状态
    reg  [9:0]    S_line_cnt;      // 已开始的行数（0..720）
    reg           S_cur_slot;      // 当前行所在行缓冲 bank
    reg  [6:0]    S_pack_ptr;      // 行内已完成字数（0..80）
    reg  [8:0]    S_grp_cnt;       // 行内组数（0..320）
    reg  [1:0]    S_wcnt;          // 字内组计数（0..3）
    reg  [127:0]  S_word_reg;      // 字组装移位寄存器
    reg           S_bad_latch;     // 本帧已有行异常
    reg           S_done_p;        // 帧完成脉冲
    reg           S_bad_p;         // 帧异常脉冲

    // 行地址锁存（按 bank）与行缓冲
    reg  [24:0]   S_line_addr0, S_line_addr1;
    reg           S_ptgl0, S_ptgl1;            // 打包完成翻转
    reg           S_dtgl0, S_dtgl1;            // 排空完成翻转
    reg  [127:0]  S_rb0 [0:127];
    reg  [127:0]  S_rb1 [0:127];

    // 排空引擎
    reg  [1:0]    S_dr_st;         // 0=IDLE, 1=RD, 2=REQ
    reg           S_dr_slot;
    reg  [6:0]    S_dr_ptr;
    reg  [127:0]  S_dr_data;

    wire          fifo_ne   = (rd_gray != wr_gray_s2);
    wire          S_ev_fs   = item_v && item[W-1];
    wire          S_ev_fe   = item_v && item[W-2];
    wire          S_ev_st   = item_v && item[W-3];
    wire          S_ev_dv   = item_v && item[W-4];
    wire [39:0]   S_ev_grp = item[EW-1:0];

    // 行缓冲占用：pack_tgl != drain_tgl → 有未排空的行
    wire          S_pend0 = (S_ptgl0 != S_dtgl0);
    wire          S_pend1 = (S_ptgl1 != S_dtgl1);
    wire          S_slot_free = S_line_cnt[0] ? (S_ptgl1 == S_dtgl1)
                                              : (S_ptgl0 == S_dtgl0);
    wire          S_frz = S_ev_st && !S_slot_free;   // 目标 bank 未腾空：冻结出队
    wire          S_pop = item_v && !S_frz;

    // 帧完整性（st / fe / fs 共用；用 >= 判据：多出的组/字不影响成帧，缺才算异常）
    wire          S_frame_ok = (S_line_cnt == 10'd720) && (S_pack_ptr >= 7'd80) &&
                               (S_grp_cnt >= 9'd320) && !S_bad_latch;

    // 行地址：line*640 = line*512 + line*128（免乘法器）
    wire [24:0]   S_line_off  = {6'b0, S_line_cnt, 9'b0} + {8'b0, S_line_cnt, 7'b0};
    wire [24:0]   S_line_base = I_wr_base + S_line_off;

    // 字组装（右移 32bit/组；行首组从零起）
    // 【M5-② 诊断 v1】打包坐标系 8 像素白框（PROBE_OVL=1 时）：
    //   位置全部用打包引擎自己的计数生成——x = grp_cnt*4 + j，y = line_cnt - 1。
    //   照片里白框若贴屏幕边缘 → 横向错位在「打包之前」（字节域/传感器侧）；
    //   白框自己偏移 → 错位在「打包之后」（行缓冲/DDR/回读/显示侧）。
    //   定位完成后把顶层例化的 PROBE_OVL 置回 1'b0。
    wire [11:0]   S_px_x = {S_grp_cnt, 2'b00};
    wire [11:0]   S_px_x1 = S_px_x + 12'd1;
    wire [11:0]   S_px_x2 = S_px_x + 12'd2;
    wire [11:0]   S_px_x3 = S_px_x + 12'd3;
    wire [9:0]    S_px_y = S_line_cnt - 10'd1;
    wire          S_ovl_y = (S_px_y < 10'd8) || (S_px_y >= 10'd712);
    wire          S_ovl0 = PROBE_OVL && (S_ovl_y || (S_px_x  < 12'd8) || (S_px_x  >= 12'd1272));
    wire          S_ovl1 = PROBE_OVL && (S_ovl_y || (S_px_x1 < 12'd8) || (S_px_x1 >= 12'd1272));
    wire          S_ovl2 = PROBE_OVL && (S_ovl_y || (S_px_x2 < 12'd8) || (S_px_x2 >= 12'd1272));
    wire          S_ovl3 = PROBE_OVL && (S_ovl_y || (S_px_x3 < 12'd8) || (S_px_x3 >= 12'd1272));
    wire [7:0]    S_g0 = S_ovl0 ? 8'hFF : gray8(S_ev_grp[9:0]);
    wire [7:0]    S_g1 = S_ovl1 ? 8'hFF : gray8(S_ev_grp[19:10]);
    wire [7:0]    S_g2 = S_ovl2 ? 8'hFF : gray8(S_ev_grp[29:20]);
    wire [7:0]    S_g3 = S_ovl3 ? 8'hFF : gray8(S_ev_grp[39:30]);
    wire [127:0]  S_w_next = S_ev_st ? {S_g3, S_g2, S_g1, S_g0, 96'd0}
                                     : {S_g3, S_g2, S_g1, S_g0, S_word_reg[127:32]};
    wire          S_wdone  = S_ev_dv && !S_ev_st && (S_wcnt == 2'd3);
    wire [6:0]    S_pack_waddr = S_ev_st ? 7'd0 : S_pack_ptr;

    always @(posedge I_clk_d) begin
        if (!I_rst_n_d) begin
            item        <= {W{1'b0}};
            item_v      <= 1'b0;
            rd_bin      <= {FA+1{1'b0}};
            rd_gray     <= {FA+1{1'b0}};
            wr_gray_s1  <= {FA+1{1'b0}};
            wr_gray_s2  <= {FA+1{1'b0}};
            S_line_cnt  <= 10'd0;
            S_cur_slot  <= 1'b0;
            S_pack_ptr  <= 7'd0;
            S_grp_cnt   <= 9'd0;
            S_wcnt      <= 2'd0;
            S_word_reg  <= 128'd0;
            S_bad_latch <= 1'b0;
            S_done_p    <= 1'b0;
            S_bad_p     <= 1'b0;
            S_line_addr0<= 25'd0;
            S_line_addr1<= 25'd0;
            S_ptgl0     <= 1'b0;
            S_ptgl1     <= 1'b0;
        end else begin
            wr_gray_s1 <= wr_gray;
            wr_gray_s2 <= wr_gray_s1;

            S_done_p <= 1'b0;              // 默认清零（下方按需置位）
            S_bad_p  <= 1'b0;

            // ---- 出队（冻结时保持当前条目与指针）----
            if (!S_frz) begin
                item   <= fifo[rd_bin[FA-1:0]];
                item_v <= fifo_ne;
                if (fifo_ne) begin
                    rd_bin  <= rd_bin + 1'b1;
                    rd_gray <= bin2gray(rd_bin + 1'b1);
                end
            end

            // ---- 条目处理（消费当前条目）----
            if (S_pop) begin
                // 帧开始：上一帧未收尾（FE 缺失等）→ 当拍给出结论
                if (S_ev_fs) begin
                    if (S_line_cnt != 10'd0) begin
                        if (S_frame_ok) S_done_p <= 1'b1;
                        else            S_bad_p  <= 1'b1;
                    end
                    S_line_cnt  <= 10'd0;
                    S_pack_ptr  <= 7'd0;
                    S_grp_cnt   <= 9'd0;
                    S_wcnt      <= 2'd0;
                    S_bad_latch <= 1'b0;
                end
                // 行首：核对上一行完整性 → 锁存本行地址 → 进入本行
                if (S_ev_st) begin
                    if (S_line_cnt != 10'd0) begin
                        if ((S_pack_ptr < 7'd80) || (S_grp_cnt < 9'd320))
                            S_bad_latch <= 1'b1;
                    end
                    S_cur_slot <= S_line_cnt[0];
                    if (S_line_cnt[0]) S_line_addr1 <= S_line_base;
                    else               S_line_addr0 <= S_line_base;
                    S_line_cnt <= S_line_cnt + 10'd1;
                    S_pack_ptr <= 7'd0;
                end else if (S_wdone) begin
                    if (S_pack_ptr != 7'd127)         // 饱和（异常长行防回卷）
                        S_pack_ptr <= S_pack_ptr + 7'd1;
                end
                // 像素组：组装字；字满 → 写行缓冲（第 80 字 → 翻转打包握手）
                if (S_ev_dv) begin
                    S_word_reg <= S_w_next;
                    if (S_ev_st) S_wcnt <= 2'd1;
                    else         S_wcnt <= S_wcnt + 2'd1;
                end
                if (S_wdone && (S_pack_ptr < 7'd80)) begin
                    if (S_cur_slot) S_rb1[S_pack_waddr] <= S_w_next;
                    else            S_rb0[S_pack_waddr] <= S_w_next;
                    if (S_pack_ptr == 7'd79) begin
                        if (S_cur_slot) S_ptgl1 <= ~S_ptgl1;
                        else            S_ptgl0 <= ~S_ptgl0;
                    end
                end
                if (S_ev_st)      S_grp_cnt <= S_ev_dv ? 9'd1 : 9'd0;
                else if (S_ev_dv) begin
                    if (S_grp_cnt != 9'd511) S_grp_cnt <= S_grp_cnt + 9'd1;
                end
                // 帧结束：核对 → 完成/异常
                if (S_ev_fe) begin
                    if (S_frame_ok) S_done_p <= 1'b1;
                    else            S_bad_p  <= 1'b1;
                    S_line_cnt  <= 10'd0;
                    S_pack_ptr  <= 7'd0;
                    S_grp_cnt   <= 9'd0;
                    S_wcnt      <= 2'd0;
                    S_bad_latch <= 1'b0;
                end
            end
        end
    end

    // ---- 排空引擎（独立推进；仅访问握手允许的 bank）----
    always @(posedge I_clk_d) begin
        if (!I_rst_n_d) begin
            S_dr_st <= 2'd0;
            S_dr_slot <= 1'b0;
            S_dr_ptr <= 7'd0;
            S_dr_data <= 128'd0;
            S_dtgl0 <= 1'b0;
            S_dtgl1 <= 1'b0;
        end else begin
            case (S_dr_st)
                2'd0: begin                         // IDLE：找已打包整行的 bank
                    if (S_pend0) begin
                        S_dr_slot <= 1'b0;
                        S_dr_ptr  <= 7'd0;
                        S_dr_st   <= 2'd1;
                    end else if (S_pend1) begin
                        S_dr_slot <= 1'b1;
                        S_dr_ptr  <= 7'd0;
                        S_dr_st   <= 2'd1;
                    end
                end
                2'd1: begin                         // RD：读行缓冲（1 拍）
                    // 【M5-② 诊断 v2】W4 排空侧标记：奇数行（slot 1）的 ptr==0 数据替换为 0x55 灰条
                    //   与 W3（偶数行、回填侧 0x88）错行互不遮掩；两者落点差即排空→回填段的偏移。
                    S_dr_data <= (S_dr_slot && (S_dr_ptr == 7'd0))
                                 ? 128'h5555_5555_5555_5555_5555_5555_5555_5555
                                 : (S_dr_slot ? S_rb1[S_dr_ptr] : S_rb0[S_dr_ptr]);
                    S_dr_st   <= 2'd2;
                end
                2'd2: begin                         // REQ：保持请求直到获准
                    if (I_wr_gnt) begin
                        if (S_dr_ptr == 7'd79) begin
                            if (S_dr_slot) S_dtgl1 <= ~S_dtgl1;
                            else           S_dtgl0 <= ~S_dtgl0;
                            S_dr_st <= 2'd0;
                        end else begin
                            S_dr_ptr <= S_dr_ptr + 7'd1;
                            S_dr_st  <= 2'd1;
                        end
                    end
                end
                default: S_dr_st <= 2'd0;
            endcase
        end
    end

    // ================================================== 输出
    assign O_frame_start = S_ev_fs && !S_frz;
    assign O_frame_done  = S_done_p;
    assign O_frame_bad   = S_bad_p;
    assign O_wr_req      = (S_dr_st == 2'd2);
    assign O_wr_addr     = (S_dr_slot ? S_line_addr1 : S_line_addr0) +
                           {15'b0, S_dr_ptr, 3'b0};
    assign O_wr_data     = S_dr_data;

endmodule
