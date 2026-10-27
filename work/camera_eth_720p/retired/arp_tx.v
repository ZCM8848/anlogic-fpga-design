// arp_tx.v — ARP 请求帧生成器（RGMII TX 测试用）
//
// 每 5 秒自动发送一个 ARP 请求广播帧，让 PC 端 Wireshark 能抓到。
// 验证 RGMII TX 通路 + PHY 是否工作。
//
// 输出 GMII 8-bit @ 125MHz，供 rgmii_tx_ddr 转 DDR 4-bit。
//
// 帧结构（共 64 字节 = 7 PRE + 1 SFD + 42 DATA + 4 FCS）：
//   Preamble: 7 × 0x55
//   SFD:      1 × 0xD5
//   Dst MAC:  FF FF FF FF FF FF（广播）
//   Src MAC:  01 23 45 67 89 AB
//   Ethertype:08 06（ARP）
//   ARP payload (28B): hw=0001, proto=0800, hlen=06, plen=04, op=0001,
//                      sender_mac=01:23:45:67:89:AB, sender_ip=192.168.1.100,
//                      target_mac=00:00:00:00:00:00, target_ip=192.168.1.1
//   FCS:      4 × CRC32（自动计算）
//
`timescale 1ns/1ps

module arp_tx #(
    parameter SEND_INTERVAL_CYCLES = 125_000_000 * 1  // 1 秒 @ 125MHz
)(
    input  wire        clk_125,
    input  wire        rst_n,

    // GMII 输出（接 rgmii_tx_ddr）
    output reg  [7:0]  gmii_txd,
    output reg         gmii_tx_en,
    output wire        gmii_tx_er,

    // 状态（可选调试）
    output reg         tx_busy,
    output reg         frame_sent     // 锁存：发过帧后持续 1（LED 可见）
);

    // ---- ARP 帧 DATA（42 字节）----
    wire [7:0] FRAME_DATA [0:41];
    assign FRAME_DATA[0]  = 8'hFF;  // Dst MAC[0]
    assign FRAME_DATA[1]  = 8'hFF;  // Dst MAC[1]
    assign FRAME_DATA[2]  = 8'hFF;  // Dst MAC[2]
    assign FRAME_DATA[3]  = 8'hFF;  // Dst MAC[3]
    assign FRAME_DATA[4]  = 8'hFF;  // Dst MAC[4]
    assign FRAME_DATA[5]  = 8'hFF;  // Dst MAC[5]
    assign FRAME_DATA[6]  = 8'h01;  // Src MAC[0]
    assign FRAME_DATA[7]  = 8'h23;  // Src MAC[1]
    assign FRAME_DATA[8]  = 8'h45;  // Src MAC[2]
    assign FRAME_DATA[9]  = 8'h67;  // Src MAC[3]
    assign FRAME_DATA[10] = 8'h89;  // Src MAC[4]
    assign FRAME_DATA[11] = 8'hAB;  // Src MAC[5]
    assign FRAME_DATA[12] = 8'h08;  // Ethertype[0]
    assign FRAME_DATA[13] = 8'h06;  // Ethertype[1] (ARP)
    assign FRAME_DATA[14] = 8'h00;  // HW type[0]
    assign FRAME_DATA[15] = 8'h01;  // HW type[1] (Ethernet)
    assign FRAME_DATA[16] = 8'h08;  // Proto type[0]
    assign FRAME_DATA[17] = 8'h00;  // Proto type[1] (IPv4)
    assign FRAME_DATA[18] = 8'h06;  // HW addr len
    assign FRAME_DATA[19] = 8'h04;  // Proto addr len
    assign FRAME_DATA[20] = 8'h00;  // Operation[0]
    assign FRAME_DATA[21] = 8'h01;  // Operation[1] (ARP request)
    assign FRAME_DATA[22] = 8'h01;  // Sender MAC[0]
    assign FRAME_DATA[23] = 8'h23;  // Sender MAC[1]
    assign FRAME_DATA[24] = 8'h45;  // Sender MAC[2]
    assign FRAME_DATA[25] = 8'h67;  // Sender MAC[3]
    assign FRAME_DATA[26] = 8'h89;  // Sender MAC[4]
    assign FRAME_DATA[27] = 8'hAB;  // Sender MAC[5]
    assign FRAME_DATA[28] = 8'hC0;  // Sender IP[0] (192)
    assign FRAME_DATA[29] = 8'hA8;  // Sender IP[1] (168)
    assign FRAME_DATA[30] = 8'h01;  // Sender IP[2] (1)
    assign FRAME_DATA[31] = 8'hC8;  // Sender IP[3] (200) — 不和 PC(192.168.1.100) 冲突
    assign FRAME_DATA[32] = 8'h00;  // Target MAC[0]
    assign FRAME_DATA[33] = 8'h00;  // Target MAC[1]
    assign FRAME_DATA[34] = 8'h00;  // Target MAC[2]
    assign FRAME_DATA[35] = 8'h00;  // Target MAC[3]
    assign FRAME_DATA[36] = 8'h00;  // Target MAC[4]
    assign FRAME_DATA[37] = 8'h00;  // Target MAC[5]
    assign FRAME_DATA[38] = 8'hC0;  // Target IP[0] (192)
    assign FRAME_DATA[39] = 8'hA8;  // Target IP[1] (168)
    assign FRAME_DATA[40] = 8'h01;  // Target IP[2] (1)
    assign FRAME_DATA[41] = 8'h64;  // Target IP[3] (100, PC)

    // ---- CRC32（以太网 FCS）----
    reg [31:0] crc;
    reg [31:0] crc_next;
    wire [7:0] crc_byte;
    // CRC-32 反射算法（poly 0xEDB88320）
    function [7:0] reverse_byte(input [7:0] b);
        integer i;
        begin
            reverse_byte = 0;
            for (i = 0; i < 8; i = i + 1)
                reverse_byte[i] = b[7 - i];
        end
    endfunction

    // CRC-32 查找表（256 项，多项式 0xEDB88320）
    reg [31:0] crc_lut [0:255];
    integer ii;
    reg [31:0] crc_lut_c;
    integer crc_lut_j;
    initial begin
        for (ii = 0; ii < 256; ii = ii + 1) begin
            crc_lut_c = 32'h00000000;
            crc_lut_c[7:0] = ii[7:0];
            for (crc_lut_j = 0; crc_lut_j < 8; crc_lut_j = crc_lut_j + 1) begin
                if (crc_lut_c[0])
                    crc_lut_c = (crc_lut_c >> 1) ^ 32'hEDB88320;
                else
                    crc_lut_c = crc_lut_c >> 1;
            end
            crc_lut[ii] = crc_lut_c;
        end
    end

    wire [7:0] db = gmii_txd;   // 不反射：CRC-32 反射算法本身已处理反射
    wire [7:0] idx = crc[7:0] ^ db;
    // CRC next（通用，用于组合输出）
    // 注意：在 S_DATA 状态用 FRAME_DATA[byte_cnt] 计算 CRC（不是 gmii_txd），
    //   因为 gmii_txd 是上一拍赋的旧值，CRC 应基于当前要发的字节
    wire [7:0] crc_data = (state == S_DATA) ? FRAME_DATA[byte_cnt] : gmii_txd;
    wire [7:0] crc_idx  = crc[7:0] ^ crc_data;  // 不反射
    always @(*) begin
        crc_next = (crc >> 8) ^ crc_lut[crc_idx];
    end

    // 输出 FCS 字节（按字节输出，小端序）
    // CRC 最终值需要取反（XOR 0xFFFFFFFF）
    wire [31:0] fcs = ~crc;  // 帧尾取反
    // FCS 字节顺序：先发最低字节
    wire [7:0] fcs_b0 = fcs[7:0];
    wire [7:0] fcs_b1 = fcs[15:8];
    wire [7:0] fcs_b2 = fcs[24:16];
    wire [7:0] fcs_b3 = fcs[31:24];

    // ---- 状态机 ----
    localparam S_IDLE  = 4'd0;
    localparam S_PRE   = 4'd1;
    localparam S_SFD   = 4'd2;
    localparam S_DATA  = 4'd3;
    localparam S_FCS   = 4'd4;
    localparam S_IFG   = 4'd5;

    reg [3:0] state;
    reg [5:0] byte_cnt;    // 0..41 (DATA) / 0..3 (FCS) / 0..11 (IFG)
    reg [29:0] wait_cnt;   // 30 位（2^30 > 1G），5 秒等待 @ 125MHz = 625M 周期

    assign gmii_tx_er = 1'b0;

    always @(posedge clk_125 or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            byte_cnt   <= 0;
            wait_cnt   <= 0;
            gmii_txd   <= 8'd0;
            gmii_tx_en <= 1'b0;
            tx_busy    <= 1'b0;
            frame_sent <= 1'b0;
            crc        <= 32'hFFFFFFFF;
        end else begin
            case (state)
                S_IDLE: begin
                    gmii_tx_en <= 1'b0;
                    tx_busy   <= 1'b0;
                    if (wait_cnt >= SEND_INTERVAL_CYCLES - 1) begin
                        wait_cnt <= 0;
                        state    <= S_PRE;
                        byte_cnt <= 0;
                        crc      <= 32'hFFFFFFFF;
                    end else begin
                        wait_cnt <= wait_cnt + 1'b1;
                    end
                end

                S_PRE: begin
                    gmii_tx_en <= 1'b1;
                    tx_busy    <= 1'b1;
                    gmii_txd   <= 8'h55;    // Preamble
                    if (byte_cnt == 6) begin
                        state    <= S_SFD;
                        byte_cnt <= 0;
                    end else begin
                        byte_cnt <= byte_cnt + 1'b1;
                    end
                end

                S_SFD: begin
                    gmii_txd <= 8'hD5;       // SFD
                    state    <= S_DATA;
                    byte_cnt <= 0;
                end

                S_DATA: begin
                    gmii_txd <= FRAME_DATA[byte_cnt];
                    crc      <= crc_next;    // 更新 CRC
                    if (byte_cnt == 41) begin
                        state    <= S_FCS;
                        byte_cnt <= 0;
                    end else begin
                        byte_cnt <= byte_cnt + 1'b1;
                    end
                end

                S_FCS: begin
                    // 输出 FCS 4 字节（小端序）
                    case (byte_cnt)
                        0: gmii_txd <= fcs_b0;
                        1: gmii_txd <= fcs_b1;
                        2: gmii_txd <= fcs_b2;
                        3: gmii_txd <= fcs_b3;
                    endcase
                    if (byte_cnt == 3) begin
                        state    <= S_IFG;
                        byte_cnt <= 0;
                    end else begin
                        byte_cnt <= byte_cnt + 1'b1;
                    end
                end

                S_IFG: begin
                    gmii_tx_en <= 1'b0;
                    gmii_txd   <= 8'h00;     // IFG 空闲
                    if (byte_cnt == 11) begin
                        state       <= S_IDLE;
                        byte_cnt    <= 0;
                        frame_sent  <= 1'b1;  // 锁存：已发过帧
                    end else begin
                        byte_cnt <= byte_cnt + 1'b1;
                    end
                end
            endcase
        end
    end
endmodule
