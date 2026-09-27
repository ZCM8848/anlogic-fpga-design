`timescale 1ns / 1ps
//=============================================================================
// mipi_stats.v — MIPI 接收统计 + 跨时钟快照（自研，M3）
//
// 字节域（clk_b = o_fabric_div4_8_clk，103.5MHz@828Mbps）计数：
//   FS 帧计数（BCD 6 位）、上一帧行数（BCD 4 位）、上一行像素数（BCD 5 位）、
//   上一行组数（BCD 4 位）、错误位图（粘滞 8 位）、是否见过 HS 流量
//
// 跨域：字节域打快照 → 2 相握手（req 翻转 + ack 翻转各经 2 级同步）→ 100MHz 域
//   数据在 ack 回来前保持不变（MCP 多周期路径），两域已声明异步时钟组。
//
// 错误位图（O_err / D_merr）：
//   bit0 lane_error（HS 期间出现）      bit1 非预期长包（DT 异常）
//   bit2 RAW10 行包 WC≠1600            bit3 包头/包体异常或疑似同步码
//   bit4 帧结束时行数≠720              bit5 帧结束时行像素≠1280
//   bit6 FS/FE 不配对                  bit7 保留
//
// BCD 计数由十进制(逐位)加法器 bcd_add 实现——避免二进制到十进制转换的除法。
//=============================================================================
module mipi_stats (
    // ---- 字节时钟域 ----
    input  wire        clk_b,
    input  wire        rst_n_b,

    input  wire        I_hs_valid,
    input  wire        I_lane_error,     // |O_lane_error
    input  wire        I_fs,
    input  wire        I_fe,
    input  wire        I_pay_start,      // 行包负载首拍
    input  wire        I_pkt_done,       // 行包结束（raw10_unpack）
    input  wire        I_px_grp_valid,   // 出组（每组 4 像素）
    input  wire        I_err_dt,
    input  wire        I_err_wc,
    input  wire        I_err_hdr,
    input  wire [31:0] I_dbg_hdr,        // 诊断：最近 RAW10 包头 4 字节
    input  wire [15:0] I_dbg_pw,         // 诊断：负载首拍 2 字节
    input  wire [14:0] I_dbg_pleft,      // 诊断：包体中断时剩余拍数
    input  wire [3:0]  I_dbg_hcause,     // 诊断：err_hdr 成因

    // ---- 字节域 → 100M 域（快照，握手保护）----
    output reg  [23:0] O_snap_fs,
    output reg  [15:0] O_snap_line,
    output reg  [19:0] O_snap_wpx,
    output reg  [15:0] O_snap_grp,
    output reg  [7:0]  O_snap_err,
    output reg         O_snap_hs,
    output reg  [31:0] O_snap_hdr,
    output reg  [15:0] O_snap_pw,
    output reg  [14:0] O_snap_pleft,
    output reg  [3:0]  O_snap_hcause,
    output reg         O_req_t,          // 请求翻转（随快照）

    // ---- 100M 时钟域 ----
    input  wire        clk_s,
    input  wire        rst_n_s,
    input  wire        I_ack_t,          // 100M 域回执翻转（顶层把 O_ack_t 接回这里）
    output reg         O_ack_t,          // 取走快照后翻转回执

    output reg  [23:0] O_fs_bcd,
    output reg  [15:0] O_line_bcd,
    output reg  [19:0] O_wpx_bcd,
    output reg  [15:0] O_grp_bcd,
    output reg  [7:0]  O_err,
    output reg         O_hs_seen,
    output reg  [31:0] O_dbg_hdr,
    output reg  [15:0] O_dbg_pw,
    output reg  [14:0] O_dbg_pleft,
    output reg  [3:0]  O_dbg_hcause
);

    localparam [15:0] LINE_720  = 16'h0720;   // 720 的 BCD
    localparam [19:0] WPX_1280  = 20'h01280;  // 1280 的 BCD
    localparam [23:0] HB_ROLL   = 24'hFFFFFF; // 心跳快照周期（≈162ms @103.5MHz）

    // ---- BCD 十进制加法（24bit = 6 位十进制）----
    function [23:0] bcd_add;
        input [23:0] v;
        input [3:0]  add;
        integer k;
        reg [4:0] s;
        reg [4:0] t;
        reg       cy;
        begin
            bcd_add = v;
            cy      = 1'b0;
            for (k = 0; k < 6; k = k + 1) begin
                s = {1'b0, bcd_add[4*k +: 4]} + (k == 0 ? {1'b0, add} : {4'b0, cy});
                if (s > 5'd9) begin
                    t = s - 5'd10;
                    bcd_add[4*k +: 4] = t[3:0];
                    cy = 1'b1;
                end else begin
                    bcd_add[4*k +: 4] = s[3:0];
                    cy = 1'b0;
                end
            end
        end
    endfunction

    // ---- 字节域状态 ----
    reg [23:0] fs_bcd;
    reg [15:0] line_bcd;
    reg [19:0] wpx_bcd;
    reg [15:0] grp_bcd;
    reg [7:0]  err_b;
    reg        hs_seen_b;
    reg [3:0]  dm;        // FS/FE 配对计数（FS +1、FE -1）
    reg [23:0] hb;        // 心跳计数
    reg        busy;      // 上一次快照尚未被 100M 域取走
    reg        ack_s1, ack_s2, ack_last;

    reg [23:0] t24;

    // ---- 100M 域状态 ----
    reg        req_s1, req_s2, req_last;

    always @(posedge clk_b or negedge rst_n_b) begin
        if (!rst_n_b) begin
            fs_bcd   <= 24'd0;
            line_bcd <= 16'd0;
            wpx_bcd  <= 20'd0;
            grp_bcd  <= 16'd0;
            err_b    <= 8'd0;
            hs_seen_b<= 1'b0;
            dm       <= 4'd0;
            hb       <= 24'd0;
            busy     <= 1'b0;
            ack_s1   <= 1'b0;
            ack_s2   <= 1'b0;
            ack_last <= 1'b0;
            O_snap_fs   <= 24'd0;
            O_snap_line <= 16'd0;
            O_snap_wpx  <= 20'd0;
            O_snap_grp  <= 16'd0;
            O_snap_err  <= 8'd0;
            O_snap_hs   <= 1'b0;
            O_snap_hdr  <= 32'd0;
            O_snap_pw   <= 16'd0;
            O_snap_pleft<= 15'd0;
            O_snap_hcause <= 4'd0;
            O_req_t     <= 1'b0;
        end else begin
            hb <= (hb == HB_ROLL) ? 24'd0 : (hb + 24'd1);

            // ---- 帧计数 ----
            if (I_fs) begin
                t24    = bcd_add({4'b0, fs_bcd}, 4'd1);
                fs_bcd <= t24[23:0];
            end

            // ---- 每帧行数 ----
            if (I_fs) begin
                line_bcd <= 16'd0;
            end else if (I_pkt_done) begin
                t24      = bcd_add({8'b0, line_bcd}, 4'd1);
                line_bcd <= t24[15:0];
            end

            // ---- 每行像素/组数 ----
            if (I_pay_start) begin
                wpx_bcd <= 20'd0;
                grp_bcd <= 16'd0;
            end else if (I_px_grp_valid) begin
                t24     = bcd_add({4'b0, wpx_bcd}, 4'd4);   // 每组 4 像素
                wpx_bcd <= t24[19:0];
                t24     = bcd_add({8'b0, grp_bcd}, 4'd1);
                grp_bcd <= t24[15:0];
            end

            // ---- 粘滞错误 ----
            if (I_hs_valid) hs_seen_b <= 1'b1;
            if (I_hs_valid & I_lane_error) err_b[0] <= 1'b1;
            if (I_err_dt)                  err_b[1] <= 1'b1;
            if (I_err_wc)                  err_b[2] <= 1'b1;
            if (I_err_hdr)                 err_b[3] <= 1'b1;

            // ---- FS/FE 配对与帧末核对 ----
            if (I_fs) begin
                dm <= dm + 4'd1;
            end else if (I_fe) begin
                if (dm != 4'd1)         err_b[6] <= 1'b1;
                if (line_bcd != LINE_720) err_b[4] <= 1'b1;
                if (wpx_bcd  != WPX_1280) err_b[5] <= 1'b1;
                dm <= (dm == 4'd0) ? 4'd0 : (dm - 4'd1);
            end

            // ---- 快照 + 2 相握手 ----
            ack_s1 <= I_ack_t;
            ack_s2 <= ack_s1;
            if (ack_s2 != ack_last) begin
                ack_last <= ack_s2;
                busy     <= 1'b0;
            end

            if ((I_fe | (hb == HB_ROLL)) && !busy) begin
                O_snap_fs   <= fs_bcd;
                O_snap_line <= line_bcd;
                O_snap_wpx  <= wpx_bcd;
                O_snap_grp  <= grp_bcd;
                O_snap_err  <= err_b;
                O_snap_hs   <= hs_seen_b;
                O_snap_hdr  <= I_dbg_hdr;
                O_snap_pw   <= I_dbg_pw;
                O_snap_pleft<= I_dbg_pleft;
                O_snap_hcause <= I_dbg_hcause;
                O_req_t     <= ~O_req_t;
                busy        <= 1'b1;
            end
        end
    end

    // ---- 100M 域：取快照并回执 ----
    always @(posedge clk_s or negedge rst_n_s) begin
        if (!rst_n_s) begin
            req_s1   <= 1'b0;
            req_s2   <= 1'b0;
            req_last <= 1'b0;
            O_fs_bcd   <= 24'd0;
            O_line_bcd <= 16'd0;
            O_wpx_bcd  <= 20'd0;
            O_grp_bcd  <= 16'd0;
            O_err      <= 8'd0;
            O_hs_seen  <= 1'b0;
            O_dbg_hdr  <= 32'd0;
            O_dbg_pw   <= 16'd0;
            O_dbg_pleft<= 15'd0;
            O_dbg_hcause <= 4'd0;
            O_ack_t    <= 1'b0;
        end else begin
            req_s1 <= O_req_t;
            req_s2 <= req_s1;
            if (req_s2 != req_last) begin
                req_last   <= req_s2;
                O_fs_bcd   <= O_snap_fs;
                O_line_bcd <= O_snap_line;
                O_wpx_bcd  <= O_snap_wpx;
                O_grp_bcd  <= O_snap_grp;
                O_err      <= O_snap_err;
                O_hs_seen  <= O_snap_hs;
                O_dbg_hdr  <= O_snap_hdr;
                O_dbg_pw   <= O_snap_pw;
                O_dbg_pleft<= O_snap_pleft;
                O_dbg_hcause <= O_snap_hcause;
                O_ack_t    <= ~O_ack_t;      // 回执：字节域据此清 busy
            end
        end
    end

endmodule
