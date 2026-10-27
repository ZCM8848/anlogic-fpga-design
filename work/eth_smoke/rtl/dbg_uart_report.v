// dbg_uart_report.v — 每秒打印一行 RX 状态（COM4, 115200 8N1）
//
//   格式：  N=XXXX A=XXXX M=XXXXXXXXXXXX\r\n
//     N = 收到的帧总数（16 位 hex）
//     A = 命中 ARP reply 的次数（16 位 hex）
//     M = 学到的对端 MAC（12 位 hex，A8-2B-DD-29-A4-CE → A82BDD29A4CE）
//
// 例：  N=0123 A=0045 M=A82BDD29A4CE
//
// 用 50 MHz 域时钟；mac 由上层做好跨时钟域（静态 + toggle 握手）。
//
`timescale 1ns/1ps

module dbg_uart_report #(
    parameter CLK_FREQ = 50_000_000
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire [15:0] frames,
    input  wire [15:0] tx_frames,
    input  wire [47:0] mac,

    output wire        uart_valid,
    output wire [7:0]  uart_data,
    input  wire        uart_ready
);

    // ------------------------------------------------------------------
    // 1 秒节拍
    // ------------------------------------------------------------------
    localparam integer TICK = CLK_FREQ;      // 50_000_000
    reg [31:0] tick_cnt;
    reg        tick;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tick_cnt <= 32'd0;
            tick     <= 1'b0;
        end else if (tick_cnt >= TICK - 1) begin
            tick_cnt <= 32'd0;
            tick     <= 1'b1;
        end else begin
            tick_cnt <= tick_cnt + 32'd1;
            tick     <= 1'b0;
        end
    end

    // ------------------------------------------------------------------
    // 锁存本次要打印的值
    // ------------------------------------------------------------------
    reg [15:0] lat_n, lat_a;
    reg [47:0] lat_m;

    // ------------------------------------------------------------------
    // 字符生成
    // ------------------------------------------------------------------
    localparam [5:0] MSG_LEN = 6'd30;

    function [7:0] hexc(input [3:0] v);
        begin
            hexc = (v <= 4'd9) ? (8'h30 + {4'd0, v}) : (8'h37 + {4'd0, v});
        end
    endfunction

    function [7:0] msg_char(input [5:0] i);
        begin
            case (i)
                6'd0 : msg_char = "N";
                6'd1 : msg_char = "=";
                6'd2 : msg_char = hexc(lat_n[15:12]);
                6'd3 : msg_char = hexc(lat_n[11:8]);
                6'd4 : msg_char = hexc(lat_n[7:4]);
                6'd5 : msg_char = hexc(lat_n[3:0]);
                6'd6 : msg_char = " ";
                6'd7 : msg_char = "T";
                6'd8 : msg_char = "=";
                6'd9 : msg_char = hexc(lat_a[15:12]);
                6'd10: msg_char = hexc(lat_a[11:8]);
                6'd11: msg_char = hexc(lat_a[7:4]);
                6'd12: msg_char = hexc(lat_a[3:0]);
                6'd13: msg_char = " ";
                6'd14: msg_char = "M";
                6'd15: msg_char = "=";
                6'd16: msg_char = hexc(lat_m[47:44]);
                6'd17: msg_char = hexc(lat_m[43:40]);
                6'd18: msg_char = hexc(lat_m[39:36]);
                6'd19: msg_char = hexc(lat_m[35:32]);
                6'd20: msg_char = hexc(lat_m[31:28]);
                6'd21: msg_char = hexc(lat_m[27:24]);
                6'd22: msg_char = hexc(lat_m[23:20]);
                6'd23: msg_char = hexc(lat_m[19:16]);
                6'd24: msg_char = hexc(lat_m[15:12]);
                6'd25: msg_char = hexc(lat_m[11:8]);
                6'd26: msg_char = hexc(lat_m[7:4]);
                6'd27: msg_char = hexc(lat_m[3:0]);
                6'd28: msg_char = 8'h0D;
                6'd29: msg_char = 8'h0A;
                default: msg_char = 8'h20;
            endcase
        end
    endfunction

    // ------------------------------------------------------------------
    // 发送序列
    // ------------------------------------------------------------------
    localparam ST_IDLE = 1'b0,
               ST_SEND = 1'b1;

    reg       st;
    reg [5:0] ci;
    reg       vld;
    reg [7:0] dat;

    assign uart_valid = vld;
    assign uart_data  = dat;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st     <= ST_IDLE;
            ci     <= 6'd0;
            vld    <= 1'b0;
            dat    <= 8'h00;
            lat_n  <= 16'd0;
            lat_a  <= 16'd0;
            lat_m  <= 48'd0;
        end else begin
            if (st == ST_IDLE) begin
                vld <= 1'b0;
                if (tick) begin
                    lat_n <= frames;
                    lat_a <= tx_frames;
                    lat_m <= mac;
                    ci    <= 6'd0;
                    st    <= ST_SEND;
                end
            end else begin
                // 握手：valid 一直保持到 uart_ready 变低（UART 已接受），
                // 然后再撤销 valid 并前进到下一个字符。
                // 注意：**不能**在这之前无条件写 vld<=0，否则 UART 还没采样
                //       valid 就被清掉，ci 永远不前进（会把整条上游逻辑优化掉）。
                if (!vld && uart_ready) begin
                    dat <= msg_char(ci);
                    vld <= 1'b1;
                end else if (vld && !uart_ready) begin
                    vld <= 1'b0;
                    if (ci == MSG_LEN - 1) begin
                        ci <= 6'd0;
                        st <= ST_IDLE;
                    end else begin
                        ci <= ci + 6'd1;
                    end
                end
            end
        end
    end

endmodule
