`timescale 1ns / 1ps
//=============================================================================
// uart_tx.v — 简单 UART 发送器（自研，M2 调试通道）
//   115200 8N1；I_valid 在 O_ready=1 时拉高即被接收（单周期即可）。
//   帧结构：起始位 + 8 数据位(LSB 先) + 停止位。
//=============================================================================
module uart_tx #(
    parameter CLK_FREQ = 100_000_000,
    parameter BAUD     = 115200
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       I_valid,
    input  wire [7:0] I_data,
    output reg        O_tx,
    output wire       O_ready
);

    localparam integer DIV = CLK_FREQ / BAUD;      // 每位时钟数（100M/115200 = 868）

    localparam [0:0] ST_IDLE = 1'b0,
                     ST_SEND = 1'b1;

    reg [0:0]  st;
    reg [9:0]  sh;      // {停止位, data[7:0], 起始位}
    reg [3:0]  bidx;    // 当前位 0..9
    reg [16:0] cnt;

    assign O_ready = (st == ST_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st   <= ST_IDLE;
            O_tx <= 1'b1;
            sh   <= 10'h3FF;
            bidx <= 4'd0;
            cnt  <= 17'd0;
        end else if (st == ST_IDLE) begin
            O_tx <= 1'b1;
            if (I_valid) begin
                sh   <= {1'b1, I_data, 1'b0};
                bidx <= 4'd0;
                cnt  <= 17'd0;
                O_tx <= 1'b0;                 // 起始位
                st   <= ST_SEND;
            end
        end else begin
            if (cnt == DIV - 1) begin
                cnt <= 17'd0;
                if (bidx == 4'd9) begin
                    st   <= ST_IDLE;
                    O_tx <= 1'b1;
                end else begin
                    bidx <= bidx + 1'b1;
                    O_tx <= sh[bidx + 1'b1];
                end
            end else begin
                cnt <= cnt + 1'b1;
            end
        end
    end

endmodule
