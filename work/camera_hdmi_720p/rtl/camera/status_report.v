`timescale 1ns / 1ps
//=============================================================================
// status_report.v — 状态串口上报（自研，M6 精简版）
//
// 每 REPEAT_MS 连发一行（115200 8N1）：
//   CAM ID=<4hex> OK=<0/1> E=<0/1> CFG=<0/1> DDR=<0/1> SW4=<0/1> SW3=<0/1>\r\n
//
//   ID  = uicfgcs520 读回的 sensor ID（应为 9E4B）
//   OK  = ID 校验通过
//   E   = I2C 错误标志（uicfgcs520.O_iic_error）
//   CFG = 摄像头寄存器初始化完成（uicfgcs520.O_cfg_done）
//   DDR = DDR2 校准完成（同步到 100M 域）
//   SW4/SW3 = 模式开关（同步到 100M 域）
//=============================================================================
module status_report #(
    parameter CLK_FREQ  = 100_000_000,
    parameter BAUD      = 115200,
    parameter REPEAT_MS = 500
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire [15:0] I_cam_id,
    input  wire        I_cam_id_ok,
    input  wire        I_cam_i2c_err,
    input  wire        I_cam_cfg_done,
    input  wire        I_ddr_rdy,
    input  wire        I_sw4,
    input  wire        I_sw3,

    output wire        O_uart_tx
);

    localparam integer REPEAT_CYC = (CLK_FREQ / 1000) * REPEAT_MS;
    localparam [7:0]   LAST       = 8'd45;   // 字符表末索引（0..45 = 46 字节）

    function [7:0] hx(input [3:0] v);
        hx = (v < 4'd10) ? (8'h30 + {4'b0, v}) : (8'h37 + {4'b0, v});
    endfunction

    // ---- 字符表（46 字节）----
    wire [7:0] ln [0:45];

    assign ln[0]  = "C";
    assign ln[1]  = "A";
    assign ln[2]  = "M";
    assign ln[3]  = " ";
    assign ln[4]  = "I";
    assign ln[5]  = "D";
    assign ln[6]  = "=";
    assign ln[7]  = hx(I_cam_id[15:12]);
    assign ln[8]  = hx(I_cam_id[11:8]);
    assign ln[9]  = hx(I_cam_id[7:4]);
    assign ln[10] = hx(I_cam_id[3:0]);
    assign ln[11] = " ";
    assign ln[12] = "O";
    assign ln[13] = "K";
    assign ln[14] = "=";
    assign ln[15] = I_cam_id_ok    ? "1" : "0";
    assign ln[16] = " ";
    assign ln[17] = "E";
    assign ln[18] = "=";
    assign ln[19] = I_cam_i2c_err  ? "1" : "0";
    assign ln[20] = " ";
    assign ln[21] = "C";
    assign ln[22] = "F";
    assign ln[23] = "G";
    assign ln[24] = "=";
    assign ln[25] = I_cam_cfg_done ? "1" : "0";
    assign ln[26] = " ";
    assign ln[27] = "D";
    assign ln[28] = "D";
    assign ln[29] = "R";
    assign ln[30] = "=";
    assign ln[31] = I_ddr_rdy      ? "1" : "0";
    assign ln[32] = " ";
    assign ln[33] = "S";
    assign ln[34] = "W";
    assign ln[35] = "4";
    assign ln[36] = "=";
    assign ln[37] = I_sw4          ? "1" : "0";
    assign ln[38] = " ";
    assign ln[39] = "S";
    assign ln[40] = "W";
    assign ln[41] = "3";
    assign ln[42] = "=";
    assign ln[43] = I_sw3          ? "1" : "0";
    assign ln[44] = 8'h0D;         // \r
    assign ln[45] = 8'h0A;         // \n

    // ---- 发送 FSM ----
    reg [31:0] S_wait_cnt;
    reg [7:0]  S_pc;
    reg        S_send;          // 1=正在发送一行
    reg        S_valid;
    reg [7:0]  S_data;
    wire       S_uart_ready;

    uart_tx #(
        .CLK_FREQ ( CLK_FREQ ),
        .BAUD     ( BAUD     )
    ) u_uart (
        .clk     ( clk        ),
        .rst_n   ( rst_n      ),
        .I_valid ( S_valid    ),
        .I_data  ( S_data     ),
        .O_tx    ( O_uart_tx  ),
        .O_ready ( S_uart_ready )
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            S_wait_cnt <= 32'd0;
            S_pc       <= 8'd0;
            S_send     <= 1'b0;
            S_valid    <= 1'b0;
            S_data     <= 8'd0;
        end else begin
            if (!S_send) begin
                S_valid <= 1'b0;
                if (S_wait_cnt >= REPEAT_CYC - 1) begin
                    S_wait_cnt <= 32'd0;
                    S_send     <= 1'b1;
                    S_pc       <= 8'd0;
                end else begin
                    S_wait_cnt <= S_wait_cnt + 1'b1;
                end
            end else begin
                // 握手：S_uart_ready 是组合输出（uart_tx IDLE 即 1）。uart 捕获字节那一拍
                // ready 仍为 1，若据此推进 S_pc 会同拍重复自增 → 每发 1 字节跳过 1 字节
                // （偶数字节正确、奇数全丢）。故：ready 且未在发脉冲时启动一字节；uart 捕获后
                // 变忙（!ready）才结束脉冲并推进 S_pc。
                if (!S_valid && S_uart_ready) begin
                    S_data  <= ln[S_pc];
                    S_valid <= 1'b1;
                end else if (S_valid && !S_uart_ready) begin
                    S_valid <= 1'b0;
                    if (S_pc == LAST) begin
                        S_send <= 1'b0;
                    end else begin
                        S_pc <= S_pc + 1'b1;
                    end
                end
            end
        end
    end

endmodule
