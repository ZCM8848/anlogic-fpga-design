`timescale 1ns / 1ps
//=============================================================================
// status_report.v — 状态串口上报（自研，M3；取代 M2 的 cam_report.v）
//
// 每 REPEAT_MS 连发两行（115200 8N1）：
//   CAM  ID=<pre4> ADR=<dev2> W=<cnt2> P=<post4> OK=<0/1> E=<code1>      （41 字符，与 M2 完全一致）
//   MIPI HS=<0/1> F=<6位> L=<4位> W=<5位> G=<4位> ER=<2位16进制>          （48 字符）
//     F  = 累计帧数（FS 计数，BCD 十进制）      L = 上一帧行数（应为 0720）
//     W  = 上一行像素数（应为 01280）           G = 上一行 RAW10 组数（应为 0320）
//     ER = 错误位图（见 mipi_stats.v 注释）     HS = 是否见过 HS 流量
//=============================================================================
module status_report #(
    parameter CLK_FREQ  = 100_000_000,
    parameter BAUD      = 115200,
    parameter REPEAT_MS = 500
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- M2：摄像头初始化结果 ----
    input  wire [15:0] D_id_pre,
    input  wire [15:0] D_id_post,
    input  wire [6:0]  D_dev,
    input  wire [8:0]  D_wr_cnt,
    input  wire [3:0]  D_err,

    // ---- M3：MIPI 接收统计（BCD）----
    input  wire [23:0] D_fs_bcd,
    input  wire [15:0] D_line_bcd,
    input  wire [19:0] D_wpx_bcd,
    input  wire [15:0] D_grp_bcd,
    input  wire [7:0]  D_merr,
    input  wire        D_hs_seen,

    output wire        O_uart_tx
);

    localparam [6:0]  LAST        = 7'd88;   // 0..40 = CAM 行；41..88 = MIPI 行
    localparam integer REPEAT_CYC = (CLK_FREQ / 1000) * REPEAT_MS;

    function [7:0] hx(input [3:0] v);
        hx = (v < 4'd10) ? (8'h30 + {4'b0, v}) : (8'h37 + {4'b0, v});
    endfunction

    function [7:0] dc(input [3:0] v);        // BCD 位 → ASCII
        dc = 8'h30 + {4'b0, v};
    endfunction

    // ---- MIPI 行字符表（48 字节，组合生成）----
    wire [7:0] ml [0:47];

    assign ml[0]  = "M";
    assign ml[1]  = "I";
    assign ml[2]  = "P";
    assign ml[3]  = "I";
    assign ml[4]  = " ";
    assign ml[5]  = "H";
    assign ml[6]  = "S";
    assign ml[7]  = "=";
    assign ml[8]  = D_hs_seen ? "1" : "0";
    assign ml[9]  = " ";
    assign ml[10] = "F";
    assign ml[11] = "=";
    assign ml[12] = dc(D_fs_bcd[23:20]);
    assign ml[13] = dc(D_fs_bcd[19:16]);
    assign ml[14] = dc(D_fs_bcd[15:12]);
    assign ml[15] = dc(D_fs_bcd[11:8]);
    assign ml[16] = dc(D_fs_bcd[7:4]);
    assign ml[17] = dc(D_fs_bcd[3:0]);
    assign ml[18] = " ";
    assign ml[19] = "L";
    assign ml[20] = "=";
    assign ml[21] = dc(D_line_bcd[15:12]);
    assign ml[22] = dc(D_line_bcd[11:8]);
    assign ml[23] = dc(D_line_bcd[7:4]);
    assign ml[24] = dc(D_line_bcd[3:0]);
    assign ml[25] = " ";
    assign ml[26] = "W";
    assign ml[27] = "=";
    assign ml[28] = dc(D_wpx_bcd[19:16]);
    assign ml[29] = dc(D_wpx_bcd[15:12]);
    assign ml[30] = dc(D_wpx_bcd[11:8]);
    assign ml[31] = dc(D_wpx_bcd[7:4]);
    assign ml[32] = dc(D_wpx_bcd[3:0]);
    assign ml[33] = " ";
    assign ml[34] = "G";
    assign ml[35] = "=";
    assign ml[36] = dc(D_grp_bcd[15:12]);
    assign ml[37] = dc(D_grp_bcd[11:8]);
    assign ml[38] = dc(D_grp_bcd[7:4]);
    assign ml[39] = dc(D_grp_bcd[3:0]);
    assign ml[40] = " ";
    assign ml[41] = "E";
    assign ml[42] = "R";
    assign ml[43] = "=";
    assign ml[44] = hx(D_merr[7:4]);
    assign ml[45] = hx(D_merr[3:0]);
    assign ml[46] = 8'h0D;
    assign ml[47] = 8'h0A;

    // ---- 字符发生器 ----
    reg [6:0]   pc;
    reg         sending;
    reg  [26:0] rt;
    reg  [7:0]  txt;
    wire        tx_ready;
    wire        U_tx_valid;

    always @(*) begin
        if (pc <= 7'd40) begin
            // ---------- CAM 行（与 M2 完全一致）----------
            case (pc)
                7'd0:  txt = "C";
                7'd1:  txt = "A";
                7'd2:  txt = "M";
                7'd3:  txt = " ";
                7'd4:  txt = "I";
                7'd5:  txt = "D";
                7'd6:  txt = "=";
                7'd7:  txt = hx(D_id_pre[15:12]);
                7'd8:  txt = hx(D_id_pre[11:8]);
                7'd9:  txt = hx(D_id_pre[7:4]);
                7'd10: txt = hx(D_id_pre[3:0]);
                7'd11: txt = " ";
                7'd12: txt = "A";
                7'd13: txt = "D";
                7'd14: txt = "R";
                7'd15: txt = "=";
                7'd16: txt = hx({1'b0, D_dev[6:4]});
                7'd17: txt = hx({1'b0, D_dev[3:0]});
                7'd18: txt = " ";
                7'd19: txt = "W";
                7'd20: txt = "=";
                7'd21: txt = hx(D_wr_cnt[7:4]);
                7'd22: txt = hx(D_wr_cnt[3:0]);
                7'd23: txt = " ";
                7'd24: txt = "P";
                7'd25: txt = "=";
                7'd26: txt = hx(D_id_post[15:12]);
                7'd27: txt = hx(D_id_post[11:8]);
                7'd28: txt = hx(D_id_post[7:4]);
                7'd29: txt = hx(D_id_post[3:0]);
                7'd30: txt = " ";
                7'd31: txt = "O";
                7'd32: txt = "K";
                7'd33: txt = "=";
                7'd34: txt = (D_err == 4'd0) ? "1" : "0";
                7'd35: txt = " ";
                7'd36: txt = "E";
                7'd37: txt = "=";
                7'd38: txt = hx(D_err);
                7'd39: txt = 8'h0D;
                7'd40: txt = 8'h0A;
                default: txt = 8'h20;
            endcase
        end else begin
            // ---------- MIPI 行 ----------
            txt = ml[pc - 7'd41];
        end
    end

    // ---- 发送节奏控制（每 REPEAT_MS 连发两行）----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc      <= 7'd0;
            sending <= 1'b0;
            rt      <= 27'd0;
        end else if (!sending) begin
            if (rt >= REPEAT_CYC - 1) begin
                rt      <= 27'd0;
                sending <= 1'b1;
                pc      <= 7'd0;
            end else begin
                rt <= rt + 27'd1;
            end
        end else begin
            if (tx_ready) begin
                if (pc == LAST) sending <= 1'b0;
                else            pc      <= pc + 7'd1;
            end
        end
    end

    assign U_tx_valid = sending & tx_ready;

    uart_tx #(
        .CLK_FREQ (CLK_FREQ),
        .BAUD     (BAUD)
    ) u_uart_tx (
        .clk      (clk),
        .rst_n    (rst_n),
        .I_valid  (U_tx_valid),
        .I_data   (txt),
        .O_tx     (O_uart_tx),
        .O_ready  (tx_ready)
    );

endmodule
