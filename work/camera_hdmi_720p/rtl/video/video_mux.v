/*******************************************************************************
 * camera_hdmi_720p — 视频源选择（自研，M4）
 *
 * 把 M1 的彩条测试图案与摄像头画面二选一送 hdmi_tx。
 * 开关 SW4（板手册 2-22：SW4 = 引脚 D11，拨上=1、拨下=0）：
 *   SW4 = 1（拨上） → 摄像头画面
 *   SW4 = 0（拨下） → 彩条测试图案（已知正确的基准，便于 A/B 定位）
 * SW1（A4，最高优先级；I_force_cam 已在顶层同步到 clk）：
 *   SW1 = 1         → 强制摄像头 RGB888 原图直通（不受 SW4 影响）
 *
 * 接口与 test_pattern 完全一致（data/de_o/vs_o 同为 1 拍寄存、同拍对齐），
 * 因此顶层只需把 test_pattern 的输出改成经过本模块再送 hdmi_tx。
 ******************************************************************************/
`timescale 1ns / 1ps

module video_mux (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        I_sw4,        // SW4 原始输入（异步，内部同步）
    input  wire        I_force_cam,  // SW1 同步后：1=强制摄像头（优先级高于 SW4）

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

    // ---------------- SW4 同步（2 级）+ 帧边界门控 ----------------
    // sel 不再每拍跟随 SW4，而是仅在 vsync 上升沿（帧边界）采纳已同步的 SW4，
    // 使切换发生在消隐期（de=0）：① 无半帧撕裂（整帧来自同一源）；
    //   ② 即便两源仍有残余相位差，扰动也落在 de=0 区不可见。
    //   （配合 test_pattern 2 级流水与 hdmi_mixer 同相后，切换处 de/vs 连续无跳变。）
    reg [2:0] sync_sw;
    reg       sel_want;   // 已同步的 SW4（期望 sel）
    reg       sel;        // 实际 sel（仅帧边界更新）
    reg       vs_d;       // I_cam_vs 延迟，用于上升沿检测
    wire      vs_rise = I_cam_vs & ~vs_d;

    always @(posedge clk) begin
        if (!rst_n) begin
            sync_sw  <= 3'd0;
            sel_want <= 1'b0;
            sel      <= 1'b0;
            vs_d     <= 1'b0;
        end else begin
            sync_sw  <= {sync_sw[1:0], I_sw4};
            sel_want <= sync_sw[2] | I_force_cam;
            vs_d     <= I_cam_vs;
            if (vs_rise) sel <= sel_want;   // 仅帧边界切换
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
