`timescale 1ns / 1ps
//=============================================================================
// raw10_unpack.v — RAW10 解包（自研，M3）
//
// 输入：csi2_pkt_rx 的 RAW10 负载流（跑在字节时钟域；每拍 2 字节，高字节先到）
// 输出：每 5 字节凑成 4 个 10bit 像素；攒满一组时 O_px_valid 拉高 1 拍，
//       O_px[39:0] = {P3,P2,P1,P0}（各 10bit）
//
// RAW10 打包（MIPI CSI-2 / V4L2 Y10P 规范）：
//   b0..b3 = P0..P3 的高 8 位；b4 = {P3[1:0], P2[1:0], P1[1:0], P0[1:0]}
//   故 P0 = {b0, b4[1:0]}，P1 = {b1, b4[3:2]}，P2 = {b2, b4[5:4]}，P3 = {b3, b4[7:6]}
//
// 每行 = 1 个长包 = 1600 字节 = 320 组 = 1280 像素；I_pay_start 时清零对齐。
// 拍入 2 字节/拍、每 5 字节出一组 ⇒ 每拍最多出 1 组（不会丢组）。
// O_pkt_grp 在 I_pay_done 那一拍上报"含末组"的组数（组数寄存器有 1 拍滞后）。
//=============================================================================
module raw10_unpack (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        I_pay_valid,   // 负载字节有效（每拍 2 字节）
    input  wire [15:0] I_pay_data,    // {先到字节, 后到字节}
    input  wire        I_pay_start,   // 本包负载首拍 → 清零对齐
    input  wire        I_pay_done,    // 本包负载末拍 → 上报本包组数

    output reg         O_px_valid,    // 一组 4 像素有效（1 拍）
    output reg  [39:0] O_px,          // {P3,P2,P1,P0}
    output reg         O_pkt_done,    // 本包末拍后 1 拍（组数已含末组）
    output reg  [10:0] O_pkt_grp      // 本包最终组数
);

    reg [31:0] pnd;     // 已收未成组的字节：第 k 字节在 pnd[8k+7:8k]（k=0..3）
    reg [2:0]  np;      // pnd 内字节数 0..4
    reg [10:0] grp;     // 本包已出组数

    // ---- 组合：一拍内串行处理两个字节 ----
    reg [31:0] q_pnd;
    reg [2:0]  q_np;
    reg [39:0] q_px;
    reg        q_pxv;
    reg [10:0] q_grp;

    always @(*) begin
        // 行首对齐必须发生在推字节"之前"：清零残留半组，再接收本行首拍的两字节
        if (I_pay_start) begin
            q_pnd = 32'd0;
            q_np  = 3'd0;
            q_grp = 11'd0;
        end else begin
            q_pnd = pnd;
            q_np  = np;
            q_grp = grp;
        end
        q_px  = 40'd0;
        q_pxv = 1'b0;
        if (I_pay_valid) begin
            push_byte(I_pay_data[15:8]);   // 先到字节
            push_byte(I_pay_data[7:0]);    // 后到字节
        end
    end

    task push_byte;
        input [7:0] d;
        begin
            if (q_np == 3'd4) begin        // 4 个待拼字节 + 本字节 = 一组
                q_px[9:0]   = {q_pnd[7:0],   d[1:0]};
                q_px[19:10] = {q_pnd[15:8],  d[3:2]};
                q_px[29:20] = {q_pnd[23:16], d[5:4]};
                q_px[39:30] = {q_pnd[31:24], d[7:6]};
                q_pxv = 1'b1;
                q_grp = q_grp + 11'd1;
                q_np  = 3'd0;
            end else begin
                q_pnd[8*q_np +: 8] = d;
                q_np = q_np + 3'd1;
            end
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pnd        <= 32'd0;
            np         <= 3'd0;
            grp        <= 11'd0;
            O_px       <= 40'd0;
            O_px_valid <= 1'b0;
            O_pkt_done <= 1'b0;
            O_pkt_grp  <= 11'd0;
        end else begin
            pnd        <= q_pnd;
            np         <= q_np;
            O_px       <= q_px;
            O_px_valid <= q_pxv;
            grp        <= q_grp;
            O_pkt_done <= 1'b0;

            // 本拍出的组已记在 q_grp 里；行首清零在组合块中完成
            if (I_pay_done) begin
                O_pkt_grp  <= q_grp;
                O_pkt_done <= 1'b1;
                grp        <= 11'd0;
            end
        end
    end

endmodule
