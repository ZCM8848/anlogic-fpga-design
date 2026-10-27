// async_fifo.v — 双时钟 FIFO（gray 指针），带读域可用字数
//
// 为什么需要它：摄像头 MIPI 2lane×828Mbps = 207 MB/s 突发（每行 7.7µs），
// 而 FIFO 写时钟 ~103.5MHz，8bit 只有 103MB/s。所以宽度必须 ≥40bit
// （40bit×41.5M/s = 207MB/s）。读侧再展开成 1 字节/周期。
//
// 注意：full 标志必须**寄存器化**（Cummings 标准写法）。若用
//   wfull = (wgray_nx == ...)，会形成 wfull→do_wr→wbin_nx→wgray_nx→wfull
// 的组合环，TD 综合会报 SYN-5033 / SYN-8613。
//
`timescale 1ns/1ps

module async_fifo #(
    parameter integer DW = 41,
    parameter integer AW = 9             // 深度 = 2^AW 字
)(
    // 写侧
    input  wire          wclk,
    input  wire          wrst_n,
    input  wire          winc,
    input  wire [DW-1:0] wdata,
    output wire          wfull,
    // 读侧
    input  wire          rclk,
    input  wire          rrst_n,
    input  wire          rinc,
    output wire [DW-1:0] rdata,
    output wire          rempty,
    // 读域看到的已用字数（同步有 2 拍延迟，偏小 → 保守安全）
    output wire [AW:0]   rused
);

    reg [DW-1:0] mem [0:(1<<AW)-1];

    reg [AW:0] wbin, wgray;
    reg [AW:0] rbin, rgray;
    reg        wfull_r;

    // 指针跨时钟（先声明，后面 always 块要用）
    reg [AW:0] wgray_s1, wgray_s2;
    reg [AW:0] rgray_s1, rgray_s2;

    wire        do_wr = winc & ~wfull_r;
    wire        do_rd = rinc & ~rempty;

    wire [AW:0] wbin_nx  = wbin + {{AW{1'b0}}, do_wr};
    wire [AW:0] wgray_nx = (wbin_nx >> 1) ^ wbin_nx;
    wire [AW:0] rbin_nx  = rbin + {{AW{1'b0}}, do_rd};
    wire [AW:0] rgray_nx = (rbin_nx >> 1) ^ rbin_nx;

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            wbin    <= {(AW+1){1'b0}};
            wgray   <= {(AW+1){1'b0}};
            wfull_r <= 1'b0;
        end else begin
            wbin    <= wbin_nx;
            wgray   <= wgray_nx;
            wfull_r <= (wgray_nx == {~rgray_s2[AW:AW-1], rgray_s2[AW-2:0]});
        end
    end

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            rbin  <= {(AW+1){1'b0}};
            rgray <= {(AW+1){1'b0}};
        end else begin
            rbin  <= rbin_nx;
            rgray <= rgray_nx;
        end
    end

    always @(posedge wclk) begin
        if (do_wr) mem[wbin[AW-1:0]] <= wdata;
    end

    assign rdata = mem[rbin[AW-1:0]];

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            wgray_s1 <= {(AW+1){1'b0}};
            wgray_s2 <= {(AW+1){1'b0}};
        end else begin
            wgray_s1 <= wgray;
            wgray_s2 <= wgray_s1;
        end
    end

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            rgray_s1 <= {(AW+1){1'b0}};
            rgray_s2 <= {(AW+1){1'b0}};
        end else begin
            rgray_s1 <= rgray;
            rgray_s2 <= rgray_s1;
        end
    end

    assign rempty = (rgray == wgray_s2);
    assign wfull  = wfull_r;

    function [AW:0] gray2bin(input [AW:0] g);
        integer i;
        begin
            gray2bin[AW] = g[AW];
            for (i = AW-1; i >= 0; i = i - 1)
                gray2bin[i] = gray2bin[i+1] ^ g[i];
        end
    endfunction

    assign rused = gray2bin(wgray_s2) - rbin;

endmodule
