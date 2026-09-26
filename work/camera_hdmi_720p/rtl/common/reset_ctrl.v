/*******************************************************************************
 * camera_hdmi_720p — 复位控制（自研）
 *
 * 功能：以 PLL lock 为触发，异步拉低、同步释放本时钟域的复位。
 *       PLL 未锁定时复位保持；锁定后在本时钟域同步计数 16 拍再释放，
 *       保证各域在稳定时钟下开始工作。
 ******************************************************************************/
`timescale 1ns / 1ps

module reset_ctrl (
    input  wire clk,        // 本时钟域时钟
    input  wire pll_lock,   // PLL 锁定指示（高有效，异步）
    output wire rst_n       // 本时钟域复位（低有效，同步释放）
);

    reg [3:0] S_cnt;

    always @(posedge clk or negedge pll_lock) begin
        if (!pll_lock)
            S_cnt <= 4'd0;
        else if (S_cnt != 4'hF)
            S_cnt <= S_cnt + 1'b1;
    end

    assign rst_n = (S_cnt == 4'hF);

endmodule
