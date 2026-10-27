// arp_rx.v — 从接收字节流里解析 ARP reply，学习对端 MAC/IP
//
// 只依赖 eth_rx_mac 的字节流接口（frame_idx 对齐 frame_data）。
// 校验条件（不需要 CRC 也足够可靠）：
//   EtherType == 0x0806
//   opcode    == 2 (reply)
//   target IP == 192.168.1.200（本机）
//   frame_len >= 42
//
// 输出：
//   arp_hit      : 1 拍脉冲（每收到一个合格 reply）
//   peer_mac     : 最近一次的 sender MAC
//   peer_ip      : 最近一次的 sender IP
//   arp_cnt      : 累计命中次数
//   rx_frame_cnt : 累计收到的帧数（含非 ARP）
//
`timescale 1ns/1ps

module arp_rx #(
    parameter [31:0] LOCAL_IP = 32'hC0A801C8    // 192.168.1.200
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        frame_start,
    input  wire [7:0]  frame_data,
    input  wire [10:0] frame_idx,
    input  wire        frame_byte_v,
    input  wire        frame_end,
    input  wire [10:0] frame_len,
    input  wire        frame_err,

    output reg         arp_hit,
    output reg  [47:0] peer_mac,
    output reg  [31:0] peer_ip,
    output reg  [15:0] arp_cnt,
    output reg  [15:0] rx_frame_cnt
);

    reg [15:0] eth_type;
    reg [7:0]  op_hi, op_lo;
    reg [47:0] sha;
    reg [31:0] spa;
    reg [31:0] tpa;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            arp_hit      <= 1'b0;
            peer_mac     <= 48'd0;
            peer_ip      <= 32'd0;
            arp_cnt      <= 16'd0;
            rx_frame_cnt <= 16'd0;
            eth_type     <= 16'd0;
            op_hi        <= 8'd0;
            op_lo        <= 8'd0;
            sha          <= 48'd0;
            spa          <= 32'd0;
            tpa          <= 32'd0;
        end else begin
            arp_hit <= 1'b0;

            if (frame_start) begin
                eth_type <= 16'd0;
                op_hi    <= 8'd0;
                op_lo    <= 8'd0;
                sha      <= 48'd0;
                spa      <= 32'd0;
                tpa      <= 32'd0;
            end

            if (frame_byte_v) begin
                case (frame_idx)
                    11'd12 : eth_type[15:8] <= frame_data;
                    11'd13 : eth_type[7:0]  <= frame_data;
                    11'd20 : op_hi          <= frame_data;
                    11'd21 : op_lo          <= frame_data;
                    11'd22, 11'd23, 11'd24,
                    11'd25, 11'd26, 11'd27 : sha <= {sha[39:0], frame_data};
                    11'd28, 11'd29,
                    11'd30, 11'd31         : spa <= {spa[23:0], frame_data};
                    11'd38, 11'd39,
                    11'd40, 11'd41         : tpa <= {tpa[23:0], frame_data};
                    default: ;
                endcase
            end

            if (frame_end) begin
                rx_frame_cnt <= rx_frame_cnt + 16'd1;

                if (!frame_err && frame_len >= 11'd42 &&
                    eth_type == 16'h0806 && op_hi == 8'h00 && op_lo == 8'h02 &&
                    tpa == LOCAL_IP) begin
                    arp_hit  <= 1'b1;
                    peer_mac <= sha;
                    peer_ip  <= spa;
                    arp_cnt  <= arp_cnt + 16'd1;
                end
            end
        end
    end

endmodule
