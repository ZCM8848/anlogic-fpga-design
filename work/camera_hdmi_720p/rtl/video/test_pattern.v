/*******************************************************************************
 * camera_hdmi_720p — HDMI 测试图案（自研）
 *
 * M1 上板验证用图案（1280x720 区域内）：
 *   1) 8 条标准彩条（每 160 像素一条：白/黄/青/绿/品红/红/蓝/深灰）
 *   2) 4 像素白色边框（验证整幅几何范围）
 *   3) 行 y=300..419 的灰度渐变带（R=G=B=x[7:0]，验证水平 1280 全分辨率）
 *   4) 橙色方块每帧右移 8 像素、天蓝色方块每帧下移 6 像素（验证帧在持续刷新）
 *
 * 输出 data/de_o/vs_o 同为 1 拍寄存，与 hdmi_tx 输入要求一致（de 与 data 同拍）。
 ******************************************************************************/
`timescale 1ns / 1ps

module test_pattern (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vs,     // 来自 hdmi_timing（有效高）
    input  wire        de,     // 来自 hdmi_timing
    input  wire [11:0] x,      // 0..1279
    input  wire [11:0] y,      // 0..719
    output reg  [23:0] data,   // {R[7:0], G[7:0], B[7:0]}
    output reg         de_o,
    output reg         vs_o
);

    parameter H_ACTIVE = 1280;
    parameter V_ACTIVE = 720;

    // ---------------- 帧节拍（vs 上升沿） ----------------
    reg  S_vs_d;
    wire S_vs_rise = vs & ~S_vs_d;

    always @(posedge clk) begin
        if (!rst_n)
            S_vs_d <= 1'b0;
        else
            S_vs_d <= vs;
    end

    // ---------------- 移动方块坐标 ----------------
    reg [11:0] S_box_x;   // 橙色方块：每帧右移 8 像素
    reg [11:0] S_box_y;   // 天蓝方块：每帧下移 6 像素

    always @(posedge clk) begin
        if (!rst_n) begin
            S_box_x <= 12'd0;
            S_box_y <= 12'd0;
        end
        else if (S_vs_rise) begin
            S_box_x <= (S_box_x + 12'd8 >= H_ACTIVE) ? 12'd0 : S_box_x + 12'd8;
            S_box_y <= (S_box_y + 12'd6 >= V_ACTIVE) ? 12'd0 : S_box_y + 12'd6;
        end
    end

    // ---------------- 彩条 ----------------
    wire [2:0] S_bar_idx = (x < 12'd160)  ? 3'd0 :
                           (x < 12'd320)  ? 3'd1 :
                           (x < 12'd480)  ? 3'd2 :
                           (x < 12'd640)  ? 3'd3 :
                           (x < 12'd800)  ? 3'd4 :
                           (x < 12'd960)  ? 3'd5 :
                           (x < 12'd1120) ? 3'd6 : 3'd7;

    reg [23:0] S_bar_color;
    always @* begin
        case (S_bar_idx)
            3'd0:    S_bar_color = 24'hFFFFFF;  // 白
            3'd1:    S_bar_color = 24'hFFFF00;  // 黄
            3'd2:    S_bar_color = 24'h00FFFF;  // 青
            3'd3:    S_bar_color = 24'h00FF00;  // 绿
            3'd4:    S_bar_color = 24'hFF00FF;  // 品红
            3'd5:    S_bar_color = 24'hFF0000;  // 红
            3'd6:    S_bar_color = 24'h0000FF;  // 蓝
            default: S_bar_color = 24'h202020;  // 深灰
        endcase
    end

    // ---------------- 叠加元素 ----------------
    wire S_border = (x < 12'd4) || (x >= H_ACTIVE - 4) || (y < 12'd4) || (y >= V_ACTIVE - 4);
    wire S_grad   = (y >= 12'd300) && (y < 12'd420);
    wire S_box_o  = (x >= S_box_x) && (x < S_box_x + 12'd128) && (y >= 12'd540) && (y < 12'd668);
    wire S_box_b  = (x >= 12'd64)  && (x < 12'd192)           && (y >= S_box_y) && (y < S_box_y + 12'd128);

    wire [23:0] S_pix = S_border ? 24'hFFFFFF :
                        S_box_o  ? 24'hFF8000 :
                        S_box_b  ? 24'h00C0FF :
                        S_grad   ? {x[7:0], x[7:0], x[7:0]} :
                                   S_bar_color;

    // ---------------- 输出寄存（与 de 同拍） ----------------
    always @(posedge clk) begin
        if (!rst_n) begin
            data <= 24'd0;
            de_o <= 1'b0;
            vs_o <= 1'b0;
        end
        else begin
            de_o <= de;
            vs_o <= vs;
            data <= de ? S_pix : 24'h000000;
        end
    end

endmodule
