/*******************************************************************************
 * camera_hdmi_720p — HDMI 视频时序发生器（自研，M6 复刻 uivtc 时序）
 *
 * 生成 1280x720@60Hz（CEA-861 VIC=4）显示时序。
 * 逐拍复刻参考工程 uivtc 的时序生成，保证 video_out/hdmi_mixer 收到的
 * de/vs/hs/user/last 相位与参考件完全一致（消除 OSD 模式下 logo/画面偏移）：
 *   de   延 2 拍（= uivtc vtc_valid_r2）
 *   vs/hs 延 1 拍（= uivtc vtc_vs_r1 / vtc_hs_r1）
 *   user  uivtc 式：vs_start 在 vs 上升沿置位、在 user_r1 清零；user_r1 在
 *          「vs_start 期间的第一个 de」翻转（单拍脉冲）；user_r2 延 1 拍 → 与 de(+2) 同拍
 *   last  uivtc 式：de 下降沿（~de & de_1d）→ last_r2，与 de(+2) 同拍
 *   x/y   hcnt/vcnt 延 2 拍，与 de 同相对齐（供 test_pattern 组合用）
 *
 * 时钟：HDMI 像素时钟（75MHz）。复位：rst_n（由 reset_ctrl 同步释放）。
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
    output wire        vs,    // 场同步（有效高），延 1 拍
    output wire        hs,    // 行同步（有效高），延 1 拍
    output wire        de,    // 数据有效，延 2 拍
    output wire [11:0] x,     // 像素列坐标，延 2 拍（与 de 同拍）
    output wire [11:0] y,     // 像素行坐标，延 2 拍
    output wire        user,  // 帧起始脉冲，uivtc 式，延 2 拍（与 de 同拍）
    output wire        last   // 行结束脉冲，uivtc 式，延 2 拍（与 de 同拍）
);

    reg  [11:0] S_hcnt;
    reg  [11:0] S_vcnt;

    wire S_hs_i = (S_hcnt >= H_SYNC_START) && (S_hcnt < H_SYNC_END);
    wire S_vs_i = (S_vcnt >  V_SYNC_START) && (S_vcnt <= V_SYNC_END);
    wire S_de_i = (S_hcnt <  H_ACTIVE)     && (S_vcnt <  V_ACTIVE);

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

    // ---- uivtc 式 user 生成辅助：vs_start ----
    // vs_start 在 vs 上升沿（S_vs_i=1 且上一拍 S_vs_r1=0）置位，在 user_r1 置位时清零。
    // 与 uivtc 的 vs_start always 一致（vtc_vs && vtc_vs_r1==0 → 置位；vtc_user_r1 → 清零）。
    reg        S_vs_start;
    reg        S_vs_r1;
    reg        S_hs_r1;
    reg        S_user_r1;
    reg        S_user_r2;
    reg        S_last_r2;
    reg        S_valid_r1;
    reg        S_valid_r2;
    reg [11:0] S_x_1d;
    reg [11:0] S_x_2d;
    reg [11:0] S_y_1d;
    reg [11:0] S_y_2d;

    always @(posedge clk) begin
        if (!rst_n)
            S_vs_start <= 1'b0;
        else if (S_user_r1)
            S_vs_start <= 1'b0;
        else if (S_vs_i && !S_vs_r1)
            S_vs_start <= 1'b1;
    end

    // ---- 主寄存器块（复刻 uivtc 主 always）----
    always @(posedge clk) begin
        if (!rst_n) begin
            S_vs_r1    <= 1'b0;
            S_hs_r1    <= 1'b0;
            S_user_r1  <= 1'b0;
            S_last_r2  <= 1'b0;
            S_valid_r1 <= 1'b0;
            S_valid_r2 <= 1'b0;
            S_user_r2  <= 1'b0;
            S_x_1d     <= 12'd0;
            S_x_2d     <= 12'd0;
            S_y_1d     <= 12'd0;
            S_y_2d     <= 12'd0;
        end else begin
            S_vs_r1    <= S_vs_i;
            S_hs_r1    <= S_hs_i;
            // user_r1：在 vs_start 期间的第一个 de 处翻转（单拍脉冲）
            S_user_r1  <= ~S_user_r1 & S_vs_start & S_de_i;
            // last：de 下降沿（本拍 de=0、上拍 de_1d=1）→ 与 de(+2) 同拍
            S_last_r2  <= ~S_de_i & S_valid_r1;
            S_valid_r1 <= S_de_i;          // de +1
            S_valid_r2 <= S_valid_r1;      // de +2
            S_user_r2  <= S_user_r1;       // user +2（与 de(+2) 同拍）
            S_x_1d     <= S_hcnt;          // x +1
            S_x_2d     <= S_x_1d;          // x +2（与 de 同拍）
            S_y_1d     <= S_vcnt;          // y +1
            S_y_2d     <= S_y_1d;          // y +2
        end
    end

    assign vs   = S_vs_r1;     // vs  延 1 拍
    assign hs   = S_hs_r1;     // hs  延 1 拍
    assign de   = S_valid_r2;  // de  延 2 拍
    assign user = S_user_r2;   // user 延 2 拍（与 de 同拍）
    assign last = S_last_r2;   // last 延 2 拍（与 de 同拍）
    assign x    = S_x_2d;      // x   延 2 拍（与 de 同拍）
    assign y    = S_y_2d;      // y   延 2 拍（与 de 同拍）

endmodule
