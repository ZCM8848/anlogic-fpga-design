`timescale 1ns / 1ps
//=============================================================================
// cam_report.v — 把摄像头初始化结果打印到串口（自研，M2）
//
// 输出格式（每 REPEAT_MS 重复一次，便于随时接串口看）：
//   CAM ID=<pre4> ADR=<dev2> W=<cnt2> P=<post4> OK=<0/1> E=<code1>\r\n
//   例：CAM ID=EE4B ADR=36 W=A5 P=9E4B OK=1 E=0
//   ID= 上电读到的 0x3107/0x3108（未加载寄存器表时应为 EE4B）
//   P=  寄存器表加载后复读的 0x3107/0x3108（应为 9E4B）
//   W=  成功写入的寄存器条数（16 进制，A5=165）
//   E=  错误码：0 正常 / 1 无 I2C 应答 / 2 写表 NAK / 4 ID 不符
//=============================================================================
module cam_report #(
    parameter CLK_FREQ  = 100_000_000,
    parameter BAUD      = 115200,
    parameter REPEAT_MS = 500
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire [15:0] D_id_pre,
    input  wire [15:0] D_id_post,
    input  wire [6:0]  D_dev,
    input  wire [8:0]  D_wr_cnt,
    input  wire [3:0]  D_err,

    output wire        O_uart_tx
);

    localparam [5:0]  LAST       = 6'd40;
    localparam integer REPEAT_CYC = (CLK_FREQ / 1000) * REPEAT_MS;

    function [7:0] hx(input [3:0] v);
        hx = (v < 4'd10) ? (8'h30 + {4'b0, v}) : (8'h37 + {4'b0, v});
    endfunction

    reg [5:0]   pc;
    reg         sending;
    reg [26:0]  rt;
    reg  [7:0]  txt;
    wire        tx_ready;
    wire        U_tx_valid;

    // ---- 字符发生器 ----
    always @(*) begin
        case (pc)
            6'd0:  txt = "C";
            6'd1:  txt = "A";
            6'd2:  txt = "M";
            6'd3:  txt = " ";
            6'd4:  txt = "I";
            6'd5:  txt = "D";
            6'd6:  txt = "=";
            6'd7:  txt = hx(D_id_pre[15:12]);
            6'd8:  txt = hx(D_id_pre[11:8]);
            6'd9:  txt = hx(D_id_pre[7:4]);
            6'd10: txt = hx(D_id_pre[3:0]);
            6'd11: txt = " ";
            6'd12: txt = "A";
            6'd13: txt = "D";
            6'd14: txt = "R";
            6'd15: txt = "=";
            6'd16: txt = hx({1'b0, D_dev[6:4]});
            6'd17: txt = hx({1'b0, D_dev[3:0]});
            6'd18: txt = " ";
            6'd19: txt = "W";
            6'd20: txt = "=";
            6'd21: txt = hx(D_wr_cnt[7:4]);
            6'd22: txt = hx(D_wr_cnt[3:0]);
            6'd23: txt = " ";
            6'd24: txt = "P";
            6'd25: txt = "=";
            6'd26: txt = hx(D_id_post[15:12]);
            6'd27: txt = hx(D_id_post[11:8]);
            6'd28: txt = hx(D_id_post[7:4]);
            6'd29: txt = hx(D_id_post[3:0]);
            6'd30: txt = " ";
            6'd31: txt = "O";
            6'd32: txt = "K";
            6'd33: txt = "=";
            6'd34: txt = (D_err == 4'd0) ? "1" : "0";
            6'd35: txt = " ";
            6'd36: txt = "E";
            6'd37: txt = "=";
            6'd38: txt = hx(D_err);
            6'd39: txt = 8'h0D;
            6'd40: txt = 8'h0A;
            default: txt = 8'h20;
        endcase
    end

    // ---- 发送节奏控制（每 REPEAT_MS 重发一整条） ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc      <= 6'd0;
            sending <= 1'b0;
            rt      <= 27'd0;
        end else if (!sending) begin
            if (rt >= REPEAT_CYC - 1) begin
                rt      <= 27'd0;
                sending <= 1'b1;
                pc      <= 6'd0;
            end else begin
                rt <= rt + 27'd1;
            end
        end else begin
            if (tx_ready) begin
                if (pc == LAST) sending <= 1'b0;
                else            pc      <= pc + 6'd1;
            end
        end
    end

    assign U_tx_valid = sending & tx_ready;

    uart_tx #(
        .CLK_FREQ (CLK_FREQ),
        .BAUD     (BAUD)
    ) u_uart_tx (
        .clk      (clk),
        .rst_n    (rst_n),
        .I_valid  (U_tx_valid),
        .I_data   (txt),
        .O_tx     (O_uart_tx),
        .O_ready  (tx_ready)
    );

endmodule
