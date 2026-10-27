`timescale 1ns / 1ps
//=============================================================================
// mdio_status_print.v — MDIO 调试状态串口上报
//
// 每 REPEAT_MS 连发一行（115200 8N1）：
//   MDIO ad=XX id1=XXXX id2=XXXX v=X lk=X bs=X ml=X pl=X ta=X\r\n
//
// 字段：
//   ad  = PHY_ADDR（0..31）
//   id1/id2 = PHYSID1/2
//   v   = phy_id_valid
//   lk  = link_up
//   bs  = mdio_busy
//   ml  = mdio_low_flag（MDIO 线曾为 0；1=master 在驱动帧）
//   pl  = mdio_phy_low（master 释放期间 MDIO=0；1=PHY 在驱动）
//   ta  = TA 期间 2 bit 采样值（bit46=Z应读1, bit47=ack应读0）
//         0x3=11=PHY没acknowledge；0x2=10=PHY ack了(TA bit1=0)
//=============================================================================
module mdio_status_print #(
    parameter CLK_FREQ  = 50_000_000,
    parameter BAUD      = 115200,
    parameter REPEAT_MS = 500
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire [4:0]  I_phy_addr_cur,
    input  wire [15:0] I_physid1,
    input  wire [15:0] I_physid2,
    input  wire        I_phy_id_valid,
    input  wire        I_link_up,
    input  wire        I_mdio_busy,
    input  wire        I_mdio_low,
    input  wire        I_mdio_phy_low,
    input  wire [1:0]  I_ta_sample,

    output wire        O_uart_tx
);

    localparam integer REPEAT_CYC = (CLK_FREQ / 1000) * REPEAT_MS;
    localparam [7:0]   LAST       = 8'd58;   // 0..58 = 59 字节

    function [7:0] hx(input [3:0] v);
        hx = (v < 4'd10) ? (8'h30 + {4'b0, v}) : (8'h37 + {4'b0, v});
    endfunction

    wire [7:0] ln [0:58];

    assign ln[0]  = "M";
    assign ln[1]  = "D";
    assign ln[2]  = "I";
    assign ln[3]  = "O";
    assign ln[4]  = " ";
    assign ln[5]  = "a";
    assign ln[6]  = "d";
    assign ln[7]  = "=";
    assign ln[8]  = hx({3'b0, I_phy_addr_cur[4]});
    assign ln[9]  = hx(I_phy_addr_cur[3:0]);
    assign ln[10] = " ";
    assign ln[11] = "i";
    assign ln[12] = "d";
    assign ln[13] = "1";
    assign ln[14] = "=";
    assign ln[15] = hx(I_physid1[15:12]);
    assign ln[16] = hx(I_physid1[11:8]);
    assign ln[17] = hx(I_physid1[7:4]);
    assign ln[18] = hx(I_physid1[3:0]);
    assign ln[19] = " ";
    assign ln[20] = "i";
    assign ln[21] = "d";
    assign ln[22] = "2";
    assign ln[23] = "=";
    assign ln[24] = hx(I_physid2[15:12]);
    assign ln[25] = hx(I_physid2[11:8]);
    assign ln[26] = hx(I_physid2[7:4]);
    assign ln[27] = hx(I_physid2[3:0]);
    assign ln[28] = " ";
    assign ln[29] = "v";
    assign ln[30] = "=";
    assign ln[31] = I_phy_id_valid ? "1" : "0";
    assign ln[32] = " ";
    assign ln[33] = "l";
    assign ln[34] = "k";
    assign ln[35] = "=";
    assign ln[36] = I_link_up      ? "1" : "0";
    assign ln[37] = " ";
    assign ln[38] = "b";
    assign ln[39] = "s";
    assign ln[40] = "=";
    assign ln[41] = I_mdio_busy    ? "1" : "0";
    assign ln[42] = " ";
    assign ln[43] = "m";
    assign ln[44] = "l";
    assign ln[45] = "=";
    assign ln[46] = I_mdio_low     ? "1" : "0";
    assign ln[47] = " ";
    assign ln[48] = "p";
    assign ln[49] = "l";
    assign ln[50] = "=";
    assign ln[51] = I_mdio_phy_low ? "1" : "0";
    assign ln[52] = " ";
    assign ln[53] = "t";
    assign ln[54] = "a";
    assign ln[55] = "=";
    assign ln[56] = hx({2'b0, I_ta_sample});
    assign ln[57] = 8'h0D;         // \r
    assign ln[58] = 8'h0A;         // \n

    // ---- 发送 FSM ----
    reg [31:0] S_wait_cnt;
    reg [7:0]  S_pc;
    reg        S_send;
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
