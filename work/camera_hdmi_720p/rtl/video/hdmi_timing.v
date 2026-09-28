/*******************************************************************************
 * camera_hdmi_720p — HDMI 视频时序发生器（自研）
 *
 * 生成 1280x720@60Hz（CEA-861 VIC=4）显示时序：
 *   行：0..1279 有效 → 110 前肩 → 40 行同步 → 220 后肩（合计 1650）
 *   场：0..719 有效 → 5 前肩 → 5 场同步 → 20 后肩（合计 750）
 * 同步信号为有效高（与参考设计 vtc 语义一致，hdmi_tx 的 rgb 模式下仅用 de/vs）。
 *
 * 输出 de 与 x/y 同拍：de=1 时 (x,y) 即当前像素坐标。
 *
 * 时钟：HDMI 像素时钟（本工程 75MHz；若更换像素时钟，只需改参数/时钟源）
 ******************************************************************************/
`timescale 1ns / 1ps

module hdmi_timing #(
    parameter H_ACTIVE     = 1280,
    parameter H_TOTAL      = 1650,
    parameter H_SYNC_START = 1390,  // 行同步区间 [H_SYNC_START, H_SYNC_END)
    parameter H_SYNC_END   = 1430,
    parameter V_ACTIVE     = 720,
    parameter V_TOTAL      = 750,
    parameter V_SYNC_START = 725,   // 场同步区间 (V_SYNC_START, V_SYNC_END]
    parameter V_SYNC_END   = 730
)(
    input  wire        clk,
    input  wire        rst_n,
    output reg         vs,   // 场同步（有效高）
    output reg         hs,   // 行同步（有效高）
    output reg         de,   // 数据有效
    output reg  [11:0] x,    // 像素列坐标（de=1 时有效）
    output reg  [11:0] y,    // 像素行坐标（de=1 时有效）
    output reg         user,
    output reg         last
);

    reg  [11:0] S_hcnt;
    reg  [11:0] S_vcnt;

    wire S_hs_i = (S_hcnt >= H_SYNC_START) && (S_hcnt < H_SYNC_END);
    wire S_vs_i = (S_vcnt >  V_SYNC_START) && (S_vcnt <= V_SYNC_END);
    wire S_de_i = (S_hcnt <  H_ACTIVE)     && (S_vcnt <  V_ACTIVE);
    wire S_user_i = (S_hcnt == 12'd0)      && (S_vcnt == 12'd0);
    wire S_last_i = (S_hcnt == H_ACTIVE - 1) && (S_vcnt <  V_ACTIVE);

    // 行计数器
    always @(posedge clk) begin
        if (!rst_n)
            S_hcnt <= 12'd0;
        else
            S_hcnt <= (S_hcnt == H_TOTAL - 1) ? 12'd0 : S_hcnt + 1'b1;
    end

    // 场计数器（每行结束加 1）
    always @(posedge clk) begin
        if (!rst_n)
            S_vcnt <= 12'd0;
        else if (S_hcnt == H_TOTAL - 1)
            S_vcnt <= (S_vcnt == V_TOTAL - 1) ? 12'd0 : S_vcnt + 1'b1;
    end

    // 同步/有效信号与坐标同拍输出
    always @(posedge clk) begin
        if (!rst_n) begin
            vs <= 1'b0;  hs <= 1'b0;  de <= 1'b0;
            x  <= 12'd0; y  <= 12'd0;
            user <= 1'b0; last <= 1'b0;
        end
        else begin
            vs <= S_vs_i;  hs <= S_hs_i;  de <= S_de_i;
            x  <= S_hcnt;  y  <= S_vcnt;
            user <= S_user_i;  last <= S_last_i;
        end
    end

endmodule
