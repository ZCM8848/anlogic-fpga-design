//=============================================================================
// lane_deint.v — D-PHY 字节流「拍对」重排（M3 联调自研）
//
// 背景（2026-09-27 上板实测 + 原厂接口语义核对）：
//   PH1P MIPI D-PHY 硬核在 BYTE_NUM=1、2-lane 模式下，每个字节时钟同时给出
//   lane0 与 lane1 各 1 字节：I_hs_data[15:8] = 当拍 lane0 字节、[7:0] = lane1。
//   实测 RAW10 行包 WC 字段在原始流中位于「上一拍低字节 + 当拍高字节」，
//   与原厂 csi_unpacket_2lane 的读法 {I_hs_data[15:8], S_hs_data_1d[7:0]}
//   完全一致 —— 即原始流的字节配对是「每 2 字节一段、lane 轮转」。
//
//   真正的 CSI-2 字节顺序（下游按标准包头解析所需）：
//       拍对 (A,B)  →  A[15:8], B[15:8], A[7:0], B[7:0]
//   本模块把原始流还原成标准 CSI-2 字节流（仍是 2 字节/拍），
//   下游 csi2_pkt_rx / raw10_unpack 因此无需改动。
//
// 时序：输出比输入晚半个拍对（1~2 拍）；包首（valid 上升沿）重置配对相位；
//       包尾若为「欠配对」的孤拍（本工程 WC 为偶数，负载不会出现）直接丢弃，
//       即每包输出字节数可能比输入少 2（CRC 尾拍），不影响负载计数。
//=============================================================================
module lane_deint (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        I_hs_valid,   // 来自 D-PHY 硬核
    input  wire [15:0] I_hs_data,
    output reg         O_valid,      // 重排后的 CSI-2 字节流
    output reg  [15:0] O_data
);

    reg        v1d;
    reg        ph;          // 拍对内相位：0 = 下一个有效拍是第 1 拍
    reg [15:0] a_d;         // 拍对第 1 拍

    reg [15:0] q0, q1, q2, q3;   // 输出队列（最多同时 2 拍入队，1 拍出队）
    reg [2:0]  qn;

    wire       pop      = (qn != 3'd0);
    wire [2:0] d_shift  = pop ? (qn - 3'd1) : 3'd0;   // 本拍出队后的深度
    wire       pair_fire= I_hs_valid & v1d & (ph == 1'b1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v1d     <= 1'b0;
            ph      <= 1'b0;
            a_d     <= 16'd0;
            q0      <= 16'd0;
            q1      <= 16'd0;
            q2      <= 16'd0;
            q3      <= 16'd0;
            qn      <= 3'd0;
            O_valid <= 1'b0;
            O_data  <= 16'd0;
        end else begin
            v1d <= I_hs_valid;

            // ---- 发射：先消费队头 ----
            O_valid <= pop;
            O_data  <= q0;
            q0      <= q1;
            q1      <= q2;
            q2      <= q3;
            q3      <= 16'd0;
            qn      <= pop ? (qn - 3'd1) : 3'd0;

            // ---- 收集 ----
            if (I_hs_valid & ~v1d) begin            // 包首
                ph  <= 1'b1;
                a_d <= I_hs_data;
            end else if (I_hs_valid & (ph == 1'b0)) begin
                ph  <= 1'b1;
                a_d <= I_hs_data;
            end else if (pair_fire) begin           // 拍对收齐 → 入队 2 拍
                ph <= 1'b0;
                case (d_shift)
                    3'd0: begin
                        q0 <= {a_d[15:8], I_hs_data[15:8]};
                        q1 <= {a_d[7:0],  I_hs_data[7:0]};
                        qn <= 3'd2;
                    end
                    3'd1: begin
                        q1 <= {a_d[15:8], I_hs_data[15:8]};
                        q2 <= {a_d[7:0],  I_hs_data[7:0]};
                        qn <= 3'd3;
                    end
                    3'd2: begin
                        q2 <= {a_d[15:8], I_hs_data[15:8]};
                        q3 <= {a_d[7:0],  I_hs_data[7:0]};
                        qn <= 3'd4;
                    end
                    default: begin                  // 深度 3：只放高对（正常不出现）
                        q3 <= {a_d[15:8], I_hs_data[15:8]};
                        qn <= 3'd4;
                    end
                endcase
            end else if (~I_hs_valid & v1d) begin   // 包间：重置配对相位
                ph <= 1'b0;
            end
        end
    end

endmodule
