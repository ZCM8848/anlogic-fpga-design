/*******************************************************************************
 * camera_hdmi_720p — DDR 帧缓存三缓冲管理（自研，M5-②）
 *
 * 三个帧缓冲槽，状态机：FREE → WRITING → READY → DISPLAY → FREE
 *
 *   帧开始（fs，I_frame_start）：
 *     · 若上帧异常未收尾（仍有 WRITING 槽）→ 该槽作废回 FREE（其内容残缺不完整，
 *       不会上屏）；结论脉冲由 fb_wr 在同拍/次拍给出（done 或 bad）。
 *     · 分配新的写缓冲：优先 FREE；无 FREE 则抢占 READY（未上屏就被覆盖 → OV++）。
 *       3 槽 + 每态 ≤1 槽 ⇒ 「FREE 或 READY 至少有一个」恒成立。
 *   帧完成（fe 核对通过，I_frame_done）：WRITING → READY（WR 计数++）；
 *     若已有旧的 READY 未被显示取走 → 旧 READY 回 FREE（OV++）。
 *   帧异常（I_frame_bad）：ER++，WRITING 保持（等下个 fs 作废）。
 *   显示换帧（I_vsync_pulse）：READY → DISPLAY（RD 计数++，O_rd_base 切到该槽基址）；
 *     旧 DISPLAY → FREE。无 READY 时保持上一帧（重复显示，无撕裂）。
 *   行欠载（I_line_underflow）→ UN++；仲裁器异常（I_arb_err）→ ER++。
 *
 * 基址（2 字节单位）：槽 0/1/2 = 0x00000 / 0x80000 / 0x100000（各隔 1MB 字节，
 *   一帧仅占 0x70800 单位，互不重叠）。
 *
 * 计数快照（用户域 → 100MHz 域）：WR/RD 为 4 位十进制 BCD 计数器（bcd_add4），
 *   OV/UN/ER 为 8bit 二进制（串口按 1 位 16 进制展示，>15 显示 F）。
 *   握手协议与 mipi_stats 相同（req/ack 各 2 级同步，数据在 ack 前保持不变）。
 ******************************************************************************/
