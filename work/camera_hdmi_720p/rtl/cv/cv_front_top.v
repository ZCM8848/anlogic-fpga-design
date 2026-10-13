`timescale 1ns / 1ps
//=============================================================================
// cv_front_top.v — CV 前端顶层（灰度 -> 光照归一化/IIR 背景 -> 形态学）
//   把 24bit RGB 视频流变成干净的 1bit 前景掩膜，替代 cv_top 内部的阈值级：
//       I_rgb(24) -> cv_gray -> cv_norm_bg -> 形态学开(腐蚀->膨胀) -> O_mask(1)
//   对应 Python: Python/impl_hw/hw_pipeline.HWPipeline 的检测前半段。
//
//   时序: 逐拍流水，O_de/O_vs 与 O_mask 对齐。
//   与 cv_top 的衔接: 把 O_mask 作为 cv_top 的检测掩膜输入（cv_top 当前内部
//   自算阈值；接入时用本模块输出旁路 cv_top 的阈值/Sobel 级即可）。
//=============================================================================
module cv_front_top #(
    parameter IMG_W = 1280
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_de,
    input  wire        I_vs,
    input  wire [23:0] I_rgb,
    output wire        O_de,
    output wire        O_vs,
    output wire        O_mask,      // 1 = 前景（处理后的掩膜）
    output wire [7:0]  O_norm       // 光照归一化后的灰度（调试/直方图用）
);
    // ---- 灰度 ----
    wire        g_de, g_vs;
    wire [7:0]  g_y;
    cv_gray u_gray (
        .I_clk(I_clk), .I_rst_n(I_rst_n), .I_de(I_de), .I_vs(I_vs), .I_rgb(I_rgb),
        .O_de(g_de), .O_vs(g_vs), .O_y(g_y)
    );

    // ---- 光照归一化 + IIR 背景 + 阈值 ----
    wire        n_de, n_vs, n_mask;
    wire [7:0]  n_norm;
    cv_norm_bg u_norm (
        .I_clk(I_clk), .I_rst_n(I_rst_n), .I_de(g_de), .I_vs(g_vs), .I_y(g_y),
        .O_de(n_de), .O_vs(n_vs), .O_norm(n_norm), .O_mask(n_mask)
    );

    // ---- 形态学开：腐蚀 -> 膨胀（去碎点）----
    wire        e_de, e_vs, e_pix;
    cv_morph3x3 #(.IMG_W(IMG_W), .MODE(0)) u_erode (
        .I_clk(I_clk), .I_rst_n(I_rst_n), .I_de(n_de), .I_vs(n_vs), .I_pix(n_mask),
        .O_de(e_de), .O_vs(e_vs), .O_pix(e_pix)
    );
    wire        d_de, d_vs, d_pix;
    cv_morph3x3 #(.IMG_W(IMG_W), .MODE(1)) u_dilate (
        .I_clk(I_clk), .I_rst_n(I_rst_n), .I_de(e_de), .I_vs(e_vs), .I_pix(e_pix),
        .O_de(d_de), .O_vs(d_vs), .O_pix(d_pix)
    );

    assign O_de   = d_de;
    assign O_vs   = d_vs;
    assign O_mask = d_pix;
    assign O_norm = n_norm;

endmodule
