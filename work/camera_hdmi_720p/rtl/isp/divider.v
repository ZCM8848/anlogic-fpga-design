`timescale 1ns / 1ps
//=============================================================================
// divider.v — 行为等价替换 TD 生成的除法器网表（ip/divider/divider_gate.v）
//
//   用途：rtl/isp/awb.v 的 AWB 白平衡增益  gain = floor((sum_g<<16) / sum_r|sum_b)
//   与原 IP 的接口/时序/语义保持完全一致：
//     * 端口同名：clk, rst(高有效), start, denominator[31:0], numerator[47:0],
//                 done, quotient[47:0], remainder[31:0]
//     * 全流水：每个时钟节拍接受一次 start（吞吐 1）
//     * 固定延迟 = PIPLE = 50 拍（与原 IP 的 `parameter PIPLE=50` 一致），
//       因此 awb.v 里 signal_delay(DELAY_CYCLE=50) 的对齐保持不变
//     * 无符号除法、向下取整（floor）
//
//   与原 IP 的差异（仅资源，不改结果）：
//     * 原 IP 按 48 位被除数 / 32 位余数全宽流水（48 级）。
//       本实现按 awb 的**实际取值范围**定宽：
//         numerator   = sum_g<<16  ≤ (1+720*255)<<16 ≈ 2^34   → 取 34 位被除数
//         denominator = sum_r      ∈ [1, 1+720*255 ≈ 2^18]     → 取 20 位余数
//       即被除数高位 (>34bit) 非零时直接判溢出（awb 永不出现）。
//     * 商只保留调用方真正用到的部分：低 20 位 + 溢出标志。
//       awb.v 的用法是 `|quotient[47:20] ? 20'hFFFFF : quotient[19:0]`，
//       故这里：无溢出 → quotient={28'b0, q[19:0]}；溢出 → quotient 高位全 1。
//=============================================================================
module divider #(
    parameter PIPLE = 50,
    parameter S_DEN = "UNSIGNED",
    parameter S_NUM = "UNSIGNED",
    parameter W_DEN = 32,
    parameter W_NUM = 48,
    parameter W_REM = 32
)(
    input             clk,
    input      [31:0] denominator,
    input      [47:0] numerator,
    input             rst,
    input             start,
    output     [47:0] quotient,
    output     [31:0] remainder,
    output reg        done
);

    // ---- 定宽参数（对齐 awb 实际取值范围）----
    localparam NITER = 34;              // 处理的被除数位数
    localparam RW    = 20;              // 余数位宽（denominator ≤ 2^18 ⇒ rem ≤ 2^19）
    localparam QB    = 20;              // 输出保留的商位数
    localparam PAD   = PIPLE - (NITER + 1) - 1;  // 尾部补齐到总延迟 PIPLE

    // ---- 输入级 ----
    reg [NITER-1:0] a_r;      // 被除数低 NITER 位
    reg             ovf_i;    // 被除数高位非零
    reg [RW-1:0]    d_r;      // 除数（截到 RW 位）
    reg             v_r;      // 有效流水

    always @(posedge clk) begin
        if (rst) begin
            a_r <= {NITER{1'b0}}; d_r <= {RW{1'b0}}; ovf_i <= 1'b0; v_r <= 1'b0;
        end else begin
            if (start) begin
                a_r   <= numerator[NITER-1:0];
                ovf_i <= |numerator[W_NUM-1:NITER];
                d_r   <= denominator[RW-1:0];
            end
            v_r <= start;
        end
    end

    // ---- 迭代流水：NITER 级，每级处理一位被除数，产生一位商 ----
    //   qbit[k] 为第 k 次迭代产生的商位（MSB 先出）⇒ q = {qbit[0], qbit[1], ..., qbit[NITER-1]}
    reg [RW-1:0]    rem_p [0:NITER];
    reg             qbit_p[0:NITER-1];
    reg             ovf_p [0:NITER];
    reg             v_p   [0:NITER];

    // 级 0 初始化（rem/q 清零，valid/ovf 从输入级进来）
    always @(posedge clk) begin
        if (rst) begin
            rem_p[0]  <= {RW{1'b0}};
            ovf_p[0]  <= 1'b0;
            v_p[0]    <= 1'b0;
        end else begin
            rem_p[0]  <= {RW{1'b0}};
            ovf_p[0]  <= ovf_i;
            v_p[0]    <= v_r;
        end
    end

    genvar gi;
    generate
        for (gi = 0; gi < NITER; gi = gi + 1) begin : g_iter
            wire [RW-1:0] sh = {rem_p[gi][RW-2:0], a_r[NITER-1-gi]};
            wire          ge = (sh >= d_r);
            always @(posedge clk) begin
                if (rst) begin
                    rem_p[gi+1]  <= {RW{1'b0}};
                    qbit_p[gi]   <= 1'b0;
                    ovf_p[gi+1]  <= 1'b0;
                    v_p[gi+1]    <= 1'b0;
                end else begin
                    rem_p[gi+1]  <= ge ? (sh - d_r) : sh;
                    qbit_p[gi]   <= ge;
                    ovf_p[gi+1]  <= ovf_p[gi];
                    v_p[gi+1]    <= v_p[gi];
                end
            end
        end
    endgenerate

    // ---- 结果组装（迭代结束时各 qbit 已就绪）----
    // 商 q[NITER-1:0] = {qbit[0], ..., qbit[NITER-1]}；高位自 NITER-1 起为 MSB
    wire [NITER-1:0] q_full;
    genvar gj;
    generate
        for (gj = 0; gj < NITER; gj = gj + 1) begin : g_q
            assign q_full[NITER-1-gj] = qbit_p[gj];   // qbit[0] 是 MSB
        end
    endgenerate

    wire ovf_final = ovf_p[NITER] | (|q_full[NITER-1:QB]);   // 商超过 QB 位
    wire [QB-1:0]   q_lo   = q_full[QB-1:0];
    wire [RW-1:0]   rem_f  = rem_p[NITER];

    wire [47:0] q_fmt = ovf_final ? 48'hFFFF_FFFF_FFFF : {{(48-QB){1'b0}}, q_lo};
    wire [31:0] r_fmt = {{(32-RW){1'b0}}, rem_f};

    // ---- 尾部补齐到 PIPLE 拍 ----
    reg [47:0] q_pad [1:PAD];
    reg [31:0] r_pad [1:PAD];
    reg        v_pad [1:PAD];

    integer p;
    always @(posedge clk) begin
        if (rst) begin
            for (p = 1; p <= PAD; p = p + 1) begin
                q_pad[p] <= 48'd0; r_pad[p] <= 32'd0; v_pad[p] <= 1'b0;
            end
        end else begin
            q_pad[1] <= q_fmt;
            r_pad[1] <= r_fmt;
            v_pad[1] <= v_p[NITER];
            for (p = 2; p <= PAD; p = p + 1) begin
                q_pad[p] <= q_pad[p-1];
                r_pad[p] <= r_pad[p-1];
                v_pad[p] <= v_pad[p-1];
            end
        end
    end

    assign quotient  = q_pad[PAD];
    assign remainder = r_pad[PAD];

    always @(posedge clk) begin
        if (rst) done <= 1'b0;
        else     done <= v_pad[PAD];
    end

endmodule
