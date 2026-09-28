/*******************************************************************************
 * camera_hdmi_720p — DDR 帧缓存读引擎 / 显示侧（自研，M5-②）
 *
 * 分工：
 *   用户域（S_ddr_clk）：向 ddr_arb 发读请求，把一行 80 个字（128bit）取回写进
 *       显示行缓冲（双 bank，按行号奇偶分 bank）。预取策略：显示第 y 行时预取
 *       第 y+1 行；vsync 时预取第 0 行（消隐期充足）。
 *   像素域（HDMI 75MHz）：按 x 读行缓冲（bank = 当前显示行 y[0]），
 *       x[10:4] 选字、x[3:0] 选字节（打包时已保证 byte n = 该 16 像素组第 n 个
 *       像素的灰度），输出 {g,g,g}；无可用帧时输出黑。
 *
 * 跨域事件（像素域 → 用户域）：vs_tgl / line_tgl 翻转脉冲经 2 级同步 + 边沿检测；
 *   仅单位信号，事件间隔 ≥22us，无线序问题。「有帧」标志反向 2 级同步到像素域。
 *
 * 读吞吐：允许最多 16 个读命令在途（S_issue 条件），逐行 80 字，
 *   预计 <8us << 行周期 22.4us；行 0 在 vsync 后 ~0.5ms 消隐期内完成。
 *
 * 欠载/冲刷（诊断）：某行显示开始时若其预取尚未完成 → O_line_underflow 脉冲
 *   （fb_ctrl 计 UN；画面表现为该行重复上一帧内容，无撕裂）。仲裁器读超时
 *   冲刷期间冻结本引擎、丢弃响应，冲刷结束从本行第 0 字重取（幂等）。
 *
 * 地址（2 字节单位）：行 y 基址 = I_rd_base + y*640；字 k 地址 = 行基址 + k*8。
 *   行基址在预取启动时锁存（换帧发生在 vsync，在途预取保持旧基址，语义一致）。
 ******************************************************************************/
