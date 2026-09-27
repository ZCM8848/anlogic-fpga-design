/*******************************************************************************
 * camera_hdmi_720p — 视频源选择（自研，M4）
 *
 * 把 M1 的彩条测试图案与 M4 的摄像头灰度画面二选一送 hdmi_tx。
 * 开关 SW4（板手册 2-22：SW4 = 引脚 D11，拨上=1、拨下=0）：
 *   SW4 = 1（拨上） → 摄像头画面
 *   SW4 = 0（拨下） → 彩条测试图案（已知正确的基准，便于 A/B 定位）
 *
 * 接口与 test_pattern 完全一致（data/de_o/vs_o 同为 1 拍寄存、同拍对齐），
 * 因此顶层只需把 test_pattern 的输出改成经过本模块再送 hdmi_tx。
 ******************************************************************************/
`timescale 1ns / 1ps

module video_mux (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        I_sw4,        // SW4 原始输入（异步，内部同步）

    // 测试图案源（M1）
    input  wire [23:0] I_pat_data,
    input  wire        I_pat_de,
    input  wire        I_pat_vs,

    // 摄像头源（M4 行缓存输出）
    input  wire [23:0] I_cam_data,
    input  wire        I_cam_de,
    input  wire        I_cam_vs,

    output reg  [23:0] O_data,
    output reg         O_de,
    output reg         O_vs,

    output wire        O_sel       // 供串口上报（同步后的开关状态）
);

    // ---------------- SW4 同步（2 级） ----------------
    reg [2:0] sync_sw;
    reg       sel;

    always @(posedge clk) begin
        if (!rst_n) begin
            sync_sw <= 3'd0;
            sel     <= 1'b0;                    // 复位默认：测试图案
        end else begin
            sync_sw <= {sync_sw[1:0], I_sw4};
            sel     <= sync_sw[2];
        end
    end

    assign O_sel = sel;

    // ---------------- 二选一 ----------------
    always @(posedge clk) begin
        if (!rst_n) begin
            O_data <= 24'd0;
            O_de   <= 1'b0;
            O_vs   <= 1'b0;
        end else if (sel) begin
            O_data <= I_cam_data;
            O_de   <= I_cam_de;
            O_vs   <= I_cam_vs;
        end else begin
            O_data <= I_pat_data;
            O_de   <= I_pat_de;
            O_vs   <= I_pat_vs;
        end
    end

endmodule
