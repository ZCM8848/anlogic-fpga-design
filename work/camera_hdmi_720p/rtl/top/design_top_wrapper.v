/*******************************************************************************
 * camera_hdmi_720p — 板级顶层（自研）
 *
 * M1 功能：50MHz → PLL(复用 IP) → HDMI 测试图案 → HDMI 1.4b TX(复用 IP) → 显示器
 *          （摄像头链路 M2/M3 起在本文件中接入）
 *
 * 时钟（ip/pll/PLL.v，厂商验证配置）：
 *   C0 = 100.000MHz   系统逻辑（M2 起使用）
 *   C1 = 23.809524MHz 摄像头 XCLK（M2 起使用）
 *   C4 = 75.000MHz    HDMI 像素时钟
 *   C5 = 375.000MHz   HDMI 串行时钟
 *
 * 复位：PLL lock → reset_ctrl 同步复位，各域独立释放。
 ******************************************************************************/
`timescale 1ns / 1ps

module design_top_wrapper (
    input  wire       I_sys_clk,     // C4：板载 50MHz 有源晶振
    output wire       O_tmds_ch0_p,  // G16
    output wire       O_tmds_ch1_p,  // F17
    output wire       O_tmds_ch2_p,  // H14
    output wire       O_tmds_clk_p,  // C17
    output wire [3:0] O_led          // D10/E10/C6/D6（LED1..LED4，高电平点亮）
);

    // ---------------------------------------------------------------- 时钟
    wire S_clk_100m;     // 系统逻辑时钟（M2 起使用）
    wire S_clk_cam;      // 摄像头 XCLK（M2 起使用）
    wire S_pixel_clk;    // HDMI 像素时钟 75MHz
    wire S_serial_clk;   // HDMI 串行时钟 375MHz
    wire S_pll_lock;

    PLL u_pll (
        .refclk   ( I_sys_clk    ),
        .reset    ( 1'b0         ),   // 上电复位由芯片内建处理；参考设计此处接外部复位，本设计不使用
        .clk0_out ( S_clk_100m   ),
        .clk1_out ( S_clk_cam    ),
        .clk4_out ( S_pixel_clk  ),
        .clk5_out ( S_serial_clk ),
        .lock     ( S_pll_lock   )
    );

    // ---------------------------------------------------------------- 复位
    wire S_rst_n_100m;
    wire S_rst_n_pix;

    reset_ctrl u_rst_100m (.clk(S_clk_100m),  .pll_lock(S_pll_lock), .rst_n(S_rst_n_100m));
    reset_ctrl u_rst_pix  (.clk(S_pixel_clk), .pll_lock(S_pll_lock), .rst_n(S_rst_n_pix));

    // ------------------------------------------------- 视频时序与测试图案
    wire        S_vs, S_hs, S_de;
    wire [11:0] S_x, S_y;

    hdmi_timing #(
        .H_ACTIVE     ( 1280 ),
        .H_TOTAL      ( 1650 ),
        .H_SYNC_START ( 1390 ),
        .H_SYNC_END   ( 1430 ),
        .V_ACTIVE     ( 720  ),
        .V_TOTAL      ( 750  ),
        .V_SYNC_START ( 725  ),
        .V_SYNC_END   ( 730  )
    ) u_timing (
        .clk   ( S_pixel_clk ),
        .rst_n ( S_rst_n_pix ),
        .vs    ( S_vs        ),
        .hs    ( S_hs        ),
        .de    ( S_de        ),
        .x     ( S_x         ),
        .y     ( S_y         )
    );

    wire [23:0] S_pat_data;
    wire        S_pat_de, S_pat_vs;

    test_pattern u_pattern (
        .clk   ( S_pixel_clk ),
        .rst_n ( S_rst_n_pix ),
        .vs    ( S_vs        ),
        .de    ( S_de        ),
        .x     ( S_x         ),
        .y     ( S_y         ),
        .data  ( S_pat_data  ),
        .de_o  ( S_pat_de    ),
        .vs_o  ( S_pat_vs    )
    );

    // --------------------------------------------- HDMI 1.4b 发送（复用 IP）
    // 复位说明：HDMI IP 的复位直接用 PLL lock（异步），与厂商参考设计一致。
    // 原因：IP 内部既有像素域又有 375MHz 串行域寄存器，若用某一域的同步复位驱动，
    // TD 会把"复位 → 另一域寄存器的复位脚"当作定时路径分析（实测 4 条恢复路径
    // 违例 -0.365ns）。用无发起时钟的 pll_lock 则该分发路径不参与分析。
    // 我们自研的时序/图案逻辑仍使用 reset_ctrl 的同步复位（S_rst_n_pix）。
    hdmi_tx u_hdmi_tx (
        .I_pixel_clk        ( S_pixel_clk   ),
        .I_serial_clk       ( S_serial_clk  ),
        .I_rst              ( ~S_pll_lock   ),

        .I_key_in           ( 1'b0          ),
        .I_edid_read_trig   ( 1'b0          ),
        .O_edid_read_valid  (               ),
        .O_edid_read_data   (               ),

        // RGB 时序输入模式（hdmi_tx 内部转 stream 时序）
        .I_video_rgb_enable ( 1'b1          ),
        .I_video_in_de      ( S_pat_de      ),
        .I_video_in_vs      ( S_pat_vs      ),
        .I_video_in_user    ( 1'b0          ),
        .I_video_in_valid   ( 1'b0          ),
        .I_video_in_last    ( 1'b0          ),
        .O_video_in_ready   (               ),
        .I_video_in_data    ( S_pat_data    ),

        // 音频不使用
        .I_audio_valid      ( 1'b0          ),
        .I_audio_left_data  ( 24'd0         ),
        .I_audio_right_data ( 24'd0         ),
        .I_i2s_BCLK         ( 1'b0          ),
        .I_i2s_LRCK         ( 1'b0          ),
        .I_i2s_DOUT         ( 1'b0          ),

        // DDC 不使用（M2 起可接 EDID 读取）
        .O_ddc_scl          (               ),
        .IO_ddc_sda         (               ),

        // 旧版直连接口未使用
        .O_hdmi_clk_p       (               ),
        .O_hdmi_tx_p        (               ),

        .O_tmds_ch0_p       ( O_tmds_ch0_p  ),
        .O_tmds_ch1_p       ( O_tmds_ch1_p  ),
        .O_tmds_ch2_p       ( O_tmds_ch2_p  ),
        .O_tmds_clk_p       ( O_tmds_clk_p  )
    );

    // ---------------------------------------------------------------- 状态指示
    reg [23:0] S_hb_cnt;    // 像素域心跳计数器（约 0.22s 翻转一次）
    always @(posedge S_pixel_clk) begin
        if (!S_rst_n_pix) S_hb_cnt <= 24'd0;
        else              S_hb_cnt <= S_hb_cnt + 1'b1;
    end

    reg S_de_seen;          // 是否已产生过有效数据
    always @(posedge S_pixel_clk) begin
        if (!S_rst_n_pix)      S_de_seen <= 1'b0;
        else if (S_de)         S_de_seen <= 1'b1;
    end

    // LED1=PLL 锁定  LED2=像素域心跳  LED3=像素域复位已释放  LED4=已输出过有效数据
    // 板载 4 个独立 LED 为【高电平点亮】（手册 p20：FPGA 引脚经 1K 排阻 RN17 接 LED 阳极、阴极接 GND）
    wire [3:0] S_led_status = { S_de_seen, S_rst_n_pix, S_hb_cnt[23], S_pll_lock };
    assign O_led = S_led_status;

endmodule