`timescale 1ns / 1ps

module fb_rd #(
    parameter DW = 128
) (
    // ---------------- 用户域（S_ddr_clk）----------------
    input  wire         clk_d,
    input  wire         rst_n_d,
    input  wire [24:0]  I_rd_base,     // 当前显示帧基址（fb_ctrl）
    input  wire         I_rd_valid_f,  // 有可显示帧（fb_ctrl O_rd_valid）

    output reg          O_vsync_pulse, // 换帧点（用户域 1 拍 → fb_ctrl）
    output reg          O_line_underflow,

    output wire         O_rd_req,      // 读请求（→ ddr_arb）
    output wire [24:0]  O_rd_addr,
    input  wire         I_rd_gnt,
    input  wire [127:0] I_rd_data,
    input  wire         I_rd_dvalid,
    input  wire         I_rd_flush,    // 仲裁器读超时冲刷中

    // ---------------- 像素域（HDMI 75MHz）----------------
    input  wire         clk_p,
    input  wire         rst_n_p,
    input  wire         I_vs,          // hdmi_timing（有效高）
    input  wire         I_de,
    input  wire [11:0]  I_x,
    input  wire [11:0]  I_y,

    output reg  [23:0]  O_data,        // 灰度 {g,g,g}，与 O_de/O_vs 同拍
    output reg          O_de,
    output reg          O_vs
);

    localparam NONE = 10'h3FF;         // 「无已完成行」标记

    // ================================================== 显示行缓冲（写=用户域，读=像素域）
    reg  [DW-1:0]  S_rb0 [0:127];
    reg  [DW-1:0]  S_rb1 [0:127];

    // ================================================== 用户域：预取引擎
    reg  [2:0]     S_vs_tg_s, S_ln_tg_s;   // 像素域事件翻转同步链
    reg  [9:0]     S_evt_cnt;              // 本帧已到达的行事件数（= 即将显示的行号）
    reg  [9:0]     S_done_line;            // 最近完成预取的行号
    reg  [9:0]     S_want_line;            // 待预取行
    reg            S_want_v;
    reg            S_fill_act;
    reg            S_fill_slot;
    reg  [9:0]     S_fill_line;
    reg  [24:0]    S_fill_la;              // 本行基址（启动时锁存）
    reg  [7:0]     S_fill_cnt;             // 已发出的读命令数（0..80）
    reg  [7:0]     S_fill_got;             // 已回收的响应数（0..80）

    // 像素域事件翻转寄存器（先声明：下面的用户域 always 要同步它们）
    reg            S_pixel_vs_tgl, S_pixel_ln_tgl;

    wire           S_vs_p = (S_vs_tg_s[2] ^ S_vs_tg_s[1]);
    wire           S_ln_p = (S_ln_tg_s[2] ^ S_ln_tg_s[1]);

    // 行基址偏移：line*640 = line*512 + line*128
    wire [24:0]    S_want_la = I_rd_base + ({6'b0, S_want_line, 9'b0} +
                                            {8'b0, S_want_line, 7'b0});

    // 发出条件：行未取满、在途 < 16、未在冲刷
    wire           S_issue = S_fill_act && !I_rd_flush && (S_fill_cnt < 8'd80) &&
                             ((S_fill_cnt - S_fill_got) < 8'd16);

    assign O_rd_req  = S_issue;
    assign O_rd_addr = S_fill_la + {15'b0, S_fill_cnt[6:0], 3'b0};

    // 【M5-② 诊断 v2】W3 回填侧标记：偶数行（fill_line[0]==0）的 got==0 数据替换为 0x88 灰条
    //   用途：若 W3 灰条出现在屏幕最左（x=0..16）⇒ 回填写入的「字 0」一路诚实到屏幕；
    //   若出现在 ≈208px ⇒ 偏移在回填写入或其下游。与 W1 白框、W4（排空侧 0x55，奇数行）配合二分。
    wire           S_fill_w3 = (!S_fill_line[0]) && (S_fill_got == 8'd0);

    always @(posedge clk_d) begin
        if (!rst_n_d) begin
            S_vs_tg_s    <= 3'd0;
            S_ln_tg_s    <= 3'd0;
            S_evt_cnt    <= 10'd0;
            S_done_line  <= NONE;
            S_want_line  <= 10'd0;
            S_want_v     <= 1'b0;
            S_fill_act   <= 1'b0;
            S_fill_slot  <= 1'b0;
            S_fill_line  <= 10'd0;
            S_fill_la    <= 25'd0;
            S_fill_cnt   <= 8'd0;
            S_fill_got   <= 8'd0;
            O_vsync_pulse<= 1'b0;
            O_line_underflow <= 1'b0;
        end else begin
            S_vs_tg_s <= {S_vs_tg_s[1:0], S_pixel_vs_tgl};
            S_ln_tg_s <= {S_ln_tg_s[1:0], S_pixel_ln_tgl};
            O_vsync_pulse    <= 1'b0;
            O_line_underflow <= 1'b0;

            // 事件 1：vsync（新一帧显示起点）→ 预取第 0 行
            if (S_vs_p) begin
                S_evt_cnt    <= 10'd0;
                S_done_line  <= NONE;
                S_want_line  <= 10'd0;
                S_want_v     <= 1'b1;
                O_vsync_pulse<= 1'b1;
            end
            // 事件 2：行事件（开始显示第 evt_cnt 行）→ 核对 + 预取下一行
            if (S_ln_p) begin
                if (S_done_line != S_evt_cnt) O_line_underflow <= 1'b1;
                if (S_evt_cnt < 10'd719) begin
                    S_want_line <= S_evt_cnt + 10'd1;
                    S_want_v    <= 1'b1;
                end else begin
                    S_want_v    <= 1'b0;
                end
                S_evt_cnt <= S_evt_cnt + 10'd1;
            end

            // 预取启动（want 消费；同拍新事件不丢）
            if (!S_fill_act && S_want_v && !I_rd_flush) begin
                S_fill_act  <= 1'b1;
                S_fill_slot <= S_want_line[0];
                S_fill_line <= S_want_line;
                S_fill_la   <= S_want_la;
                S_fill_cnt  <= 8'd0;
                S_fill_got  <= 8'd0;
                S_want_v    <= S_vs_p | S_ln_p;
            end

            // 读命令发出
            if (S_issue && I_rd_gnt) S_fill_cnt <= S_fill_cnt + 8'd1;

            // 响应回收 → 写显示行缓冲
            if (I_rd_dvalid && S_fill_act && !I_rd_flush) begin
                if (S_fill_slot) S_rb1[S_fill_got[6:0]] <= S_fill_w3 ? 128'h8888_8888_8888_8888_8888_8888_8888_8888 : I_rd_data;
                else             S_rb0[S_fill_got[6:0]] <= S_fill_w3 ? 128'h8888_8888_8888_8888_8888_8888_8888_8888 : I_rd_data;
                if (S_fill_got == 8'd79) begin
                    S_fill_act  <= 1'b0;
                    S_done_line <= S_fill_line;
                end
                S_fill_got <= S_fill_got + 8'd1;
            end

            // 冲刷：冻结并复位计数（冲刷结束从本行第 0 字重取）
            if (I_rd_flush) begin
                S_fill_cnt <= 8'd0;
                S_fill_got <= 8'd0;
            end
        end
    end

    // ================================================== 像素域：事件 + 读 + 输出
    reg            S_vs_prev, S_de_prev;
    reg  [DW-1:0]  S_rd_q;
    reg  [11:0]    S_x_d1;
    reg            S_de_d1, S_vs_d1;
    reg  [1:0]     S_vd_s;                 // 「有帧」标志同步链
    reg            S_mk1;                  // 【M5-② 诊断 v2】W2 显示读出侧标记（比输出早 1 拍，与 O_data 同拍对齐）

    reg  [7:0]     S_byte;
    integer        i;

    always @* begin
        S_byte = 8'd0;
        for (i = 0; i < 16; i = i + 1)
            if (S_x_d1[3:0] == i[3:0])
                S_byte = S_rd_q[i*8 +: 8];      // byte n = 第 n 个像素的灰度
    end

    always @(posedge clk_p) begin
        if (!rst_n_p) begin
            S_pixel_vs_tgl <= 1'b0;
            S_pixel_ln_tgl <= 1'b0;
            S_vs_prev      <= 1'b0;
            S_de_prev      <= 1'b0;
            S_rd_q         <= {DW{1'b0}};
            S_x_d1         <= 12'd0;
            S_de_d1        <= 1'b0;
            S_vs_d1        <= 1'b0;
            S_vd_s         <= 2'b00;
            S_mk1          <= 1'b0;
            O_data         <= 24'd0;
            O_de           <= 1'b0;
            O_vs           <= 1'b0;
        end else begin
            // 事件翻转（用户域 2 级同步去抖）
            if (I_vs && !S_vs_prev) S_pixel_vs_tgl <= ~S_pixel_vs_tgl;
            if (I_de && !S_de_prev) S_pixel_ln_tgl <= ~S_pixel_ln_tgl;
            S_vs_prev <= I_vs;
            S_de_prev <= I_de;

            // 「有帧」标志（用户域 → 像素域，2 级同步）
            S_vd_s <= {S_vd_s[0], I_rd_valid_f};

            // 行缓冲读（bank = 当前显示行奇偶；x[10:4] 选字）
            S_rd_q <= I_y[0] ? S_rb1[I_x[10:4]] : S_rb0[I_x[10:4]];
            S_x_d1 <= I_x;
            S_de_d1 <= I_de;
            S_vs_d1 <= I_vs;

            // 【M5-② 诊断 v2】W2 显示读出侧标记：用显示侧自己的 (I_x,I_y) 在 (x<64, 200<=y<208)
            //   画 64x8 白条。出现在屏幕最左 ⇒ 显示读出坐标诚实；出现在 ≈208px ⇒ I_x 本身错位。
            S_mk1 <= I_de && (I_x < 12'd64) && (I_y >= 10'd200) && (I_y < 10'd208);

            // 输出（2 拍流水与 de/vs 对齐；无帧时输出黑）
            O_data <= S_mk1 ? 24'hFFFFFF : (S_vd_s[1] ? {S_byte, S_byte, S_byte} : 24'd0);
            O_de   <= S_de_d1;
            O_vs   <= S_vs_d1;
        end
    end

endmodule
