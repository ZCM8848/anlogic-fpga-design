/*******************************************************************************
 * seg_count_display — 8 位数码管（共阳）十进制计数显示
 *
 * 硬件（与 work/seg_led_test 一致）：
 *   - 段选 O_seg[7:0] = {DP,g,f,e,d,c,b,a}，低电平点亮
 *   - 位选 O_sel[7:0] 低电平选中（PNP9012）
 *   - O_sel[0] = 最右位，O_sel[7] = 最左位
 *   - 板上 SW6 必须拨到数码管一侧（拨上）
 *
 * 显示格式：右 5 位显示 BCD 计数 00000..99999，左 3 位熄灭。
 ******************************************************************************/
`timescale 1ns / 1ps

module seg_count_display #(
    parameter integer CLK_HZ  = 50_000_000,
    parameter integer SCAN_HZ = 1_000
) (
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire [19:0] I_bcd,      // [3:0]=个位 ... [19:16]=万位
    input  wire        I_dash,     // 1=8 位全部显示 '-'（背景重采样）
    output reg  [7:0]  O_seg,
    output reg  [7:0]  O_sel
);

    localparam [31:0] SCAN_MAX = CLK_HZ / SCAN_HZ;

    // BCD 来自 AHB/150MHz 域，先 2FF 同步到 50MHz
    reg [19:0] bcd_s1, bcd_s2;
    reg        dash_s1, dash_s2;
    always @(posedge I_clk) begin
        bcd_s1  <= I_bcd;
        bcd_s2  <= bcd_s1;
        dash_s1 <= I_dash;
        dash_s2 <= dash_s1;
    end

    // ---------------- 扫描 ----------------
    reg [31:0] scan_cnt;
    reg [2:0]  scan_idx;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            scan_cnt <= 32'd0;
            scan_idx <= 3'd0;
        end else if (scan_cnt >= SCAN_MAX - 1) begin
            scan_cnt <= 32'd0;
            scan_idx <= scan_idx + 3'd1;
        end else begin
            scan_cnt <= scan_cnt + 32'd1;
        end
    end

    // 右 5 位显示计数，左 3 位全灭
    reg [3:0] disp_val;
    always @(*) begin
        case (scan_idx)
            3'd0: disp_val = bcd_s2[3:0];    // 个位
            3'd1: disp_val = bcd_s2[7:4];    // 十位
            3'd2: disp_val = bcd_s2[11:8];   // 百位
            3'd3: disp_val = bcd_s2[15:12];  // 千位
            3'd4: disp_val = bcd_s2[19:16];  // 万位
            default: disp_val = 4'hF;        // 左 3 位灭
        endcase
    end

    // 共阳段码，1=灭，0=亮；bit7=DP，bit6..0=g..a
    function [7:0] seg_decode;
        input [3:0] val;
        begin
            case (val)
                4'h0: seg_decode = 8'hC0;
                4'h1: seg_decode = 8'hF9;
                4'h2: seg_decode = 8'hA4;
                4'h3: seg_decode = 8'hB0;
                4'h4: seg_decode = 8'h99;
                4'h5: seg_decode = 8'h92;
                4'h6: seg_decode = 8'h82;
                4'h7: seg_decode = 8'hF8;
                4'h8: seg_decode = 8'h80;
                4'h9: seg_decode = 8'h90;
                default: seg_decode = 8'hFF;
            endcase
        end
    endfunction

    // 正常显示 BCD；重采样时 8 位全部显示 '-'
    reg [7:0] seg_code;
    always @(*) begin
        if (dash_s2) seg_code = 8'hBF;       // 共阳 '-'：仅 g 段亮
        else         seg_code = seg_decode(disp_val);
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_seg <= 8'hFF;
            O_sel <= 8'hFF;
        end else begin
            O_seg <= seg_code;
            O_sel <= ~(8'h01 << scan_idx);   // 低电平选中
        end
    end

endmodule
