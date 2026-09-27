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
    output wire [3:0] O_led,         // D10/E10/C6/D6（LED1..LED4，高电平点亮）

    // ---- M2：MIPI 摄像头控制（BANK21，3V3；模组侧经 TXS0104E 电平转换）----
    inout  wire       IO_cam_scl,    // K3
    inout  wire       IO_cam_sda,    // J3
    output wire       O_cam_pwdnb,   // L2（=原厂 PWDNB，高=工作）
    output wire       O_cam_clk,     // L3（XCLK 23.81MHz ≈ 24MHz）
    // ---- M3：MIPI CSI-2 接收（2 lane，D-PHY 为器件专用脚，无需 pin 约束）----
    inout  wire        IO_rx_clk_pad_p,   // V16
    inout  wire        IO_rx_clk_pad_n,   // U16
    inout  wire [3:0]  IO_rx_data_pad_p,  // D0=V14 / D1=V15 / D2=V17 / D3=U18（本设计只用 D0/D1）
    inout  wire [3:0]  IO_rx_data_pad_n,  // D0=U14 / D1=U15 / D2=U17 / D3=V18
    // ---- M2：板载 USB-UART（USB-JTAG Cable 的 Type-C 双通道之一）----
    output wire        O_uart_tx      // H1 = FPGA uart_tx（依据官方例程 uart_test.adc；J1 是 uart_rx，本阶段未用）
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

    // ------------------------------------------------- M2：摄像头链路（上电 + I2C 初始化）
    // 本阶段只做控制通路：FCLK 输出 + PWDNB 时序 + I2C 读 ID + 写 165 条寄存器表。
    // MIPI 数据通路（D-PHY 硬核 + CSI-2 解析 + ISP）留待 M3。
    wire        S_i2c_scl_low, S_i2c_sda_low, S_i2c_sda_in;
    wire [7:0]  S_i2c_rdata;
    wire        S_i2c_busy, S_i2c_done, S_i2c_ack_err;

    // 开漏：只拉低或释放（总线外部 4.7K 上拉 + 模组侧 TXS0104E）
    assign IO_cam_scl = S_i2c_scl_low ? 1'b0 : 1'bz;
    assign IO_cam_sda = S_i2c_sda_low ? 1'b0 : 1'bz;
    assign S_i2c_sda_in = IO_cam_sda;

    assign O_cam_clk = S_clk_cam;      // 23.81MHz，手册 EXTCLK 6~40MHz 范围内

    wire        S_cam_go, S_cam_rd;
    wire [6:0]  S_cam_dev;
    wire [15:0] S_cam_sub;
    wire [7:0]  S_cam_wdata;
    wire [8:0]  S_rom_idx;
    wire [23:0] S_rom_data;
    wire [15:0] S_id_pre, S_id_post;
    wire [6:0]  S_dev_used;
    wire [8:0]  S_wr_cnt;
    wire [3:0]  S_cam_err;
    wire        S_cam_busy, S_cam_i2c_ok, S_cam_id_ok;

    i2c_master u_i2c (
        .clk       ( S_clk_100m    ),
        .rst_n     ( S_rst_n_100m  ),
        .I_go      ( S_cam_go      ),
        .I_rd      ( S_cam_rd      ),
        .I_dev     ( S_cam_dev     ),
        .I_sub     ( S_cam_sub     ),
        .I_wdata   ( S_cam_wdata   ),
        .O_rdata   ( S_i2c_rdata   ),
        .O_busy    ( S_i2c_busy    ),
        .O_done    ( S_i2c_done    ),
        .O_ack_err ( S_i2c_ack_err ),
        .O_scl_low ( S_i2c_scl_low ),
        .O_sda_low ( S_i2c_sda_low ),
        .I_sda_in  ( S_i2c_sda_in  )
    );

    cam_ctrl u_cam_ctrl (
        .clk           ( S_clk_100m    ),
        .rst_n         ( S_rst_n_100m  ),
        .O_cam_xshutdn ( O_cam_pwdnb   ),
        .I2C_go        ( S_cam_go      ),
        .I2C_rd        ( S_cam_rd      ),
        .I2C_dev       ( S_cam_dev     ),
        .I2C_sub       ( S_cam_sub     ),
        .I2C_wdata     ( S_cam_wdata   ),
        .I2C_rdata     ( S_i2c_rdata   ),
        .I2C_busy      ( S_i2c_busy    ),
        .I2C_done      ( S_i2c_done    ),
        .I2C_ack_err   ( S_i2c_ack_err ),
        .ROM_idx       ( S_rom_idx     ),
        .ROM_data      ( S_rom_data    ),
        .D_id_pre      ( S_id_pre      ),
        .D_id_post     ( S_id_post     ),
        .D_dev         ( S_dev_used    ),
        .D_wr_cnt      ( S_wr_cnt      ),
        .D_err         ( S_cam_err     ),
        .O_i2c_ok      ( S_cam_i2c_ok  ),
        .O_id_ok       ( S_cam_id_ok   ),
        .D_busy        ( S_cam_busy    )
    );

    // 原厂 720p60 寄存器表（数据件，见 ip/README.md）
    uics520reg_720p60 u_cam_reg (
        .REG_INDEX ( S_rom_idx  ),
        .REG_DATA  ( S_rom_data ),
        .REG_SIZE  (            )
    );

    // ================================================== M3：MIPI CSI-2 接收链路
    // 复用件：ip/mipi_dphy_rx/（D-PHY 硬核 IP 及其官方配套件，见 ip/README.md）
    // 自研件：rtl/mipi/{csi2_pkt_rx,raw10_unpack,mipi_stats}.v
    // 数据通路：D-PHY 字节流 → CSI-2 包解析 → RAW10 解包（4 像素/组）→ 统计/上报
    wire        S_rx_byte_clk;    // o_fabric_div4_8_clk（1:8 模式 = 串行时钟/4 ≈ 103.5MHz）
    wire        S_hs_valid;
    wire [15:0] S_hs_data;
    wire [1:0]  S_lane_err;
    wire        S_di_valid;      // lane_deint 重排后的 CSI-2 字节流
    wire [15:0] S_di_data;

    mipi_dphy_rx_ph1p_mipiio_wrapper #(
        .DPHY_RX_LOCATION ( "DPHY0"  ),
        .HS_EQUALIZER     ( "3dB"    ),   // 828Mbps/lane（表头注明）
        .HS_VGA_GAIN      ( "8dB"    ),
        .LANE_NUM         ( 2        ),
        .BYTE_NUM         ( 1        )    // 1:8 模式
    ) u_mipi_dphy_rx_ph1p_mipiio_wrapper (
        .I_lp_clk              ( S_clk_100m                  ),
        .I_rst                 ( ~S_rst_n_100m               ),

        .I_clk_lane_in_delay   ( 6'd0                        ),
        .I_data_lane0_in_delay ( 6'd0                        ),
        .I_data_lane1_in_delay ( 6'd0                        ),
        .I_data_lane2_in_delay ( 6'd0                        ),
        .I_data_lane3_in_delay ( 6'd0                        ),
        .I_lane_invert         ( 2'b00                       ),

        .O_hs_rx_clk           ( S_rx_byte_clk               ),
        .O_hs_rx_valid         ( S_hs_valid                  ),
        .O_hs_rx_data          ( S_hs_data                   ),

        .O_lp_rx_lane0_p       (                             ),
        .O_lp_rx_lane0_n       (                             ),

        .I_lp_tx_en            ( 1'b0                        ),   // RX-only：不开 LP 反向
        .I_lp_tx_lane0_p       ( 1'b1                        ),
        .I_lp_tx_lane0_n       ( 1'b1                        ),

        .O_lane_match_error    (                             ),
        .O_lane_error          ( S_lane_err                  ),

        .IO_rx_clk_pad_n       ( IO_rx_clk_pad_n             ),
        .IO_rx_clk_pad_p       ( IO_rx_clk_pad_p             ),
        .IO_rx_data_pad_n      ( IO_rx_data_pad_n            ),
        .IO_rx_data_pad_p      ( IO_rx_data_pad_p            )
    );

    // 字节域复位：异步复位、在字节域同步释放（HS 时钟停止时该域逻辑保持复位/冻结）
    reg  [1:0] S_rx_rst_sync;
    always @(posedge S_rx_byte_clk or negedge S_rst_n_100m) begin
        if (!S_rst_n_100m) S_rx_rst_sync <= 2'b00;
        else               S_rx_rst_sync <= {S_rx_rst_sync[0], 1'b1};
    end
    wire S_rst_n_rx = S_rx_rst_sync[1];

    // ---- CSI-2 包解析 ----
    wire        S_fs, S_fe, S_ls, S_le;
    wire        S_pay_valid, S_pay_start, S_pay_end;
    wire [15:0] S_pay_data, S_last_wc;
    wire [5:0]  S_last_dt;
    wire        S_err_dt, S_err_wc, S_err_hdr;
    wire [31:0] S_dbg_hdr;      // 字节域诊断（csi2 → stats）
    wire [15:0] S_dbg_pw;
    wire [14:0] S_dbg_pleft;
    wire [3:0]  S_dbg_hcause;

    // ---- M3：D-PHY 字节流「拍对」重排（lane0/lane1 并行字节 → 标准 CSI-2 字节序）----
    lane_deint u_lane_deint (
        .clk        ( S_rx_byte_clk ),
        .rst_n      ( S_rst_n_rx    ),
        .I_hs_valid ( S_hs_valid    ),
        .I_hs_data  ( S_hs_data     ),
        .O_valid    ( S_di_valid    ),
        .O_data     ( S_di_data     )
    );

    csi2_pkt_rx u_csi2_pkt_rx (
        .clk         ( S_rx_byte_clk ),
        .rst_n       ( S_rst_n_rx    ),
        .I_hs_valid  ( S_di_valid    ),
        .I_hs_data   ( S_di_data     ),
        .O_fs        ( S_fs          ),
        .O_fe        ( S_fe          ),
        .O_ls        ( S_ls          ),
        .O_le        ( S_le          ),
        .O_pay_valid ( S_pay_valid   ),
        .O_pay_data  ( S_pay_data    ),
        .O_pay_start ( S_pay_start   ),
        .O_pay_end   ( S_pay_end     ),
        .O_last_wc   ( S_last_wc     ),
        .O_last_dt   ( S_last_dt     ),
        .O_err_dt    ( S_err_dt      ),
        .O_err_wc    ( S_err_wc      ),
        .O_err_hdr   ( S_err_hdr     ),
        .O_dbg_hdr   ( S_dbg_hdr     ),
        .O_dbg_pw    ( S_dbg_pw      ),
        .O_dbg_pleft ( S_dbg_pleft   ),
        .O_dbg_hcause( S_dbg_hcause  )
    );

    // ---- RAW10 解包（5 字节 → 4 个 10bit 像素）----
    wire        S_px_valid, S_pkt_done;
    wire [39:0] S_px;
    wire [10:0] S_pkt_grp;

    raw10_unpack u_raw10_unpack (
        .clk         ( S_rx_byte_clk ),
        .rst_n       ( S_rst_n_rx    ),
        .I_pay_valid ( S_pay_valid   ),
        .I_pay_data  ( S_pay_data    ),
        .I_pay_start ( S_pay_start   ),
        .I_pay_done  ( S_pay_end     ),
        .O_px_valid  ( S_px_valid    ),
        .O_px        ( S_px          ),
        .O_pkt_done  ( S_pkt_done    ),
        .O_pkt_grp   ( S_pkt_grp     )
    );

    // ---- 统计（字节域计数 → 100MHz 域快照）----
    wire [23:0] S_fs_bcd, S_snap_fs;
    wire [15:0] S_line_bcd, S_snap_line, S_grp_bcd, S_snap_grp;
    wire [19:0] S_wpx_bcd, S_snap_wpx;
    wire [7:0]  S_merr, S_snap_err;
    wire        S_hs_seen, S_snap_hs;
    wire        S_req_t, S_ack_t;
    wire [31:0] S_rdbg_hdr;      // 100M 域诊断（stats → status_report）
    wire [15:0] S_rdbg_pw;
    wire [14:0] S_rdbg_pleft;
    wire [3:0]  S_rdbg_hcause;

    mipi_stats u_mipi_stats (
        .clk_b         ( S_rx_byte_clk ),
        .rst_n_b       ( S_rst_n_rx    ),
        .I_hs_valid    ( S_hs_valid    ),
        .I_lane_error  ( |S_lane_err   ),
        .I_fs          ( S_fs          ),
        .I_fe          ( S_fe          ),
        .I_pay_start   ( S_pay_start   ),
        .I_pkt_done    ( S_pkt_done    ),
        .I_px_grp_valid( S_px_valid    ),
        .I_err_dt      ( S_err_dt      ),
        .I_err_wc      ( S_err_wc      ),
        .I_err_hdr     ( S_err_hdr     ),
        .I_dbg_hdr     ( S_dbg_hdr     ),
        .I_dbg_pw      ( S_dbg_pw      ),
        .I_dbg_pleft   ( S_dbg_pleft   ),
        .I_dbg_hcause  ( S_dbg_hcause  ),

        .O_snap_fs     ( S_snap_fs     ),
        .O_snap_line   ( S_snap_line   ),
        .O_snap_wpx    ( S_snap_wpx    ),
        .O_snap_grp    ( S_snap_grp    ),
        .O_snap_err    ( S_snap_err    ),
        .O_snap_hs     ( S_snap_hs     ),
        .O_req_t       ( S_req_t       ),

        .clk_s         ( S_clk_100m    ),
        .rst_n_s       ( S_rst_n_100m  ),
        .I_ack_t       ( S_ack_t       ),
        .O_ack_t       ( S_ack_t       ),

        .O_fs_bcd      ( S_fs_bcd      ),
        .O_line_bcd    ( S_line_bcd    ),
        .O_wpx_bcd     ( S_wpx_bcd     ),
        .O_grp_bcd     ( S_grp_bcd     ),
        .O_err         ( S_merr        ),
        .O_hs_seen     ( S_hs_seen     ),
        .O_dbg_hdr     ( S_rdbg_hdr    ),
        .O_dbg_pw      ( S_rdbg_pw     ),
        .O_dbg_pleft   ( S_rdbg_pleft  ),
        .O_dbg_hcause  ( S_rdbg_hcause )
    );

    // --------------------------------------------- M2+M3：串口状态上报（两行循环）
    status_report u_status_report (
        .clk        ( S_clk_100m   ),
        .rst_n      ( S_rst_n_100m ),
        .D_id_pre   ( S_id_pre     ),
        .D_id_post  ( S_id_post    ),
        .D_dev      ( S_dev_used   ),
        .D_wr_cnt   ( S_wr_cnt     ),
        .D_err      ( S_cam_err    ),
        .D_fs_bcd   ( S_fs_bcd     ),
        .D_line_bcd ( S_line_bcd   ),
        .D_wpx_bcd  ( S_wpx_bcd    ),
        .D_grp_bcd  ( S_grp_bcd    ),
        .D_merr     ( S_merr       ),
        .D_hs_seen  ( S_hs_seen    ),
        .D_dbg_hdr  ( S_rdbg_hdr   ),
        .D_dbg_pw   ( S_rdbg_pw    ),
        .D_dbg_pleft( S_rdbg_pleft ),
        .D_dbg_hcause(S_rdbg_hcause),
        .O_uart_tx  ( O_uart_tx    )
    );

    // ---------------------------------------------------------------- 状态指示
    reg [23:0] S_hb_cnt;    // 100MHz 域心跳（约 0.17s 翻转一次）
    always @(posedge S_clk_100m) begin
        if (!S_rst_n_100m) S_hb_cnt <= 24'd0;
        else               S_hb_cnt <= S_hb_cnt + 1'b1;
    end

    // M2：LED1=PLL 锁定  LED2=100M 域心跳  LED3=摄像头初始化流程结束  LED4=Sensor ID 校验通过(9E4B)
    // （M1 的像素域指示灯由 LED2 改为 LED3/4 的摄像头状态；HDMI 图案仍在输出，可继续肉眼确认屏幕）
    wire [3:0] S_led_status = { S_cam_id_ok, ~S_cam_busy, S_hb_cnt[23], S_pll_lock };
    assign O_led = S_led_status;

endmodule
