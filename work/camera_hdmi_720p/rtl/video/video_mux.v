/*******************************************************************************
 * camera_hdmi_720p — 视频源选择（自研）
 *
 * I_camera_sel（像素域已同步）：
 *   1 = 摄像头 / CV 输出（正常或动态调试）
 *   0 = 静态测试图案（SW1=1, SW2=0）
 *
 * sel 仅在 vsync 上升沿（帧边界）更新，切换发生在消隐期，避免半帧撕裂。
 * 接口与 test_pattern 输出同相，video_mux 输出打一拍后送 hdmi_tx。
 ******************************************************************************/
`timescale 1ns / 1ps

module video_mux (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        I_camera_sel, // 像素域同步后的源选择
    input  wire [23:0] I_pat_data,
    input  wire        I_pat_de,
    input  wire        I_pat_vs,

    input  wire [23:0] I_cam_data,
    input  wire        I_cam_de,
    input  wire        I_cam_vs,

    output reg  [23:0] O_data,
    output reg         O_de,
    output reg         O_vs,
    output wire        O_sel
);

    reg sel;
    reg vs_d;
    wire vs_rise = I_cam_vs & ~vs_d;

    always @(posedge clk) begin
        if (!rst_n) begin
            sel  <= 1'b1;
            vs_d <= 1'b0;
        end else begin
            vs_d <= I_cam_vs;
            if (vs_rise) sel <= I_camera_sel;
        end
    end

    assign O_sel = sel;

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
