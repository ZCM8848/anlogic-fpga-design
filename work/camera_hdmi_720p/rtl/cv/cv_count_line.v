`timescale 1ns / 1ps
//=============================================================================
// cv_count_line.v — 单向计数线穿越计数（整数）
//   对应 Python: Python/impl_hw/hw_count.HWLineCounter
//
//   接口: 主控在每帧末尾扫描轨迹表，逐个把轨迹喂进来（I_scan_en 期间逐拍有效）。
//   侧向:  s = ldx*(cy-ly) - ldy*(cx-lx)  的符号（1 次乘加 + 比较）
//   越线:  当前符号 != 出生侧符号（1 位触发器/轨迹）
//   方向:  vx*dirx + vy*diry > 0（2 乘 + 加 + 比较）
//
//   存储: 每条轨迹 3 bit 状态（seen/first_neg/crossed），MAX_TRACKS 条。
//=============================================================================
module cv_count_line #(
    parameter MAX_TRACKS = 16
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_clear,        // 计数/状态清零
    // ---- 扫描接口（逐轨迹）----
    input  wire        I_scan_en,
    input  wire        I_tvalid,
    input  wire [4:0]  I_tid,
    input  wire [11:0] I_cx, I_cy,
    input  wire signed [11:0] I_vx, I_vy,
    input  wire        I_confirmed,
    // ---- 计数线参数（处理分辨率坐标）----
    input  wire signed [12:0] I_lx, I_ly,    // 线上一点
    input  wire signed [12:0] I_ldx, I_ldy,  // 线方向
    input  wire signed [12:0] I_dirx, I_diry,// 期望运动方向
    // ---- 结果 ----
    output reg  [15:0] O_count,
    output reg         O_cross_pulse
);
    reg [MAX_TRACKS-1:0] r_seen;
    reg [MAX_TRACKS-1:0] r_first_neg;
    reg [MAX_TRACKS-1:0] r_crossed;

    // 侧向符号
    wire signed [24:0] w_bx = $signed({13'b0, I_cx}) - I_lx;
    wire signed [24:0] w_by = $signed({13'b0, I_cy}) - I_ly;
    wire signed [25:0] w_s  = I_ldx * w_by - I_ldy * w_bx;
    wire               w_neg = w_s[25];
    // 方向点积
    wire signed [24:0] w_vdot = I_vx * I_dirx + I_vy * I_diry;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_count <= 0; O_cross_pulse <= 0;
            r_seen <= 0; r_first_neg <= 0; r_crossed <= 0;
        end else begin
            O_cross_pulse <= 1'b0;
            if (I_clear) begin
                O_count <= 0; r_seen <= 0; r_first_neg <= 0; r_crossed <= 0;
            end else if (I_scan_en && I_tvalid) begin
                if (!r_seen[I_tid]) begin
                    r_seen[I_tid]      <= 1'b1;
                    r_first_neg[I_tid] <= w_neg;
                end else if (I_confirmed && !r_crossed[I_tid]
                             && (w_neg != r_first_neg[I_tid])) begin
                    if (w_vdot > 0) begin
                        O_count       <= O_count + 1'b1;
                        O_cross_pulse <= 1'b1;
                        r_crossed[I_tid] <= 1'b1;
                    end
                end
            end
        end
    end
endmodule
