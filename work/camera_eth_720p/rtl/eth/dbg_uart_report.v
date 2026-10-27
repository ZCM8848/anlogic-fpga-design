// dbg_uart_report.v — 每秒打印一行状态（COM4, 115200 8N1）
//
//   N=XXXX T=XXXX C=XXXX S=XXXX V=X\r\n        （33 字符）
//     N = 以太网 RX 收帧数
//     T = 已发送的视频帧数（frame_id）
//     C = 摄像头 RAW10 帧计数
//     S = 传感器 ID（I2C 读回，0x56C0 之类；0 表示没读到）
//     V = 状态位  bit0=cfg_done  bit1=sensor_ok  bit2=fifo_ovf  bit3=rx_alive
//
`timescale 1ns/1ps

module dbg_uart_report #(
    parameter CLK_FREQ = 50_000_000
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire [15:0] rx_frames,
    input  wire [15:0] tx_frames,
    input  wire [15:0] cam_frames,
    input  wire [15:0] sensor_id,
    input  wire [3:0]  status,

    output wire        uart_valid,
    output wire [7:0]  uart_data,
    input  wire        uart_ready
);

    // 1 秒节拍
    localparam integer TICK = CLK_FREQ;
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

    reg [15:0] lat_n, lat_t, lat_c, lat_s;
    reg [3:0]  lat_v;

    localparam [5:0] MSG_LEN = 6'd33;

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
                6'd9 : msg_char = hexc(lat_t[15:12]);
                6'd10: msg_char = hexc(lat_t[11:8]);
                6'd11: msg_char = hexc(lat_t[7:4]);
                6'd12: msg_char = hexc(lat_t[3:0]);
                6'd13: msg_char = " ";
                6'd14: msg_char = "C";
                6'd15: msg_char = "=";
                6'd16: msg_char = hexc(lat_c[15:12]);
                6'd17: msg_char = hexc(lat_c[11:8]);
                6'd18: msg_char = hexc(lat_c[7:4]);
                6'd19: msg_char = hexc(lat_c[3:0]);
                6'd20: msg_char = " ";
                6'd21: msg_char = "S";
                6'd22: msg_char = "=";
                6'd23: msg_char = hexc(lat_s[15:12]);
                6'd24: msg_char = hexc(lat_s[11:8]);
                6'd25: msg_char = hexc(lat_s[7:4]);
                6'd26: msg_char = hexc(lat_s[3:0]);
                6'd27: msg_char = " ";
                6'd28: msg_char = "V";
                6'd29: msg_char = "=";
                6'd30: msg_char = hexc(lat_v);
                6'd31: msg_char = 8'h0D;
                6'd32: msg_char = 8'h0A;
                default: msg_char = 8'h20;
            endcase
        end
    endfunction

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
            st    <= ST_IDLE;
            ci    <= 6'd0;
            vld   <= 1'b0;
            dat   <= 8'h00;
            lat_n <= 16'd0;
            lat_t <= 16'd0;
            lat_c <= 16'd0;
            lat_s <= 16'd0;
            lat_v <= 4'd0;
        end else begin
            if (st == ST_IDLE) begin
                vld <= 1'b0;
                if (tick) begin
                    lat_n <= rx_frames;
                    lat_t <= tx_frames;
                    lat_c <= cam_frames;
                    lat_s <= sensor_id;
                    lat_v <= status;
                    ci    <= 6'd0;
                    st    <= ST_SEND;
                end
            end else begin
                // valid 必须保持到 UART 接受（ready 变低）之后再撤销
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
