`timescale 1ns / 1ps
//=============================================================================
// status_report.v — 状态串口上报（自研，M3；取代 M2 的 cam_report.v）
//
// 每 REPEAT_MS 连发三行（115200 8N1）：
//   CAM  ID=<pre4> ADR=<dev2> W=<cnt2> P=<post4> OK=<0/1> E=<code1>      （41 字符，与 M2 完全一致）
//   MIPI HS=<0/1> F=<6位> L=<4位> W=<5位> G=<4位> ER=<2位16进制>
//        HW=<8位16进制> PW=<4位16进制> PL=<4位16进制> HC=<1位16进制>   （81 字符）
//     F  = 累计帧数（FS 计数，BCD 十进制）      L = 上一帧行数（应为 0720）
//     W  = 上一行像素数（应为 01280）           G = 上一行 RAW10 组数（应为 0320）
//     ER = 错误位图（见 mipi_stats.v 注释）     HS = 是否见过 HS 流量
//     HW = 最近一个 RAW10 包收到的 4 个包头字节（应为 2B 06 40 xx）
//     PW = 该包负载首拍的 2 字节（RAW10 头 4 像素的高 8 位）
//     PL = 包体提前结束那一拍还剩多少拍（0 表示未发生）  HC = err_hdr 成因位图
//   DDR  RDY=<0/1> ARDY=<0/1> WRDY=<0/1>                                （26 字符，M5 起）
//     RDY  = DDR 校准完成（ddrphy_rdy）    ARDY = 应用口就绪（O_mc_app_rdy）
//     WRDY = 写数据口就绪（O_mc_app_wdf_rdy）；
//     M5-① 空载校准版仅报这三个状态；② 接上读写引擎后本行扩为帧计数/溢出计数。
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

    // ---- M3 诊断（仅联调用）----
    input  wire [31:0] D_dbg_hdr,      // 最近 RAW10 包头 4 字节
    input  wire [15:0] D_dbg_pw,       // 负载首拍 2 字节
    input  wire [14:0] D_dbg_pleft,    // 包体中断时剩余拍数
    input  wire [3:0]  D_dbg_hcause,   // err_hdr 成因位

    input  wire        D_sw4,          // M4：SW4 状态（100MHz 域同步后）
    input  wire        D_lp0_p,        // M4 诊断：D-PHY LP 状态（lane0 p）
    input  wire        D_lp0_n,
    input  wire        D_lp_act,       // 曾出现过非 LP-11（传感器在驱动）
    input  wire        D_rx_alive,     // 字节域复位已释放（恢复时钟跑过）

    // ---- M5：DDR2 状态（100MHz 域同步后）----
    input  wire        D_ddr_rdy,      // ddrphy_rdy：校准完成
    input  wire        D_ddr_ardy,     // O_mc_app_rdy：应用口就绪
    input  wire        D_ddr_wrdy,     // O_mc_app_wdf_rdy：写数据口就绪

    output wire        O_uart_tx
);

    localparam [7:0]  LAST        = 8'd169;  // 0..40 = CAM；41..144 = MIPI；145..169 = DDR（必须 ≥8 位，7 位会溢出）
    localparam integer REPEAT_CYC = (CLK_FREQ / 1000) * REPEAT_MS;

    function [7:0] hx(input [3:0] v);
        hx = (v < 4'd10) ? (8'h30 + {4'b0, v}) : (8'h37 + {4'b0, v});
    endfunction

    function [7:0] dc(input [3:0] v);        // BCD 位 → ASCII
        dc = 8'h30 + {4'b0, v};
    endfunction

    // ---- MIPI 行字符表（81 字节，组合生成）----
    wire [7:0] ml [0:103];

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
    assign ml[46] = " ";
    assign ml[47] = "H";
    assign ml[48] = "W";
    assign ml[49] = "=";
    assign ml[50] = hx(D_dbg_hdr[31:28]);
    assign ml[51] = hx(D_dbg_hdr[27:24]);
    assign ml[52] = hx(D_dbg_hdr[23:20]);
    assign ml[53] = hx(D_dbg_hdr[19:16]);
    assign ml[54] = hx(D_dbg_hdr[15:12]);
    assign ml[55] = hx(D_dbg_hdr[11:8]);
    assign ml[56] = hx(D_dbg_hdr[7:4]);
    assign ml[57] = hx(D_dbg_hdr[3:0]);
    assign ml[58] = " ";
    assign ml[59] = "P";
    assign ml[60] = "W";
    assign ml[61] = "=";
    assign ml[62] = hx(D_dbg_pw[15:12]);
    assign ml[63] = hx(D_dbg_pw[11:8]);
    assign ml[64] = hx(D_dbg_pw[7:4]);
    assign ml[65] = hx(D_dbg_pw[3:0]);
    assign ml[66] = " ";
    assign ml[67] = "P";
    assign ml[68] = "L";
    assign ml[69] = "=";
    assign ml[70] = hx(D_dbg_pleft[14:12]);
    assign ml[71] = hx(D_dbg_pleft[11:8]);
    assign ml[72] = hx(D_dbg_pleft[7:4]);
    assign ml[73] = hx(D_dbg_pleft[3:0]);
    assign ml[74] = " ";
    assign ml[75] = "H";
    assign ml[76] = "C";
    assign ml[77] = "=";
    assign ml[78] = hx(D_dbg_hcause);
    assign ml[79] = " ";
    assign ml[80] = "S";
    assign ml[81] = "W";
    assign ml[82] = "4";
    assign ml[83] = "=";
    assign ml[84] = D_sw4 ? "1" : "0";     // 画面切换开关状态（1=摄像头画面）
    assign ml[85] = " ";
    assign ml[86] = "L";
    assign ml[87] = "P";
    assign ml[88] = "=";
    assign ml[89] = D_lp0_p   ? "1" : "0";  // D-PHY LP 接收状态（lane0）
    assign ml[90] = D_lp0_n   ? "1" : "0";
    assign ml[91] = " ";
    assign ml[92] = "L";
    assign ml[93] = "P";
    assign ml[94] = "A";
    assign ml[95] = "=";
    assign ml[96] = D_lp_act  ? "1" : "0";  // 曾出现过非 LP-11 → 传感器在驱动总线
    assign ml[97] = " ";
    assign ml[98] = "R";
    assign ml[99] = "X";
    assign ml[100] = "=";
    assign ml[101] = D_rx_alive ? "1" : "0"; // 字节域复位已释放 → 恢复时钟跑过
    assign ml[102] = 8'h0D;
    assign ml[103] = 8'h0A;

    // ---- M5：DDR 行字符表（25 字节：23 字符 + CRLF）----
    wire [7:0] dl [0:24];

    assign dl[0]  = "D";
    assign dl[1]  = "D";
    assign dl[2]  = "R";
    assign dl[3]  = " ";
    assign dl[4]  = "R";
    assign dl[5]  = "D";
    assign dl[6]  = "Y";
    assign dl[7]  = "=";
    assign dl[8]  = D_ddr_rdy  ? "1" : "0";
    assign dl[9]  = " ";
    assign dl[10] = "A";
    assign dl[11] = "R";
    assign dl[12] = "D";
    assign dl[13] = "Y";
    assign dl[14] = "=";
    assign dl[15] = D_ddr_ardy ? "1" : "0";
    assign dl[16] = " ";
    assign dl[17] = "W";
    assign dl[18] = "R";
    assign dl[19] = "D";
    assign dl[20] = "Y";
    assign dl[21] = "=";
    assign dl[22] = D_ddr_wrdy ? "1" : "0";
    assign dl[23] = 8'h0D;
    assign dl[24] = 8'h0A;

    // ---- 字符发生器 ----
    reg [7:0]   pc;
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
        end else if (pc <= 7'd144) begin
            // ---------- MIPI 行 ----------
            txt = ml[pc - 7'd41];
        end else begin
            // ---------- DDR 行（M5）----------
            txt = dl[pc - 7'd145];
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
