// arp_frame_tx.v — 固定 ARP 请求帧发送器（128 字节，带自描述填充）
//
// 帧内容：DA..FCS 共 128 字节
//   0..41   : 标准 ARP 请求（广播，sender 192.168.1.200 → target 192.168.1.100）
//   42..123 : 填充 0xA0,0xA1,...,0xF1  ← 用于在抓到包时判断字节是否错位/重复
//   124..127: FCS（PC 端 zlib.crc32 预计算：F1 D4 3F 01）
//
// 帧格式检查（PC 端 Python）：
//   data = 前 124 字节
//   zlib.crc32(data) = 0x013FD4F1  → 线序 F1 D4 3F 01
//   zlib.crc32(全 128 字节) = 0x2144DF1C（以太网魔数）PASS
//
// 前导码：7 × 0x55 + 0xD5（S_PRE 输出 7 拍 0x55 的第 1 拍在进入时被吃掉，
//         所以 S_PRE 只数到 5，第 7 个 0x55 由 S_SFD 那一拍输出）
//
`timescale 1ns/1ps

module arp_frame_tx #(
    parameter SEND_INTERVAL_CYCLES = 32'd25_000_000   // 200 ms @ 125MHz
)(
    input  wire        clk,            // 125 MHz
    input  wire        rst_n,

    output reg  [7:0]  gmii_txd,
    output reg         gmii_tx_en,
    output wire        gmii_tx_er,

    output wire        tx_active,      // 正在发帧
    output reg         frame_sent      // 锁存：发过至少一帧
);

    // ------------------------------------------------------------------
    // 固定帧内容（128 字节，含 FCS）
    // ------------------------------------------------------------------
    function [7:0] frame_byte(input [6:0] idx);
        begin
            case (idx)
                7'd0  : frame_byte = 8'hFF;
                7'd1  : frame_byte = 8'hFF;
                7'd2  : frame_byte = 8'hFF;
                7'd3  : frame_byte = 8'hFF;
                7'd4  : frame_byte = 8'hFF;
                7'd5  : frame_byte = 8'hFF;
                7'd6  : frame_byte = 8'h01;
                7'd7  : frame_byte = 8'h23;
                7'd8  : frame_byte = 8'h45;
                7'd9  : frame_byte = 8'h67;
                7'd10 : frame_byte = 8'h89;
                7'd11 : frame_byte = 8'hAB;
                7'd12 : frame_byte = 8'h08;
                7'd13 : frame_byte = 8'h06;
                7'd14 : frame_byte = 8'h00;
                7'd15 : frame_byte = 8'h01;
                7'd16 : frame_byte = 8'h08;
                7'd17 : frame_byte = 8'h00;
                7'd18 : frame_byte = 8'h06;
                7'd19 : frame_byte = 8'h04;
                7'd20 : frame_byte = 8'h00;
                7'd21 : frame_byte = 8'h01;
                7'd22 : frame_byte = 8'h01;
                7'd23 : frame_byte = 8'h23;
                7'd24 : frame_byte = 8'h45;
                7'd25 : frame_byte = 8'h67;
                7'd26 : frame_byte = 8'h89;
                7'd27 : frame_byte = 8'hAB;
                7'd28 : frame_byte = 8'hC0;
                7'd29 : frame_byte = 8'hA8;
                7'd30 : frame_byte = 8'h01;
                7'd31 : frame_byte = 8'hC8;
                7'd32 : frame_byte = 8'h00;
                7'd33 : frame_byte = 8'h00;
                7'd34 : frame_byte = 8'h00;
                7'd35 : frame_byte = 8'h00;
                7'd36 : frame_byte = 8'h00;
                7'd37 : frame_byte = 8'h00;
                7'd38 : frame_byte = 8'hC0;
                7'd39 : frame_byte = 8'hA8;
                7'd40 : frame_byte = 8'h01;
                7'd41 : frame_byte = 8'h64;
                7'd42 : frame_byte = 8'hA0;
                7'd43 : frame_byte = 8'hA1;
                7'd44 : frame_byte = 8'hA2;
                7'd45 : frame_byte = 8'hA3;
                7'd46 : frame_byte = 8'hA4;
                7'd47 : frame_byte = 8'hA5;
                7'd48 : frame_byte = 8'hA6;
                7'd49 : frame_byte = 8'hA7;
                7'd50 : frame_byte = 8'hA8;
                7'd51 : frame_byte = 8'hA9;
                7'd52 : frame_byte = 8'hAA;
                7'd53 : frame_byte = 8'hAB;
                7'd54 : frame_byte = 8'hAC;
                7'd55 : frame_byte = 8'hAD;
                7'd56 : frame_byte = 8'hAE;
                7'd57 : frame_byte = 8'hAF;
                7'd58 : frame_byte = 8'hB0;
                7'd59 : frame_byte = 8'hB1;
                7'd60 : frame_byte = 8'hB2;
                7'd61 : frame_byte = 8'hB3;
                7'd62 : frame_byte = 8'hB4;
                7'd63 : frame_byte = 8'hB5;
                7'd64 : frame_byte = 8'hB6;
                7'd65 : frame_byte = 8'hB7;
                7'd66 : frame_byte = 8'hB8;
                7'd67 : frame_byte = 8'hB9;
                7'd68 : frame_byte = 8'hBA;
                7'd69 : frame_byte = 8'hBB;
                7'd70 : frame_byte = 8'hBC;
                7'd71 : frame_byte = 8'hBD;
                7'd72 : frame_byte = 8'hBE;
                7'd73 : frame_byte = 8'hBF;
                7'd74 : frame_byte = 8'hC0;
                7'd75 : frame_byte = 8'hC1;
                7'd76 : frame_byte = 8'hC2;
                7'd77 : frame_byte = 8'hC3;
                7'd78 : frame_byte = 8'hC4;
                7'd79 : frame_byte = 8'hC5;
                7'd80 : frame_byte = 8'hC6;
                7'd81 : frame_byte = 8'hC7;
                7'd82 : frame_byte = 8'hC8;
                7'd83 : frame_byte = 8'hC9;
                7'd84 : frame_byte = 8'hCA;
                7'd85 : frame_byte = 8'hCB;
                7'd86 : frame_byte = 8'hCC;
                7'd87 : frame_byte = 8'hCD;
                7'd88 : frame_byte = 8'hCE;
                7'd89 : frame_byte = 8'hCF;
                7'd90 : frame_byte = 8'hD0;
                7'd91 : frame_byte = 8'hD1;
                7'd92 : frame_byte = 8'hD2;
                7'd93 : frame_byte = 8'hD3;
                7'd94 : frame_byte = 8'hD4;
                7'd95 : frame_byte = 8'hD5;
                7'd96 : frame_byte = 8'hD6;
                7'd97 : frame_byte = 8'hD7;
                7'd98 : frame_byte = 8'hD8;
                7'd99 : frame_byte = 8'hD9;
                7'd100: frame_byte = 8'hDA;
                7'd101: frame_byte = 8'hDB;
                7'd102: frame_byte = 8'hDC;
                7'd103: frame_byte = 8'hDD;
                7'd104: frame_byte = 8'hDE;
                7'd105: frame_byte = 8'hDF;
                7'd106: frame_byte = 8'hE0;
                7'd107: frame_byte = 8'hE1;
                7'd108: frame_byte = 8'hE2;
                7'd109: frame_byte = 8'hE3;
                7'd110: frame_byte = 8'hE4;
                7'd111: frame_byte = 8'hE5;
                7'd112: frame_byte = 8'hE6;
                7'd113: frame_byte = 8'hE7;
                7'd114: frame_byte = 8'hE8;
                7'd115: frame_byte = 8'hE9;
                7'd116: frame_byte = 8'hEA;
                7'd117: frame_byte = 8'hEB;
                7'd118: frame_byte = 8'hEC;
                7'd119: frame_byte = 8'hED;
                7'd120: frame_byte = 8'hEE;
                7'd121: frame_byte = 8'hEF;
                7'd122: frame_byte = 8'hF0;
                7'd123: frame_byte = 8'hF1;
                7'd124: frame_byte = 8'hF1;   // FCS
                7'd125: frame_byte = 8'hD4;
                7'd126: frame_byte = 8'h3F;
                7'd127: frame_byte = 8'h01;
                default: frame_byte = 8'h00;
            endcase
        end
    endfunction

    // ------------------------------------------------------------------
    // 状态机
    // ------------------------------------------------------------------
    localparam S_IDLE = 3'd0;
    localparam S_PRE  = 3'd1;   // 0x55 × 7
    localparam S_SFD  = 3'd2;   // 0xD5
    localparam S_DATA = 3'd3;   // 128 字节
    localparam S_IFG  = 3'd4;   // 12 拍帧间隔

    reg [2:0]  state;
    reg [6:0]  byte_cnt;
    reg [31:0] wait_cnt;

    assign gmii_tx_er = 1'b0;
    assign tx_active  = (state != S_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            byte_cnt   <= 7'd0;
            wait_cnt   <= 32'd0;
            gmii_txd   <= 8'h00;
            gmii_tx_en <= 1'b0;
            frame_sent <= 1'b0;
        end else begin
            case (state)

                S_IDLE: begin
                    gmii_tx_en <= 1'b0;
                    gmii_txd   <= 8'h00;
                    if (wait_cnt >= SEND_INTERVAL_CYCLES - 1) begin
                        wait_cnt <= 32'd0;
                        byte_cnt <= 7'd0;
                        state    <= S_PRE;
                    end else begin
                        wait_cnt <= wait_cnt + 1'b1;
                    end
                end

                // 输出寄存器有一拍延迟：本轮赋 0x55，下一拍才出现在 gmii_txd。
                // 数到 5 → 6 拍 0x55；S_SFD 那一拍再出第 7 个 0x55；
                // 进入 S_DATA 第 1 拍输出 0xD5。合计 7×0x55 + 0xD5。
                S_PRE: begin
                    gmii_tx_en <= 1'b1;
                    gmii_txd   <= 8'h55;
                    if (byte_cnt == 7'd5) begin
                        byte_cnt <= 7'd0;
                        state    <= S_SFD;
                    end else begin
                        byte_cnt <= byte_cnt + 1'b1;
                    end
                end

                S_SFD: begin
                    gmii_txd <= 8'hD5;
                    byte_cnt <= 7'd0;
                    state    <= S_DATA;
                end

                S_DATA: begin
                    gmii_txd <= frame_byte(byte_cnt);
                    if (byte_cnt == 7'd127) begin
                        byte_cnt <= 7'd0;
                        state    <= S_IFG;
                    end else begin
                        byte_cnt <= byte_cnt + 1'b1;
                    end
                end

                S_IFG: begin
                    gmii_tx_en <= 1'b0;
                    gmii_txd   <= 8'h00;
                    if (byte_cnt == 7'd11) begin
                        byte_cnt   <= 7'd0;
                        frame_sent <= 1'b1;
                        state      <= S_IDLE;
                    end else begin
                        byte_cnt <= byte_cnt + 1'b1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
