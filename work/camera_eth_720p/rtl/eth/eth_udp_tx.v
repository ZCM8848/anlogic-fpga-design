// eth_udp_tx.v — 以太网 + IPv4 + UDP 帧发送器（固定 1440 字节数据/包）
//
// 帧结构（字节索引）：
//    0..6    0x55 x7          前导码
//    7       0xD5             SFD
//    8..21   Ethernet 头      DA(6) + SA(6) + Type(0x0800)
//   22..41   IPv4 头 20B      (总长 1476，UDP，TTL 64)
//   42..49   UDP 头 8B        (0x1234 -> 0x1234，长度 1456，校验和 0)
//   50..57   应用头 8B        AA 55 | frame_id(2) | pkt_idx(2) | pkt_total(2)
//   58..1497 数据 1440B       ← 外部组合返回 pay_data
//  1498..1501 FCS 4B         CRC32 小端
//  合计 1502 字节（含前导码）
//
// 800 包 × 1440B = 1,152,000B = 1280×720×10bit 的一整帧 RAW10
//
// 时序说明（关键）：
//   txd 在 idx=k 时装载 byte(k)，下一拍真正上线；
//   同一拍把 byte(k) 也送进 CRC，所以 idx 走到 1498 时 CRC 刚好算完，
//   此时装载的 fcs[7:0] 直接用当前 crc 即可，不需要额外一拍。
//
`timescale 1ns/1ps

module eth_udp_tx #(
    parameter [15:0] DATA_BYTES = 16'd1440,
    parameter [15:0] IP_TOTAL   = 16'd1476,   // 20 + 8 + 8 + DATA_BYTES
    parameter [15:0] UDP_LEN    = 16'd1456,   // 8 + 8 + DATA_BYTES
    parameter [15:0] SRC_PORT   = 16'h1234,
    parameter [15:0] DST_PORT   = 16'h1234
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        req,          // 电平请求；busy=0 时启动一个包
    input  wire [47:0] dst_mac,
    input  wire [47:0] src_mac,
    input  wire [15:0] frame_id,
    input  wire [15:0] pkt_idx,
    input  wire [15:0] pkt_total,

    input  wire [7:0]  pay_data,     // 流式载荷：本拍有效（只在数据区被消费）
    output wire        pay_rd,       // 消费一个载荷字节

    output wire        busy,
    output reg         done,         // 包结束 1 拍脉冲（在 IFG 期间）
    output reg         gmii_tx_en,
    output reg  [7:0]  gmii_txd
);

    // ------------------------------------------------------------------
    // 字节边界
    // ------------------------------------------------------------------
    localparam [10:0] IDX_ETH  = 11'd8;
    localparam [10:0] IDX_DATA = 11'd58;
    localparam [10:0] IDX_FCS  = 11'd58 + DATA_BYTES[10:0];
    localparam [10:0] IDX_END  = IDX_FCS + 11'd4;

    // ------------------------------------------------------------------
    // 状态机寄存器（先声明，后面组合逻辑要用）
    // ------------------------------------------------------------------
    localparam S_IDLE = 2'd0,
               S_TX   = 2'd1,
               S_IFG  = 2'd2;

    reg [1:0]  st;
    reg [10:0] idx;
    reg [3:0]  ifg_cnt;
    reg        crc_init;

    assign busy = (st != S_IDLE);

    // IPv4 校验和：常量部分 0x098F + 总长，再回卷取反 → 1476 时 = 0xF0AC
    wire [16:0] ip_sum  = 17'h098F + {1'b0, IP_TOTAL};
    wire [15:0] ip_sum2 = ip_sum[15:0] + {15'd0, ip_sum[16]};
    wire [15:0] ip_ck   = ~ip_sum2;

    // CRC（先声明，字节选择里要用 crc 输出）
    wire [31:0] crc;
    wire [31:0] crc_next;
    wire        crc_en = (st == S_TX) && (idx >= IDX_ETH) && (idx < IDX_FCS);

    // ------------------------------------------------------------------
    // 字节选择
    // ------------------------------------------------------------------
    reg [7:0] b;
    always @(*) begin
        b = 8'h00;
        case (idx)
            11'd0, 11'd1, 11'd2, 11'd3, 11'd4, 11'd5, 11'd6 : b = 8'h55;
            11'd7                                            : b = 8'hD5;

            // ---- Ethernet ----
            11'd8  : b = dst_mac[47:40];
            11'd9  : b = dst_mac[39:32];
            11'd10 : b = dst_mac[31:24];
            11'd11 : b = dst_mac[23:16];
            11'd12 : b = dst_mac[15:8];
            11'd13 : b = dst_mac[7:0];
            11'd14 : b = src_mac[47:40];
            11'd15 : b = src_mac[39:32];
            11'd16 : b = src_mac[31:24];
            11'd17 : b = src_mac[23:16];
            11'd18 : b = src_mac[15:8];
            11'd19 : b = src_mac[7:0];
            11'd20 : b = 8'h08;
            11'd21 : b = 8'h00;

            // ---- IPv4 ----
            11'd22 : b = 8'h45;                  // ver 4 / IHL 5
            11'd23 : b = 8'h00;                  // TOS
            11'd24 : b = IP_TOTAL[15:8];
            11'd25 : b = IP_TOTAL[7:0];
            11'd26 : b = 8'h00;                  // ID
            11'd27 : b = 8'h00;
            11'd28 : b = 8'h00;                  // flags / frag
            11'd29 : b = 8'h00;
            11'd30 : b = 8'h40;                  // TTL 64
            11'd31 : b = 8'h11;                  // UDP
            11'd32 : b = ip_ck[15:8];
            11'd33 : b = ip_ck[7:0];
            11'd34 : b = 8'hC0;                  // 192.168.1.200
            11'd35 : b = 8'hA8;
            11'd36 : b = 8'h01;
            11'd37 : b = 8'hC8;
            11'd38 : b = 8'hC0;                  // 192.168.1.100
            11'd39 : b = 8'hA8;
            11'd40 : b = 8'h01;
            11'd41 : b = 8'h64;

            // ---- UDP ----
            11'd42 : b = SRC_PORT[15:8];
            11'd43 : b = SRC_PORT[7:0];
            11'd44 : b = DST_PORT[15:8];
            11'd45 : b = DST_PORT[7:0];
            11'd46 : b = UDP_LEN[15:8];
            11'd47 : b = UDP_LEN[7:0];
            11'd48 : b = 8'h00;                  // checksum = 0（IPv4 允许）
            11'd49 : b = 8'h00;

            // ---- 应用头 ----
            11'd50 : b = 8'hAA;
            11'd51 : b = 8'h55;
            11'd52 : b = frame_id[15:8];
            11'd53 : b = frame_id[7:0];
            11'd54 : b = pkt_idx[15:8];
            11'd55 : b = pkt_idx[7:0];
            11'd56 : b = pkt_total[15:8];
            11'd57 : b = pkt_total[7:0];

            default: b = 8'h00;
        endcase

        if (idx >= IDX_DATA && idx < IDX_FCS) b = pay_data;   // 数据区

        if (idx == IDX_FCS)         b = ~crc[7:0];
        if (idx == IDX_FCS + 11'd1) b = ~crc[15:8];
        if (idx == IDX_FCS + 11'd2) b = ~crc[23:16];
        if (idx == IDX_FCS + 11'd3) b = ~crc[31:24];
    end

    assign pay_rd = (st == S_TX) && (idx >= IDX_DATA) && (idx < IDX_FCS);

    // ------------------------------------------------------------------
    // CRC 实例
    // ------------------------------------------------------------------

    crc32_eth_nib u_crc (
        .clk      ( clk      ),
        .rst_n    ( rst_n    ),
        .init     ( crc_init ),
        .en       ( crc_en   ),
        .data     ( b        ),
        .crc      ( crc      ),
        .crc_next ( crc_next )
    );

    // ------------------------------------------------------------------
    // 发送状态机
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st         <= S_IDLE;
            idx        <= 11'd0;
            ifg_cnt    <= 4'd0;
            gmii_tx_en <= 1'b0;
            gmii_txd   <= 8'h00;
            done       <= 1'b0;
            crc_init   <= 1'b0;
        end else begin
            done     <= 1'b0;
            crc_init <= 1'b0;

            case (st)
                S_IDLE: begin
                    gmii_tx_en <= 1'b0;
                    if (req) begin
                        gmii_tx_en <= 1'b1;
                        gmii_txd   <= b;          // byte(0) = 0x55
                        idx        <= 11'd1;
                        crc_init   <= 1'b1;
                        st         <= S_TX;
                    end
                end

                S_TX: begin
                    gmii_tx_en <= 1'b1;
                    gmii_txd   <= b;
                    if (idx == IDX_END) begin
                        gmii_tx_en <= 1'b0;
                        done       <= 1'b1;
                        ifg_cnt    <= 4'd0;
                        st         <= S_IFG;
                    end else begin
                        idx <= idx + 11'd1;
                    end
                end

                S_IFG: begin
                    gmii_tx_en <= 1'b0;
                    gmii_txd   <= 8'h00;
                    if (ifg_cnt >= 4'd11) st <= S_IDLE;
                    else ifg_cnt <= ifg_cnt + 4'd1;
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
