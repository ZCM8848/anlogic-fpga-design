// crc32_eth.v — 以太网 FCS（帧校验序列）CRC-32 计算器
//
// 标准：IEEE 802.3 CRC-32
//   多项式：0x04C11DB7（反射后 0xEDB88320）
//   初值：0xFFFFFFFF
//   输入字节按位反射
//   输出按位反射，再异或 0xFFFFFFFF
//   即：在线数据流逐字节更新；FCS 在帧尾追加 4 字节（小端序）
//
// 用法：
//   - 初始 crc=32'hFFFFFFFF
//   - 每个数据字节（data_valid 高）按节拍 sop/eop 调用更新
//   - 帧结束后取反（XOR 0xFFFFFFFF）即为 FCS（小端序附加到帧尾）
//
// 实现：byte-wide 查表（256 项 32 位表，FPGA 综合 BRAM 或分布式 RAM）
//
`timescale 1ns/1ps

module crc32_eth (
    input  wire        clk,           // 同步时钟
    input  wire        rst_n,
    input  wire        init,          // 1 拍脉冲：把 crc 复位为 0xFFFFFFFF
    input  wire        data_valid,    // 1 = 本拍数据有效，参与计算
    input  wire [7:0]  data,          // 数据字节
    output reg  [31:0] crc            // 当前 CRC 值（已在线更新；帧尾取反即 FCS）
);
    // 反射输入字节：bit0↔bit7, bit1↔bit6, ...
    function [7:0] reverse_byte(input [7:0] b);
        integer i;
        begin
            reverse_byte = 0;
            for (i = 0; i < 8; i = i + 1)
                reverse_byte[i] = b[7 - i];
        end
    endfunction

    // 反射 32 位输出
    function [31:0] reverse_32(input [31:0] x);
        integer i;
        begin
            reverse_32 = 0;
            for (i = 0; i < 32; i = i + 1)
                reverse_32[i] = x[31 - i];
        end
    endfunction

    // CRC-32 反射算法（poly 0xEDB88320）逐字节更新
    //   next_crc = (crc >> 8) ^ table[(crc ^ byte) & 8'hFF]
    //   table[i] = standard CRC32 lookup entry for byte i
    wire [7:0] db = reverse_byte(data);
    wire [7:0] idx = crc[7:0] ^ db;

    // 查找表（256 项，多项式 0xEDB88320）
    reg [31:0] lut [0:255];
    integer ii;
    initial begin
        for (ii = 0; ii < 256; ii = ii + 1) begin
            // 计算 lut[ii]
            reg [31:0] c;
            integer j;
            c = 32'h00000000;
            c[7:0] = ii[7:0];
            for (j = 0; j < 8; j = j + 1) begin
                if (c[0])
                    c = (c >> 1) ^ 32'hEDB88320;
                else
                    c = c >> 1;
            end
            lut[ii] = c;
        end
    end

    // 流水化更新（1 拍延迟）
    reg [31:0] crc_next;
    always @(*) begin
        crc_next = (crc >> 8) ^ lut[idx];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            crc <= 32'hFFFFFFFF;
        else if (init)
            crc <= 32'hFFFFFFFF;
        else if (data_valid)
            crc <= crc_next;
    end
endmodule
