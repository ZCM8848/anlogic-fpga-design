`timescale 1ns / 1ps
//=============================================================================
// cv_gray.v — RGB888 -> 8bit 灰度（BT.601 定点）
//   Y = (77*R + 150*G + 29*B) >> 8
//   对应 Python: Python/impl_hw/hw_ops.to_gray
//   资源: 3 乘法(或移位加法) + 加法树 + 寄存器（1 级流水）
//=============================================================================
module cv_gray (
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_de,
    input  wire        I_vs,
    input  wire [23:0] I_rgb,      // {R[7:0], G[7:0], B[7:0]}
    output reg         O_de,
    output reg         O_vs,
    output reg  [7:0]  O_y
);
    wire [15:0] w_sum = 16'd77  * I_rgb[23:16]
                      + 16'd150 * I_rgb[15:8]
                      + 16'd29  * I_rgb[7:0];

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_de <= 1'b0; O_vs <= 1'b0; O_y <= 8'd0;
        end else begin
            O_de <= I_de;
            O_vs <= I_vs;
            O_y  <= w_sum[15:8];
        end
    end
endmodule