`timescale 1ns / 1ps

module fb_ctrl (
    // ---------------- 用户域（S_ddr_clk）----------------
    input  wire         clk,
    input  wire         rst_n,

    input  wire         I_frame_start,    // 组合脉冲（fb_wr：fs 处理当拍）
    input  wire         I_frame_done,     // 1 拍脉冲
    input  wire         I_frame_bad,      // 1 拍脉冲
    input  wire         I_vsync_pulse,    // 1 拍脉冲（fb_rd）
    input  wire         I_line_underflow, // 1 拍脉冲（fb_rd）
    input  wire         I_arb_err,        // 1 拍脉冲（ddr_arb）

    output wire [24:0]  O_wr_base,        // 当前写帧基址
    output wire [24:0]  O_rd_base,        // 当前显示帧基址（vs 当拍组合预览新槽）
    output reg          O_rd_valid,       // 有可显示帧

    output reg          O_req_t,          // 快照请求翻转（用户域）
    input  wire         I_ack_t,          // 100MHz 域回执翻转（顶层接回）
    output reg          O_ack_t,          // 100MHz 域回执输出

    // ---------------- 100MHz 域 ----------------
    input  wire         clk_s,
    input  wire         rst_n_s,
    output reg  [15:0]  O_wr_cnt,         // BCD
    output reg  [15:0]  O_rd_cnt,         // BCD
    output reg  [7:0]   O_ov_cnt,
    output reg  [7:0]   O_un_cnt,
    output reg  [7:0]   O_er_cnt
);

    localparam ST_FREE = 2'd0;
    localparam ST_WR   = 2'd1;
    localparam ST_RDY  = 2'd2;
    localparam ST_DSP  = 2'd3;

    localparam [23:0] HB_ROLL = 24'hFFFFFF;    // 心跳快照周期（≈251ms @66.7MHz）

    // ---- BCD 十进制加法（16bit = 4 位十进制，逐位加，无除法）----
    function [15:0] bcd_add4;
        input [15:0] v;
        input [3:0]  add;
        integer k;
        reg [4:0] s;
        reg [4:0] t;
        reg       cy;
        begin
            bcd_add4 = v;
            cy       = 1'b0;
            for (k = 0; k < 4; k = k + 1) begin
                s = {1'b0, bcd_add4[4*k +: 4]} + (k == 0 ? {1'b0, add} : {4'b0, cy});
                if (s > 5'd9) begin
                    t = s - 5'd10;
                    bcd_add4[4*k +: 4] = t[3:0];
                    cy = 1'b1;
                end else begin
                    bcd_add4[4*k +: 4] = s[3:0];
                    cy = 1'b0;
                end
            end
        end
    endfunction

    function [24:0] base_of (input [1:0] idx);
        begin
            case (idx)
                2'd1:    base_of = 25'd524288;     // 0x80000 单位 = 1MB 字节
                2'd2:    base_of = 25'd1048576;    // 0x100000 单位 = 2MB 字节
                default: base_of = 25'd0;
            endcase
        end
    endfunction

    // ---- 槽状态与索引 ----
    reg [1:0]  S_st0, S_st1, S_st2;
    reg [1:0]  S_wr_idx;
    reg [1:0]  S_rd_idx;
    reg [24:0] S_base;         // 当前写帧基址
    reg [24:0] S_rd_base;      // 当前显示帧基址（寄存器本体；O_rd_base 为其组合预览）

    // ---- 计数 ----
    reg [15:0] S_wr_bcd, S_rd_bcd;
    reg [7:0]  S_ov, S_un, S_er;

    // ---- 快照（用户域侧）----
    reg        S_busy;
    reg        S_ack_s1, S_ack_s2, S_ack_last;
    reg [23:0] S_hb;
    reg [15:0] S_snap_wr, S_snap_rd;
    reg [7:0]  S_snap_ov, S_snap_un, S_snap_er;

    // ---- 100MHz 侧同步 ----
    reg        S_req_s1, S_req_s2, S_req_last;

    // ---- 组合挑选 ----
    wire       S_wr_any  = (S_st0 == ST_WR) || (S_st1 == ST_WR) || (S_st2 == ST_WR);
    wire [1:0] S_wr_cur  = (S_st0 == ST_WR) ? 2'd0 :
                           (S_st1 == ST_WR) ? 2'd1 : 2'd2;
    wire       S_rdy_any = (S_st0 == ST_RDY) || (S_st1 == ST_RDY) || (S_st2 == ST_RDY);
    wire [1:0] S_rdy_idx = (S_st0 == ST_RDY) ? 2'd0 :
                           (S_st1 == ST_RDY) ? 2'd1 : 2'd2;
    wire       S_dsp_any = (S_st0 == ST_DSP) || (S_st1 == ST_DSP) || (S_st2 == ST_DSP);
    wire [1:0] S_dsp_cur = (S_st0 == ST_DSP) ? 2'd0 :
                           (S_st1 == ST_DSP) ? 2'd1 : 2'd2;
    wire       S_free_any = (S_st0 == ST_FREE) || (S_st1 == ST_FREE) || (S_st2 == ST_FREE);
    wire [1:0] S_free_idx = (S_st0 == ST_FREE) ? 2'd0 :
                            (S_st1 == ST_FREE) ? 2'd1 : 2'd2;

    // fs 当拍的写缓冲挑选：FREE 优先，其次抢占 READY（OV++）
    wire       S_pick_steal = !S_free_any && S_rdy_any;
    wire [1:0] S_pick_idx   = S_free_any ? S_free_idx : S_rdy_idx;
    wire [24:0] S_pick_base = base_of(S_pick_idx);

    // 写基址：fs 当拍组合切换到新槽（fb_wr 在其后 ≥1 拍的行首取用）
    assign O_wr_base = I_frame_start ? S_pick_base : S_base;

    // 显示基址：vs 当拍组合切换到新槽（fb_rd 在 vs 次拍取预取基址，寄存器版本晚 1 拍）
    assign O_rd_base = (I_vsync_pulse && !I_frame_start && S_rdy_any)
                       ? base_of(S_rdy_idx) : S_rd_base;

    always @(posedge clk) begin
        if (!rst_n) begin
            S_st0    <= ST_FREE;
            S_st1    <= ST_FREE;
            S_st2    <= ST_FREE;
            S_wr_idx <= 2'd0;
            S_rd_idx <= 2'd0;
            S_base   <= 25'd0;
            S_rd_base<= 25'd0;
            O_rd_valid <= 1'b0;
            S_wr_bcd <= 16'd0;
            S_rd_bcd <= 16'd0;
            S_ov     <= 8'd0;
            S_un     <= 8'd0;
            S_er     <= 8'd0;
            S_busy   <= 1'b0;
            S_ack_s1 <= 1'b0;
            S_ack_s2 <= 1'b0;
            S_ack_last <= 1'b0;
            S_hb     <= 24'd0;
            S_snap_wr<= 16'd0;
            S_snap_rd<= 16'd0;
            S_snap_ov<= 8'd0;
            S_snap_un<= 8'd0;
            S_snap_er<= 8'd0;
            O_req_t  <= 1'b0;
        end else begin
            // ---------------- 帧开始：分配写缓冲 ----------------
            if (I_frame_start) begin
                // 上帧异常未收尾：其槽作废（残缺内容不上屏）
                if (S_wr_any) begin
                    case (S_wr_cur)
                        2'd0: S_st0 <= ST_FREE;
                        2'd1: S_st1 <= ST_FREE;
                        default: S_st2 <= ST_FREE;
                    endcase
                end
                if (S_free_any) begin
                    case (S_pick_idx)
                        2'd0: S_st0 <= ST_WR;
                        2'd1: S_st1 <= ST_WR;
                        default: S_st2 <= ST_WR;
                    endcase
                    S_wr_idx <= S_pick_idx;
                    S_base   <= S_pick_base;
                end else if (S_rdy_any) begin
                    case (S_pick_idx)
                        2'd0: S_st0 <= ST_WR;
                        2'd1: S_st1 <= ST_WR;
                        default: S_st2 <= ST_WR;
                    endcase
                    S_wr_idx <= S_pick_idx;
                    S_base   <= S_pick_base;
                    S_ov     <= S_ov + 8'd1;     // 抢占未上屏的 READY 帧
                end else begin
                    S_er     <= S_er + 8'd1;     // 理论不可达（3 槽保证）
                end
            end

            // ---------------- 帧完成：WRITING → READY ----------------
            if (I_frame_done && S_wr_any) begin
                // 与 vsync 同拍时：把旧 READY 让给显示取走（不记 OV，避免同拍覆盖）
                if (S_rdy_any && !I_vsync_pulse) begin
                    case (S_rdy_idx)
                        2'd0: S_st0 <= ST_FREE;
                        2'd1: S_st1 <= ST_FREE;
                        default: S_st2 <= ST_FREE;
                    endcase
                    S_ov <= S_ov + 8'd1;
                end
                case (S_wr_cur)
                    2'd0: S_st0 <= ST_RDY;
                    2'd1: S_st1 <= ST_RDY;
                    default: S_st2 <= ST_RDY;
                endcase
                S_wr_bcd <= bcd_add4(S_wr_bcd, 4'd1);
            end

            // ---------------- 帧异常 ----------------
            if (I_frame_bad) begin
                S_er <= S_er + 8'd1;
            end

            // ---------------- 显示换帧：READY → DISPLAY ----------------
            // fs 同拍时 fs 优先（分配写缓冲不能被覆盖；显示晚一帧再换，安全）
            if (I_vsync_pulse && !I_frame_start) begin
                if (S_rdy_any) begin
                    if (S_dsp_any) begin         // 旧显示槽回 FREE
                        case (S_dsp_cur)
                            2'd0: S_st0 <= ST_FREE;
                            2'd1: S_st1 <= ST_FREE;
                            default: S_st2 <= ST_FREE;
                        endcase
                    end
                    case (S_rdy_idx)
                        2'd0: S_st0 <= ST_DSP;
                        2'd1: S_st1 <= ST_DSP;
                        default: S_st2 <= ST_DSP;
                    endcase
                    S_rd_idx   <= S_rdy_idx;
                    S_rd_base  <= base_of(S_rdy_idx);
                    O_rd_valid <= 1'b1;
                    S_rd_bcd   <= bcd_add4(S_rd_bcd, 4'd1);
                end
                // 无 READY：保持上一帧（重复显示）
            end

            // ---------------- 诊断计数 ----------------
            if (I_line_underflow) S_un <= S_un + 8'd1;
            if (I_arb_err)        S_er <= S_er + 8'd1;

            // ---------------- 快照 + 2 相握手（与 mipi_stats 同构）----------------
            S_ack_s1 <= I_ack_t;
            S_ack_s2 <= S_ack_s1;
            if (S_ack_s2 != S_ack_last) begin
                S_ack_last <= S_ack_s2;
                S_busy     <= 1'b0;
            end

            S_hb <= (S_hb == HB_ROLL) ? 24'd0 : (S_hb + 24'd1);

            if ((I_frame_done | I_frame_bad | (S_hb == HB_ROLL)) && !S_busy) begin
                S_snap_wr <= S_wr_bcd;
                S_snap_rd <= S_rd_bcd;
                S_snap_ov <= S_ov;
                S_snap_un <= S_un;
                S_snap_er <= S_er;
                O_req_t   <= ~O_req_t;
                S_busy    <= 1'b1;
            end
        end
    end

    // ---------------- 100MHz 域：取快照并回执 ----------------
    always @(posedge clk_s) begin
        if (!rst_n_s) begin
            S_req_s1 <= 1'b0;
            S_req_s2 <= 1'b0;
            S_req_last <= 1'b0;
            O_wr_cnt <= 16'd0;
            O_rd_cnt <= 16'd0;
            O_ov_cnt <= 8'd0;
            O_un_cnt <= 8'd0;
            O_er_cnt <= 8'd0;
            O_ack_t  <= 1'b0;
        end else begin
            S_req_s1 <= O_req_t;
            S_req_s2 <= S_req_s1;
            if (S_req_s2 != S_req_last) begin
                S_req_last <= S_req_s2;
                O_wr_cnt   <= S_snap_wr;
                O_rd_cnt   <= S_snap_rd;
                O_ov_cnt   <= S_snap_ov;
                O_un_cnt   <= S_snap_un;
                O_er_cnt   <= S_snap_er;
                O_ack_t    <= ~O_ack_t;      // 回执：用户域据此清 busy
            end
        end
    end

endmodule
