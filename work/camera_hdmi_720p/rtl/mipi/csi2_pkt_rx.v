`timescale 1ns / 1ps
//=============================================================================
// csi2_pkt_rx.v — CSI-2 包解析（自研，M3）
//
// 输入：MIPI D-PHY IP 的字节流（跑在字节时钟域 I_clk = o_fabric_div4_8_clk）
//   I_hs_valid —— 一个 HS 包期间为 1，包间为 0（IP 输出即包字节流，不含同步码）
//   I_hs_data  —— 每拍 2 字节 {lane0, lane1} = {先到的字节, 后到的字节}
//
// CSI-2 包头 4 字节 = [DI, WC_hi, WC_lo, ECC]，2 lane 时每拍 2 字节：
//   首拍高字节 = DI、首拍低字节 = WC_hi、次拍高字节 = WC_lo、次拍低字节 = ECC
//
// 输出：
//   O_fs/O_fe/O_ls/O_le —— 短包事件（各 1 拍脉冲）
//   O_pay_*             —— RAW10 长包负载（每拍 2 字节，首/末拍用 O_pay_start/end 标出）
//   O_last_dt/O_last_wc —— 最近一个包的 DT / 字长（观测用）
//   O_err_*             —— 粘滞错误：非预期长包 / WC 不符 / 包头或包体异常
//
// 注：包尾 2 字节 CRC + EoT 不解析，直接忽略——下一个包靠 valid 上升沿识别。
// 注：WC 为奇数时按 WC>>1 消费（RAW10 行包 WC=1600 恒为偶数，实际不会触发）。
//=============================================================================
module csi2_pkt_rx (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        I_hs_valid,
    input  wire [15:0] I_hs_data,

    output reg         O_fs,
    output reg         O_fe,
    output reg         O_ls,
    output reg         O_le,

    output wire        O_pay_valid,
    output wire [15:0] O_pay_data,
    output wire        O_pay_start,
    output wire        O_pay_end,

    output reg  [15:0] O_last_wc,
    output reg  [5:0]  O_last_dt,

    output reg         O_err_dt,
    output reg         O_err_wc,
    output reg         O_err_hdr
);

    // ---- CSI-2 数据类型 ----
    localparam [5:0] DT_FS    = 6'h00;   // 帧开始（短包）
    localparam [5:0] DT_FE    = 6'h01;   // 帧结束（短包）
    localparam [5:0] DT_LS    = 6'h02;   // 行开始（短包）
    localparam [5:0] DT_LE    = 6'h03;   // 行结束（短包）
    localparam [5:0] DT_EMB   = 6'h12;   // 嵌入式数据行（传感器常见，按"已知"处理）
    localparam [5:0] DT_RAW10 = 6'h2B;   // RAW10 图像行

    localparam [15:0] WC_720P = 16'd1600;  // 1280 px × 10bit / 8bit = 1600 字节
    localparam [7:0]  SYNC_B8 = 8'hB8;     // MIPI 同步码（正常不应出现在本 IP 输出里）

    // ---- 状态机 ----
    localparam [2:0] S_IDLE = 3'd0;   // 等包开始（valid 上升沿）
    localparam [2:0] S_HDR  = 3'd1;   // 取 WC_lo/ECC 并判类型
    localparam [2:0] S_PAY  = 3'd2;   // 输出 RAW10 负载
    localparam [2:0] S_SKIP = 3'd3;   // 跳过本包（等 valid 拉低）

    reg [2:0]  st;
    reg        v1d;          // valid 打一拍
    reg [7:0]  hdr_b0;       // 首拍高字节 = DI
    reg [7:0]  hdr_b1;       // 首拍低字节 = WC_hi
    reg [5:0]  dt_r;         // 本包 DT（已锁存）
    reg [14:0] pay_left;     // 剩余负载拍数
    reg        pay_first;    // 本拍是负载首拍
    reg [4:0]  idle_vcnt;    // IDLE 里 valid 连续为高的拍数（异常保护）

    wire        hdr_rise = I_hs_valid & ~v1d;
    wire [7:0]  b_hi     = I_hs_data[15:8];
    wire [7:0]  b_lo     = I_hs_data[7:0];
    wire [15:0] wc_now   = {hdr_b1, b_hi};   // 次拍：WC = {WC_hi, WC_lo}

    // 负载输出（组合，随 valid 直通；消费者在 clk 沿采样）
    assign O_pay_valid = (st == S_PAY) & I_hs_valid;
    assign O_pay_data  = I_hs_data;
    assign O_pay_start = (st == S_PAY) & I_hs_valid & pay_first;
    assign O_pay_end   = (st == S_PAY) & I_hs_valid & (pay_left == 15'd1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st        <= S_IDLE;
            v1d       <= 1'b0;
            hdr_b0    <= 8'h00;
            hdr_b1    <= 8'h00;
            dt_r      <= 6'd0;
            pay_left  <= 15'd0;
            pay_first <= 1'b0;
            idle_vcnt <= 5'd0;
            O_fs      <= 1'b0;
            O_fe      <= 1'b0;
            O_ls      <= 1'b0;
            O_le      <= 1'b0;
            O_last_wc <= 16'd0;
            O_last_dt <= 6'd0;
            O_err_dt  <= 1'b0;
            O_err_wc  <= 1'b0;
            O_err_hdr <= 1'b0;
        end else begin
            v1d <= I_hs_valid;
            O_fs <= 1'b0;
            O_fe <= 1'b0;
            O_ls <= 1'b0;
            O_le <= 1'b0;

            case (st)
            // ---- 等包开始 ----
            S_IDLE: begin
                if (hdr_rise) begin
                    hdr_b0    <= b_hi;
                    hdr_b1    <= b_lo;
                    idle_vcnt <= 5'd0;
                    st        <= S_HDR;
                end else if (I_hs_valid) begin
                    if (idle_vcnt >= 5'd15) O_err_hdr <= 1'b1;   // 包未正常结束
                    else                    idle_vcnt <= idle_vcnt + 5'd1;
                end else begin
                    idle_vcnt <= 5'd0;
                end
            end
            // ---- 取 WC_lo/ECC，按 DI 判类型 ----
            S_HDR: begin
                if (I_hs_valid) begin
                    dt_r      <= hdr_b0[5:0];
                    O_last_wc <= wc_now;
                    O_last_dt <= hdr_b0[5:0];
                    if (hdr_b0 == SYNC_B8) begin           // 疑似同步码（正常不应出现）
                        O_err_hdr <= 1'b1;
                        st        <= S_SKIP;
                    end else if (hdr_b0[5:0] == DT_FS) begin
                        O_fs <= 1'b1;  st <= S_SKIP;
                    end else if (hdr_b0[5:0] == DT_FE) begin
                        O_fe <= 1'b1;  st <= S_SKIP;
                    end else if (hdr_b0[5:0] == DT_LS) begin
                        O_ls <= 1'b1;  st <= S_SKIP;
                    end else if (hdr_b0[5:0] == DT_LE) begin
                        O_le <= 1'b1;  st <= S_SKIP;
                    end else if (hdr_b0[5:0] == DT_RAW10) begin
                        if (wc_now != WC_720P) O_err_wc <= 1'b1;
                        pay_left  <= {1'b0, wc_now[15:1]};  // WC>>1 拍
                        pay_first <= 1'b1;
                        st        <= S_PAY;
                    end else begin
                        if (hdr_b0[5:0] != DT_EMB) O_err_dt <= 1'b1;
                        st <= S_SKIP;
                    end
                end else begin
                    O_err_hdr <= 1'b1;   // 包头未取全
                    st        <= S_IDLE;
                end
            end
            // ---- 输出 RAW10 负载 ----
            S_PAY: begin
                if (I_hs_valid) begin
                    pay_first <= 1'b0;
                    if (pay_left > 15'd1) pay_left <= pay_left - 15'd1;
                    else                  st       <= S_IDLE;
                end else begin
                    O_err_hdr <= 1'b1;   // 包体提前结束
                    st        <= S_IDLE;
                end
            end
            // ---- 跳过本包，等 valid 拉低 ----
            S_SKIP: begin
                if (!I_hs_valid) st <= S_IDLE;
            end
            default: st <= S_IDLE;
            endcase
        end
    end

endmodule
