/*******************************************************************************
 * camera_hdmi_720p — HDMI 测试图案（自研）
 *
 * M1 上板验证用图案（1280x720 区域内）：
 *   1) 8 条标准彩条（每 160 像素一条：白/黄/青/绿/品红/红/蓝/深灰）
 *   2) 4 像素白色边框（验证整幅几何范围）
 *   3) y=300..419 的灰度渐变带（R=G=B=x[7:0]，验证水平 1280 全分辨率）
 *   4) 橙色方块每帧右移 8 像素、天蓝色方块每帧下移 6 像素（验证帧在持续刷新）
 *   5) 顶部文字 "HDMI TEST 1280X720"（5x7 字模 2 倍放大，15x7 -> 10x14）
 *
 * 输出 data/de_o/vs_o 为 2 级流水（= 组合 de+3），与 hdmi_mixer 输出同相，
 * 使 video_mux 在测试图案↔摄像头切换时 de/vs/hs 无相位跳变。
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

    wire [23:0] S_pattern = S_border ? 24'hFFFFFF :
                            S_box_o  ? 24'hFF8000 :
                            S_box_b  ? 24'h00C0FF :
                            S_grad   ? {x[7:0], x[7:0], x[7:0]} :
                                       S_bar_color;

    // 5x7 字模；row 0..6，bit[4] 为最左像素
    function [4:0] F_text_row;
        input [4:0] idx;
        input [2:0] row;
        begin
            case (idx)
                5'd0: case (row) // H
                    3'd0: F_text_row = 5'b10001; 3'd1: F_text_row = 5'b10001;
                    3'd2: F_text_row = 5'b10001; 3'd3: F_text_row = 5'b11111;
                    3'd4: F_text_row = 5'b10001; 3'd5: F_text_row = 5'b10001;
                    3'd6: F_text_row = 5'b10001; default: F_text_row = 5'b00000; endcase
                5'd1: case (row) // D
                    3'd0: F_text_row = 5'b11110; 3'd1: F_text_row = 5'b10001;
                    3'd2: F_text_row = 5'b10001; 3'd3: F_text_row = 5'b10001;
                    3'd4: F_text_row = 5'b10001; 3'd5: F_text_row = 5'b10001;
                    3'd6: F_text_row = 5'b11110; default: F_text_row = 5'b00000; endcase
                5'd2: case (row) // M
                    3'd0: F_text_row = 5'b10001; 3'd1: F_text_row = 5'b11011;
                    3'd2: F_text_row = 5'b10101; 3'd3: F_text_row = 5'b10101;
                    3'd4: F_text_row = 5'b10001; 3'd5: F_text_row = 5'b10001;
                    3'd6: F_text_row = 5'b10001; default: F_text_row = 5'b00000; endcase
                5'd3: case (row) // I
                    3'd0: F_text_row = 5'b11111; 3'd1: F_text_row = 5'b00100;
                    3'd2: F_text_row = 5'b00100; 3'd3: F_text_row = 5'b00100;
                    3'd4: F_text_row = 5'b00100; 3'd5: F_text_row = 5'b00100;
                    3'd6: F_text_row = 5'b11111; default: F_text_row = 5'b00000; endcase
                5'd4: F_text_row = 5'b00000; // space
                5'd5: case (row) // T
                    3'd0: F_text_row = 5'b11111; 3'd1: F_text_row = 5'b00100;
                    3'd2: F_text_row = 5'b00100; 3'd3: F_text_row = 5'b00100;
                    3'd4: F_text_row = 5'b00100; 3'd5: F_text_row = 5'b00100;
                    3'd6: F_text_row = 5'b00100; default: F_text_row = 5'b00000; endcase
                5'd6: case (row) // E
                    3'd0: F_text_row = 5'b11111; 3'd1: F_text_row = 5'b10000;
                    3'd2: F_text_row = 5'b10000; 3'd3: F_text_row = 5'b11110;
                    3'd4: F_text_row = 5'b10000; 3'd5: F_text_row = 5'b10000;
                    3'd6: F_text_row = 5'b11111; default: F_text_row = 5'b00000; endcase
                5'd7: case (row) // S
                    3'd0: F_text_row = 5'b01111; 3'd1: F_text_row = 5'b10000;
                    3'd2: F_text_row = 5'b10000; 3'd3: F_text_row = 5'b01110;
                    3'd4: F_text_row = 5'b00001; 3'd5: F_text_row = 5'b00001;
                    3'd6: F_text_row = 5'b11110; default: F_text_row = 5'b00000; endcase
                5'd8: case (row) // T
                    3'd0: F_text_row = 5'b11111; 3'd1: F_text_row = 5'b00100;
                    3'd2: F_text_row = 5'b00100; 3'd3: F_text_row = 5'b00100;
                    3'd4: F_text_row = 5'b00100; 3'd5: F_text_row = 5'b00100;
                    3'd6: F_text_row = 5'b00100; default: F_text_row = 5'b00000; endcase
                5'd9: F_text_row = 5'b00000; // space
                5'd10: case (row) // 1
                    3'd0: F_text_row = 5'b00100; 3'd1: F_text_row = 5'b01100;
                    3'd2: F_text_row = 5'b00100; 3'd3: F_text_row = 5'b00100;
                    3'd4: F_text_row = 5'b00100; 3'd5: F_text_row = 5'b00100;
                    3'd6: F_text_row = 5'b01110; default: F_text_row = 5'b00000; endcase
                5'd11: case (row) // 2
                    3'd0: F_text_row = 5'b01110; 3'd1: F_text_row = 5'b10001;
                    3'd2: F_text_row = 5'b00001; 3'd3: F_text_row = 5'b00010;
                    3'd4: F_text_row = 5'b00100; 3'd5: F_text_row = 5'b01000;
                    3'd6: F_text_row = 5'b11111; default: F_text_row = 5'b00000; endcase
                5'd12: case (row) // 8
                    3'd0: F_text_row = 5'b01110; 3'd1: F_text_row = 5'b10001;
                    3'd2: F_text_row = 5'b10001; 3'd3: F_text_row = 5'b01110;
                    3'd4: F_text_row = 5'b10001; 3'd5: F_text_row = 5'b10001;
                    3'd6: F_text_row = 5'b01110; default: F_text_row = 5'b00000; endcase
                5'd13: case (row) // 0
                    3'd0: F_text_row = 5'b01110; 3'd1: F_text_row = 5'b10001;
                    3'd2: F_text_row = 5'b10011; 3'd3: F_text_row = 5'b10101;
                    3'd4: F_text_row = 5'b11001; 3'd5: F_text_row = 5'b10001;
                    3'd6: F_text_row = 5'b01110; default: F_text_row = 5'b00000; endcase
                5'd14: case (row) // X
                    3'd0: F_text_row = 5'b10001; 3'd1: F_text_row = 5'b10001;
                    3'd2: F_text_row = 5'b01010; 3'd3: F_text_row = 5'b00100;
                    3'd4: F_text_row = 5'b01010; 3'd5: F_text_row = 5'b10001;
                    3'd6: F_text_row = 5'b10001; default: F_text_row = 5'b00000; endcase
                5'd15: case (row) // 7
                    3'd0: F_text_row = 5'b11111; 3'd1: F_text_row = 5'b00001;
                    3'd2: F_text_row = 5'b00010; 3'd3: F_text_row = 5'b00100;
                    3'd4: F_text_row = 5'b01000; 3'd5: F_text_row = 5'b01000;
                    3'd6: F_text_row = 5'b01000; default: F_text_row = 5'b00000; endcase
                5'd16: case (row) // 2
                    3'd0: F_text_row = 5'b01110; 3'd1: F_text_row = 5'b10001;
                    3'd2: F_text_row = 5'b00001; 3'd3: F_text_row = 5'b00010;
                    3'd4: F_text_row = 5'b00100; 3'd5: F_text_row = 5'b01000;
                    3'd6: F_text_row = 5'b11111; default: F_text_row = 5'b00000; endcase
                5'd17: case (row) // 0
                    3'd0: F_text_row = 5'b01110; 3'd1: F_text_row = 5'b10001;
                    3'd2: F_text_row = 5'b10011; 3'd3: F_text_row = 5'b10101;
                    3'd4: F_text_row = 5'b11001; 3'd5: F_text_row = 5'b10001;
                    3'd6: F_text_row = 5'b01110; default: F_text_row = 5'b00000; endcase
                default: F_text_row = 5'b00000;
            endcase
        end
    endfunction

    // ---------------- 5x7 文字：HDMI TEST 1280X720 ----------------
    // 18 个字符，每字符 16x16 单元；5x7 字模按 2 倍放大（10x14）
    localparam [11:0] TX0 = 12'd40;
    localparam [11:0] TY0 = 12'd40;
    localparam [11:0] TBOX_W = 12'd288;   // 18 * 16

    wire S_text_area = (x >= TX0 - 12'd4) && (x < TX0 + TBOX_W + 12'd4) &&
                       (y >= TY0 - 12'd4) && (y < TY0 + 12'd20);
    wire [4:0] S_text_idx = (x - TX0) >> 4;
    wire [3:0] S_text_col = (x - TX0) & 4'hF;
    wire [3:0] S_text_row = (y - TY0) & 4'hF;
    wire [2:0] S_fx = S_text_col[3:1];
    wire [2:0] S_fy = S_text_row[3:1];
    wire [2:0] S_fx_idx = (S_fx < 3'd5) ? (3'd4 - S_fx) : 3'd0;
    wire [4:0] S_font_row = F_text_row(S_text_idx, S_fy);
    wire S_text_px = (S_fx < 3'd5) && (S_fy < 3'd7) && S_font_row[S_fx_idx];

    wire [23:0] S_pix = S_text_area ? (S_text_px ? 24'hFFFFFF : 24'h000000) :
                                       S_pattern;


    // ---------------- 输出寄存器（2 级流水） ----------------
    reg [23:0] data_r;
    reg        de_r;
    reg        vs_r;

    always @(posedge clk) begin
        if (!rst_n) begin
            de_r  <= 1'b0;
            vs_r  <= 1'b0;
            data_r<= 24'd0;
            de_o  <= 1'b0;
            vs_o  <= 1'b0;
            data  <= 24'd0;
        end
        else begin
            de_r  <= de;
            vs_r  <= vs;
            data_r<= de ? S_pix : 24'h000000;
            de_o  <= de_r;
            vs_o  <= vs_r;
            data  <= data_r;
        end
    end

endmodule
