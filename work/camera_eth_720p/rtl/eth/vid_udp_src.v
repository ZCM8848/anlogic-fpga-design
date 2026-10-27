// vid_udp_src.v — 把摄像头字节流切成 UDP 包（1440 字节/包，800 包/帧）
//
// 数据是流式的（从摄像头 FIFO 出来），所以必须**等 FIFO 攒够一个包**才启动，
// 否则 GMII 会中途断流（包尾会变成上一包的残留，接收端按 FCS 丢弃）。
//
// 帧计数完全由包数决定：720p RAW10 一帧 = 1,152,000 字节 = 800×1440，整除。
// 摄像头的 frame_start 不参与控制（它只在字节被消费时才可见，若用它启动会死锁），
// 只作为状态指示。
//
`timescale 1ns/1ps

module vid_udp_src #(
    parameter [10:0] START_WORDS = 11'd292,      // FIFO 至少 292 字 = 1460 字节
    parameter [15:0] PKT_TOTAL   = 16'd800
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire [10:0] avail_words,   // 40bit FIFO 已用字数
    input  wire        frame_start,   // 摄像头帧起始（仅状态）

    output reg         req,
    output reg  [15:0] frame_id,
    output reg  [15:0] pkt_idx,
    output wire [15:0] pkt_total,

    input  wire        done           // eth_udp_tx 包结束
);

    assign pkt_total = PKT_TOTAL;

    localparam S_IDLE = 2'd0,   // 等有数据
               S_WAIT = 2'd1,   // 等攒够一个包
               S_SEND = 2'd2;   // 正在发一个包

    reg [1:0] st;

    wire enough = (avail_words >= START_WORDS);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st       <= S_IDLE;
            req      <= 1'b0;
            frame_id <= 16'd0;
            pkt_idx  <= 16'd0;
        end else begin
            case (st)
                S_IDLE: begin
                    req <= 1'b0;
                    if (enough) begin
                        frame_id <= frame_id + 16'd1;
                        pkt_idx  <= 16'd0;
                        req      <= 1'b1;
                        st       <= S_SEND;
                    end
                end

                S_WAIT: begin
                    if (enough) begin
                        req <= 1'b1;
                        st  <= S_SEND;
                    end
                end

                S_SEND: begin
                    if (done) begin
                        req <= 1'b0;
                        if (pkt_idx == PKT_TOTAL - 1) begin
                            st <= S_IDLE;              // 一帧发完
                        end else begin
                            pkt_idx <= pkt_idx + 16'd1;
                            st      <= S_WAIT;         // 等攒够下一个包
                        end
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
