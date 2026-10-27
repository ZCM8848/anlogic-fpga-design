// udp_test_gen.v — UDP 视频流的"假数据"源（M2 联调用）
//
// 每帧发 PKT_TOTAL 个包，包与包之间背靠背（IFG 由 MAC 保证），
// 帧与帧之间按 FRAME_PERIOD_CYCLES 定时。
//
// 负载是可预测图案：pay_data = pay_idx[7:0] ^ pkt_idx[7:0] ^ frame_id[7:0]
// PC 端可用它逐字节校验有没有丢包/错位。
//
`timescale 1ns/1ps

module udp_test_gen #(
    parameter [15:0] PKT_TOTAL           = 16'd800,
    parameter [31:0] FRAME_PERIOD_CYCLES = 32'd2_083_333   // 60 fps @125MHz
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        busy,          // eth_udp_tx 忙
    input  wire        done,          // eth_udp_tx 包结束脉冲

    output reg         req,           // 电平请求
    output reg  [15:0] frame_id,
    output reg  [15:0] pkt_idx,
    output wire [15:0] pkt_total,

    output wire [7:0]  pay_data,
    input  wire [10:0] pay_idx
);

    assign pkt_total = PKT_TOTAL;

    // ------------------------------------------------------------------
    // 帧周期计时
    // ------------------------------------------------------------------
    reg [31:0] timer;
    reg        tick;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            timer <= 32'd0;
            tick  <= 1'b0;
        end else if (timer >= FRAME_PERIOD_CYCLES - 1) begin
            timer <= 32'd0;
            tick  <= 1'b1;
        end else begin
            timer <= timer + 32'd1;
            tick  <= 1'b0;
        end
    end

    // ------------------------------------------------------------------
    // 包序列
    // ------------------------------------------------------------------
    localparam S_IDLE  = 1'b0,
               S_FRAME = 1'b1;

    reg st;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st       <= S_IDLE;
            req      <= 1'b0;
            frame_id <= 16'd0;
            pkt_idx  <= 16'd0;
        end else begin
            case (st)
                S_IDLE: begin
                    if (tick) begin
                        pkt_idx <= 16'd0;
                        req     <= 1'b1;
                        st      <= S_FRAME;
                    end
                end

                S_FRAME: begin
                    if (done) begin
                        if (pkt_idx == PKT_TOTAL - 1) begin
                            frame_id <= frame_id + 16'd1;
                            req      <= 1'b0;
                            st       <= S_IDLE;
                        end else begin
                            pkt_idx <= pkt_idx + 16'd1;
                        end
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // 可预测的测试图案
    // ------------------------------------------------------------------
    assign pay_data = pay_idx[7:0] ^ pkt_idx[7:0] ^ frame_id[7:0];

endmodule
