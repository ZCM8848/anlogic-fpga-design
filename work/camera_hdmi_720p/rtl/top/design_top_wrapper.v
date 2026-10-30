/*******************************************************************************
 * camera_hdmi_720p — 板级顶层（M6 三模式重构）
 *
 * 模式（SW1 主选 + SW2 调试子选；拨上=1）：
 *   SW1=0            → 识别/正常：摄像头 + 绿框 + Count（SW2 忽略）
 *   SW1=1, SW2=0     → 静态 HDMI 测试图案（彩条+灰度+移动方块+文字）
 *   SW1=1, SW2=1     → 动态调试画面；KEY1 循环 RGB888/score/mask
 *   SW4              → 保留/留空
 *
 * 数据通路（SW1=0 或 调试动态）：
 *   SC520CS → MIPI D-PHY RX(IP) → csi_unpacket_2lane → raw10_unpacket_2lane
 *   → uial2axis → isp_top[demosaic→awb→pack]
 *   → video_in(async FIFO,4帧乒乓) → mc_to_user_interface → DDR2 IP
 *   → video_out(async FIFO) → hdmi_mixer[识别态 UI（SW1=0 统一叠加）]
 *   → cv_top(CV/BALL 门控；调试态仍保持检测运行) → video_mux → hdmi_tx
 *
 * 时钟（ip/pll/PLL.v，厂商验证配置）：
 *   C0=100MHz 系统  C1=23.81MHz 摄像头XCLK  C4=75MHz 像素  C5=375MHz 串行
 *   S_csi_rx_clk = D-PHY 恢复字节时钟(~103.5MHz)  S_ddr_clk = DDR2 IP 输出用户时钟
 *
 * 复位：PLL lock → reset_ctrl 同步释放（100M/pixel/24m/ddr 域）；
 *   字节域 S_rst_n_rx 经 2FF 同步到 S_csi_rx_clk（喂 ISP/CSI 解包；HS 停摆时该域冻结）；
 *   video_in/video_out 跨多域用 pll_lock 异步复位（S_rst_n，对齐参考工程）；
 *   HDMI IP 复位用异步 ~pll_lock（避免跨 75/375MHz 域复位分发定时违例）。
 ******************************************************************************/
`timescale 1ns / 1ps

module design_top_wrapper (
    input  wire        I_sys_clk,        // C4 板载 50MHz
    output wire [3:0]  O_led,            // D10/E10/C6/D6（高电平点亮）
    output wire [7:0]  O_seg,            // 8 位数码管段选（低有效，SW6 拨上）
    output wire [7:0]  O_sel,            // 8 位数码管位选（低有效）
    output wire        O_buzzer,         // C12 蜂鸣器（低电平响，SW5 控制回路）

    // 摄像头控制（BANK21，3V3；经 TXS0104E 电平转换）
    output wire        O_cam_scl,        // K3
    inout  wire        IO_cam_sda,       // J3
    output wire        O_cam_24m,        // L3 XCLK 23.81MHz
    output wire        O_cam_rst,        // L2 PWDNB（高=工作）
    input  wire [1:0]  I_button,         // N2/J14（保留引脚；曝光/增益改由 MCU 控制）

    // USB-UART
    output wire        O_uart_tx,        // H1
    input  wire        I_uart_rx,        // J1

    // 模式切换（拨上=1）
    input  wire        I_sw1,            // A4（0=识别/正常，1=调试）
    input  wire        I_sw2,            // B4（调试子选：0=静态测试图案，1=动态调试画面）
    input  wire        I_sw4,            // D11（保留/留空）
    input  wire        I_sw3,            // E11（保留；当前不控制识别态 UI，仍进 SW_STAT）
    input  wire        I_key1,           // D5 板载 KEY1（短按：动态调试 RGB/score/mask；长按>=1s：清零 Count+轨迹）
    input  wire        I_key2,           // A9 板载 KEY2（CV 叠加开关：按下切换 CV 开/关）
    input  wire        I_key3,           // B9 板载 KEY3（CV 开时：阈值 -1）
    input  wire        I_key4,           // C7 板载 KEY4（CV 开时：阈值 +1）

    // HDMI 1.4b TX
    output wire        O_tmds_ch0_p,     // G16
    output wire        O_tmds_ch1_p,     // F17
    output wire        O_tmds_ch2_p,     // H14
    output wire        O_tmds_clk_p,     // C17

    // MIPI CSI-2（D-PHY 硬核 pad，不进 pin.adc）
    inout  wire        IO_rx_clk_pad_p,  // V16
    inout  wire        IO_rx_clk_pad_n,  // U16
    inout  wire [3:0]  IO_rx_data_pad_p, // D0=V14/D1=V15/D2=V17/D3=U18（只用 D0/D1）
    inout  wire [3:0]  IO_rx_data_pad_n, // D0=U14/D1=U15/D2=U17/D3=V18

    // DDR2（PHY 硬核 pad，约束由 ip/ddr2 自带 ddr2.adc 提供）
    output wire [12:0] ddr_addr,
    output wire [1:0]  ddr_ba,
    output wire [0:0]  ddr_cke,
    output wire [0:0]  ddr_odt,
    output wire [0:0]  ddr_cs_n,
    output wire        ddr_ras_n,
    output wire        ddr_cas_n,
    output wire        ddr_we_n,
    output wire [0:0]  ddr_ck_p,
    output wire [0:0]  ddr_ck_n,
    inout  wire [1:0]  ddr_dm,
    inout  wire [15:0] ddr_dq,
    inout  wire [1:0]  ddr_dqs_p,
    inout  wire [1:0]  ddr_dqs_n
);

    // ============================================================ 时钟与 PLL
    wire S_clk_100m;     // C0
    wire S_24m_clk;      // C1 摄像头 XCLK / cam 配置域
    wire S_pixel_clk;    // C4 75MHz
    wire S_serial_clk;   // C5 375MHz
    wire S_pll_lock;
    wire S_ahb_clk;      // 前向声明：MCU AHB 总线时钟（ps_wrapper 输出，cv_top/ahb_slave 用）

    PLL u_pll (
        .refclk   ( I_sys_clk    ),
        .reset    ( 1'b0         ),   // 上电复位由芯片内建；不用外部复位
        .clk0_out ( S_clk_100m   ),
        .clk1_out ( S_24m_clk    ),
        .clk4_out ( S_pixel_clk  ),
        .clk5_out ( S_serial_clk ),
        .lock     ( S_pll_lock   )
    );

    // ============================================================ 复位
    wire S_rst_n_100m;
    wire S_rst_n_pix;
    wire S_rst_n_24m;
    wire S_rst_n_ddr;
    wire S_rst_n_50m;

    reset_ctrl u_rst_100m (.clk(S_clk_100m), .pll_lock(S_pll_lock), .rst_n(S_rst_n_100m));
    reset_ctrl u_rst_50m  (.clk(I_sys_clk),  .pll_lock(S_pll_lock), .rst_n(S_rst_n_50m));
    reset_ctrl u_rst_pix  (.clk(S_pixel_clk), .pll_lock(S_pll_lock), .rst_n(S_rst_n_pix));
    reset_ctrl u_rst_24m  (.clk(S_24m_clk),  .pll_lock(S_pll_lock), .rst_n(S_rst_n_24m));

    // 参考工程对 camera→ISP→DDR→display 全链路用 pll_lock 异步复位（跨多时钟域，
    // 异步复位最稳、且 TD 可走全局网络避免高扇出 recovery 违例）。本工程沿用。
    wire S_rst_n = S_pll_lock;

    // MCU 钢珠前端参数（ahb_status_slave 驱动；先声明供 cv_top 使用）
    wire        S_ball_en, S_ball_capture;
    wire [7:0]  S_ball_bg_thr, S_ball_min_run;
    wire [8:0]  S_ball_roi_y1;
    wire [9:0]  S_ball_max_run_len;
    wire [15:0] S_skip_roi_cnt, S_skip_len_cnt;
    wire        S_ball_bg_ready, S_ball_capturing;

    // ============================================================ 摄像头上电时序 + I2C 配置（参考件）
    reg  [17:0] S_cam_power_cnt;
    reg         S_cam_pwdnb;
    reg         S_cam_i2c_ready;
    localparam integer CAM_PWDNB_LOW_CYCLES  = 23810;   // >=1ms @ 23.81MHz
    localparam integer CAM_I2C_START_CYCLES  = 142857;  // 释放后再等 >=5ms

    always @(posedge S_24m_clk or negedge S_pll_lock) begin
        if (!S_pll_lock) begin
            S_cam_power_cnt <= 18'd0;
            S_cam_pwdnb     <= 1'b0;
            S_cam_i2c_ready <= 1'b0;
        end else begin
            if (S_cam_power_cnt < CAM_I2C_START_CYCLES)
                S_cam_power_cnt <= S_cam_power_cnt + 1'b1;
            if (S_cam_power_cnt >= CAM_PWDNB_LOW_CYCLES)
                S_cam_pwdnb <= 1'b1;
            if (S_cam_power_cnt >= CAM_I2C_START_CYCLES - 1)
                S_cam_i2c_ready <= 1'b1;
        end
    end

    assign O_cam_rst  = S_cam_pwdnb;
    assign O_cam_24m  = S_24m_clk;

    wire [15:0] S_ae;
    wire [15:0] S_ag;
    wire [15:0] S_cam_ae_ahb, S_cam_ag_ahb;
    wire        S_buzz_toggle_ahb;
    wire [31:0] S_buzz_cfg_ahb;
    reg  [15:0] S_cam_ae_24m_a, S_cam_ae_24m;
    reg  [15:0] S_cam_ag_24m_a, S_cam_ag_24m;
    wire        S_cam_cfg_done;
    wire        S_ae_cfg_done;
    wire        S_ae_req;

    // AHB(150M) -> camera config clock(24M), values are static after boot.
    always @(posedge S_24m_clk) begin
        S_cam_ae_24m_a <= S_cam_ae_ahb;
        S_cam_ae_24m   <= S_cam_ae_24m_a;
        S_cam_ag_24m_a <= S_cam_ag_ahb;
        S_cam_ag_24m   <= S_cam_ag_24m_a;
    end
    wire [15:0] S_cam_sensor_id;
    wire        S_cam_sensor_id_ok;
    wire        S_cam_i2c_error;

    ae_set u_ae_set (
        .I_clk        ( S_24m_clk         ),
        .I_rst        ( ~S_pll_lock       ),
        .I_ae_set     ( S_cam_ae_24m      ),
        .I_ag_set     ( S_cam_ag_24m      ),
        .I_cam_cfg_done( S_cam_cfg_done   ),
        .I_ae_cfg_done( S_ae_cfg_done     ),
        .O_ae_req     ( S_ae_req          ),
        .O_ae         ( S_ae              ),
        .O_ag         ( S_ag              )
    );

    uicfgcs520 #(
        .CLK_DIV ( 23809524 / 100000 - 1 )
    ) u_uicfgcs520 (
        .I_clk          ( S_24m_clk          ),
        .I_rst_n        ( S_cam_i2c_ready    ),
        .I_ae_req       ( S_ae_req           ),
        .I_ae           ( S_ae               ),
        .I_ag           ( S_ag               ),
        .O_cam_scl      ( O_cam_scl          ),
        .IO_cam_sda     ( IO_cam_sda         ),
        .O_cfg_done     ( S_cam_cfg_done     ),
        .O_ae_cfg_done  ( S_ae_cfg_done      ),
        .O_sensor_id    ( S_cam_sensor_id    ),
        .O_sensor_id_ok ( S_cam_sensor_id_ok ),
        .O_iic_error    ( S_cam_i2c_error    )
    );

    // ============================================================ MIPI D-PHY RX（复用 IP）
    wire        S_csi_rx_clk;     // D-PHY 恢复字节时钟(~103.5MHz)
    wire        S_hs_rx_valid;
    wire [15:0] S_hs_rx_data;
    wire [1:0]  S_lane_error;

    mipi_dphy_rx_ph1p_mipiio_wrapper #(
        .DPHY_RX_LOCATION      ( "DPHY0" ),
        .HS_EQUALIZER          ( "3dB"   ),
        .HS_VGA_GAIN           ( "8dB"   ),
        .LANE_NUM              ( 2       ),
        .BYTE_NUM              ( 1       )
    ) u_mipi_dphy_rx_ph1p_mipiio_wrapper (
        .I_lp_clk              ( S_clk_100m         ),
        .I_rst                 ( ~S_rst_n_100m      ),
        .I_clk_lane_in_delay   ( 6'd0               ),
        .I_data_lane0_in_delay ( 6'd0               ),
        .I_data_lane1_in_delay ( 6'd0               ),
        .I_data_lane2_in_delay ( 6'd0               ),
        .I_data_lane3_in_delay ( 6'd0               ),
        .I_lane_invert         ( 4'b0000            ),
        .O_hs_rx_clk           ( S_csi_rx_clk       ),
        .O_hs_rx_valid         ( S_hs_rx_valid      ),
        .O_hs_rx_data          ( S_hs_rx_data       ),
        .O_lp_rx_lane0_p       (                    ),
        .O_lp_rx_lane0_n       (                    ),
        .I_lp_tx_en            ( 1'b0               ),
        .I_lp_tx_lane0_p       ( 1'b1               ),
        .I_lp_tx_lane0_n       ( 1'b1               ),
        .O_lane_match_error    (                    ),
        .O_lane_error          ( S_lane_error       ),
        .IO_rx_clk_pad_n       ( IO_rx_clk_pad_n    ),
        .IO_rx_clk_pad_p       ( IO_rx_clk_pad_p    ),
        .IO_rx_data_pad_n      ( IO_rx_data_pad_n   ),
        .IO_rx_data_pad_p      ( IO_rx_data_pad_p   )
    );

    // 字节域复位：HS 时钟停摆时该域逻辑冻结（复位保持）；2FF 同步到 S_csi_rx_clk
    reg [1:0] S_rx_rst_sync;
    always @(posedge S_csi_rx_clk or negedge S_rst_n_100m) begin
        if (!S_rst_n_100m) S_rx_rst_sync <= 2'b00;
        else               S_rx_rst_sync <= {S_rx_rst_sync[0], 1'b1};
    end
    wire S_rst_n_rx = S_rx_rst_sync[1];

    // ============================================================ CSI-2 / RAW10 解包（参考件）
    wire        S_csi_frame_start;
    wire        S_csi_frame_end;
    wire        S_csi_valid;
    wire [31:0] S_csi_data;

    csi_unpacket_2lane u_csi_unpacket (
        .I_clk             ( S_csi_rx_clk       ),
        .I_rst_n           ( S_rst_n_rx         ),
        .I_hs_valid        ( S_hs_rx_valid      ),
        .I_hs_data         ( S_hs_rx_data       ),
        .O_csi_frame_start ( S_csi_frame_start  ),
        .O_csi_frame_end   ( S_csi_frame_end    ),
        .O_csi_valid       ( S_csi_valid        ),
        .O_csi_hs         (                    ),
        .O_csi_data        ( S_csi_data         )
    );

    wire        S_raw10_frame_start;
    wire        S_raw10_frame_end;
    wire        S_raw10_valid;
    wire [39:0] S_raw10_data;

    raw10_unpacket_2lane u_raw10_unpacket (
        .I_clk             ( S_csi_rx_clk       ),
        .I_rst_n           ( S_rst_n_rx         ),
        .I_csi_frame_start ( S_csi_frame_start  ),
        .I_csi_frame_end   ( S_csi_frame_end    ),
        .I_csi_valid       ( S_csi_valid        ),
        .I_csi_data        ( S_csi_data         ),
        .I_camera_black_level ( 10'd0           ),
        .O_raw10_frame_start( S_raw10_frame_start),
        .O_raw10_frame_end ( S_raw10_frame_end  ),
        .O_raw10_valid     ( S_raw10_valid      ),
        .O_raw10_data      ( S_raw10_data       )
    );

    wire        S_axis_tvalid;
    wire [39:0] S_axis_tdata;
    wire        S_axis_tuser;
    wire        S_axis_tlast;

    uial2axis #(
        .IMG_WIDTH        ( 1280 ),
        .IMG_HEIGHT       ( 720  ),
        .INPUT_DATA_WIDTH ( 40   )
    ) u_uial2axis (
        .I_native_clk  ( S_csi_rx_clk         ),
        .I_rst_n       ( S_rst_n_rx        ),
        .I_data        ( S_raw10_data         ),
        .I_data_valid  ( S_raw10_valid        ),
        .I_data_start  ( S_raw10_frame_start  ),
        .I_data_end    ( S_raw10_frame_end    ),
        .axis_tvalid   ( S_axis_tvalid        ),
        .axis_tdata    ( S_axis_tdata         ),
        .axis_tuser    ( S_axis_tuser         ),
        .axis_tlast    ( S_axis_tlast         )
    );

    // ============================================================ ISP（参考件；edge 模式已移除）
    wire        S_ISP_O_tready;
    wire [127:0] S_ISP_O_tdata;
    wire        S_ISP_O_tlast;
    wire        S_ISP_O_tuser;
    wire        S_ISP_O_tvalid;

    isp_top u_isp_top (
        .axi4s_video_aclk ( S_csi_rx_clk    ),
        .I_rst_n          ( S_rst_n_rx     ),
        .I_tlast          ( S_axis_tlast    ),
        .I_tuser          ( S_axis_tuser    ),
        .I_tdata          ( S_axis_tdata    ),
        .I_tvalid         ( S_axis_tvalid   ),
        .I_tdest          (                 ),
        .O_tready         ( S_ISP_O_tready  ),
        .O_tdata          ( S_ISP_O_tdata   ),
        .O_tlast          ( S_ISP_O_tlast   ),
        .O_tuser          ( S_ISP_O_tuser   ),
        .O_tvalid         ( S_ISP_O_tvalid  ),
        .I_tready         (                 )
    );

    // ============================================================ DDR2 帧缓存（参考件 video_in/out + mc 桥 + IP）
    wire        S_ddr_clk;
    wire        S_ddr_rdy;        // O_init_calib_complete

    // 前向声明：video_out（本段）引用这些信号，它们由后段 hdmi_timing/hdmi_mixer 驱动。
    // 必须先声明再使用，否则按隐式 1 位线网处理、多位信号被截断（本工程防范的坑）。
    wire        S_hdmi_vsync;
    wire        S_hdmi_window_rd_en;
    wire [23:0] S_video_rd_data;

    // video_in / video_out / mc_to_user_interface 间互连
    wire        S_video_out_rd_busy;
    wire        S_video_in_wr_busy;
    wire [1:0]  S_video_out_rp;

    wire        S_vi_ddr_wr_en;
    wire [24:0] S_vi_ddr_wr_addr;
    wire [127:0]S_vi_ddr_wr_data;

    wire        S_vo_ddr_rd_en;
    wire [24:0] S_vo_ddr_rd_addr;

    wire        S_ddr_user_wr_en;
    wire        S_ddr_user_rd_en;
    wire [24:0] S_ddr_user_addr;
    wire [127:0]S_ddr_user_wr_data;
    wire        S_ddr_user_ready;
    wire        S_ddr_user_rd_valid;
    wire [127:0]S_ddr_user_rd_data;

    // mc 应用口（mc_to_user_interface ↔ DDR IP）
    wire [24:0] S_mc_app_addr;
    wire [2:0]  S_mc_app_cmd;
    wire        S_mc_app_en;
    wire [127:0]S_mc_app_wdf_data;
    wire        S_mc_app_wdf_end;
    wire [31:0] S_mc_app_wdf_mask;
    wire        S_mc_app_wdf_wren;
    wire [127:0]S_mc_app_rd_data;
    wire        S_mc_app_rd_data_end;
    wire        S_mc_app_rd_data_valid;
    wire        S_mc_app_rdy;
    wire        S_mc_app_wdf_rdy;

    video_in u_video_in (
        .I_rst_n              ( S_rst_n           ),   // PLL lock（异步，与参考一致）
        .I_camera_clk         ( S_csi_rx_clk      ),
        .I_camera_frame_start ( S_ISP_O_tuser     ),
        .I_camera_valid       ( S_ISP_O_tvalid    ),
        .I_camera_data        ( S_ISP_O_tdata     ),
        .I_mipi_rx_error      ( 1'b0              ),
        .I_ddr_clk            ( S_ddr_clk         ),
        .I_display_pause      ( 1'b0              ),
        .I_video_out_rd_busy  ( S_video_out_rd_busy ),
        .O_video_in_wr_busy   ( S_video_in_wr_busy  ),
        .O_video_out_rp       ( S_video_out_rp      ),
        .O_ddr_user_wr_en     ( S_vi_ddr_wr_en      ),
        .O_ddr_user_addr      ( S_vi_ddr_wr_addr    ),
        .O_ddr_user_wr_data   ( S_vi_ddr_wr_data    ),
        .I_ddr_user_ready     ( S_ddr_user_ready    )
    );

    // 用户口仲裁：video_in 写 / video_out 读 → 单 mc_app 口（参考接法）
    assign S_ddr_user_wr_en   = S_vi_ddr_wr_en;
    assign S_ddr_user_rd_en   = S_vo_ddr_rd_en;
    assign S_ddr_user_addr    = S_vi_ddr_wr_en ? S_vi_ddr_wr_addr :
                                 S_vo_ddr_rd_en ? S_vo_ddr_rd_addr : 25'd0;
    assign S_ddr_user_wr_data = S_vi_ddr_wr_data;

    video_out u_video_out (
        .I_rst_n             ( S_rst_n            ),
        .I_ddr_clk           ( S_ddr_clk          ),
        .O_video_out_rd_busy ( S_video_out_rd_busy ),
        .I_video_in_wr_busy  ( S_video_in_wr_busy  ),
        .I_video_out_rp      ( S_video_out_rp      ),
        .O_ddr_user_rd_en    ( S_vo_ddr_rd_en      ),
        .O_ddr_user_addr     ( S_vo_ddr_rd_addr    ),
        .I_ddr_user_ready    ( S_ddr_user_ready    ),
        .I_ddr_user_rd_valid ( S_ddr_user_rd_valid ),
        .I_ddr_user_rd_data  ( S_ddr_user_rd_data  ),
        .I_dsi_clk           ( S_pixel_clk         ),
        .I_video_vsync       ( ~S_hdmi_vsync       ),   // video_out 期望有效低 vsync
        .I_video_rd_en       ( S_hdmi_window_rd_en ),
        .O_vdieo_data        ( S_video_rd_data     )
    );

    mc_to_user_interface u_mc_to_user_interface (
        .I_clk                   ( S_ddr_clk             ),
        .I_rst_n                 ( S_rst_n_ddr           ),
        .I_ddr_user_wr_en        ( S_ddr_user_wr_en      ),
        .I_ddr_user_rd_en        ( S_ddr_user_rd_en      ),
        .I_ddr_user_addr         ( S_ddr_user_addr       ),
        .I_ddr_user_wr_data      ( S_ddr_user_wr_data    ),
        .O_ddr_user_ready        ( S_ddr_user_ready      ),
        .O_ddr_user_rd_valid     ( S_ddr_user_rd_valid   ),
        .O_ddr_user_rd_data      ( S_ddr_user_rd_data    ),
        .O_mc_app_en             ( S_mc_app_en           ),
        .O_mc_app_addr           ( S_mc_app_addr         ),
        .O_mc_app_cmd            ( S_mc_app_cmd          ),
        .I_mc_app_rdy            ( S_mc_app_rdy          ),
        .O_mc_app_wdf_wren       ( S_mc_app_wdf_wren     ),
        .O_mc_app_wdf_data       ( S_mc_app_wdf_data     ),
        .O_mc_app_wdf_end        ( S_mc_app_wdf_end      ),
        .O_mc_app_wdf_mask       ( S_mc_app_wdf_mask     ),
        .I_mc_app_wdf_rdy        ( S_mc_app_wdf_rdy      ),
        .I_mc_app_rd_data        ( S_mc_app_rd_data      ),
        .I_mc_app_rd_data_end    ( S_mc_app_rd_data_end  ),
        .I_mc_app_rd_data_valid  ( S_mc_app_rd_data_valid)
    );

    ph1p35_324_ddr_wrapper u_ph1p35_324_ddr_wrapper (
        .I_sys_clk              ( I_sys_clk             ),
        .I_sys_rst_n            ( S_rst_n_100m          ),
        .O_ddr_clk              ( S_ddr_clk             ),
        .O_init_calib_complete  ( S_ddr_rdy             ),
        .I_mc_app_addr          ( S_mc_app_addr         ),
        .I_mc_app_cmd           ( S_mc_app_cmd          ),
        .I_mc_app_en            ( S_mc_app_en           ),
        .I_mc_app_wdf_data      ( S_mc_app_wdf_data     ),
        .I_mc_app_wdf_end       ( S_mc_app_wdf_end      ),
        .I_mc_app_wdf_mask      ( S_mc_app_wdf_mask[15:0] ),
        .I_mc_app_wdf_wren      ( S_mc_app_wdf_wren     ),
        .O_mc_app_rd_data       ( S_mc_app_rd_data      ),
        .O_mc_app_rd_data_end   ( S_mc_app_rd_data_end  ),
        .O_mc_app_rd_data_valid ( S_mc_app_rd_data_valid),
        .O_mc_app_rdy           ( S_mc_app_rdy          ),
        .O_mc_app_wdf_rdy       ( S_mc_app_wdf_rdy      ),
        .ddr_addr               ( ddr_addr              ),
        .ddr_ba                 ( ddr_ba                ),
        .ddr_cke                ( ddr_cke               ),
        .ddr_odt                ( ddr_odt               ),
        .ddr_cs_n               ( ddr_cs_n              ),
        .ddr_ras_n              ( ddr_ras_n             ),
        .ddr_cas_n              ( ddr_cas_n             ),
        .ddr_we_n               ( ddr_we_n              ),
        .ddr_ck_p               ( ddr_ck_p              ),
        .ddr_ck_n               ( ddr_ck_n              ),
        .ddr_dm                 ( ddr_dm                ),
        .ddr_dq                 ( ddr_dq                ),
        .ddr_dqs_p              ( ddr_dqs_p             ),
        .ddr_dqs_n              ( ddr_dqs_n             )
    );

    // DDR 用户域复位：PLL 锁定且校准完成后释放
    reset_ctrl u_rst_ddr (.clk(S_ddr_clk), .pll_lock(S_pll_lock & S_ddr_rdy), .rst_n(S_rst_n_ddr));

    // ============================================================ 视频时序（自研 hdmi_timing，替代 uivtc）
    wire        S_hdmi_hsync;
    wire        S_hdmi_de;
    wire        S_hdmi_user;
    wire        S_hdmi_last;
    wire [11:0] S_x;
    wire [11:0] S_y;

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
        .clk   ( S_pixel_clk  ),
        .rst_n ( S_rst_n_pix  ),
        .vs    ( S_hdmi_vsync ),
        .hs    ( S_hdmi_hsync ),
        .de    ( S_hdmi_de    ),
        .x     ( S_x          ),
        .y     ( S_y          ),
        .user  ( S_hdmi_user  ),
        .last  ( S_hdmi_last  )
    );

    // ============================================================ 彩条测试图案（自研，SW1=1 & SW2=0 时输出）
    wire [23:0] S_pat_data;
    wire        S_pat_de;
    wire        S_pat_vs;

    test_pattern u_pattern (
        .clk   ( S_pixel_clk  ),
        .rst_n ( S_rst_n_pix  ),
        .vs    ( S_hdmi_vsync ),
        .de    ( S_hdmi_de    ),
        .x     ( S_x          ),
        .y     ( S_y          ),
        .data  ( S_pat_data   ),
        .de_o  ( S_pat_de     ),
        .vs_o  ( S_pat_vs     )
    );

    // ============================================================ 模式同步 / 调试显示
    // SW1=0 识别（正常），SW1=1 调试；SW2 只在调试态生效：
    //   SW2=0 静态测试图案（带文字），SW2=1 动态调试（K1 循环 RGB/score/mask）
    reg  [2:0]  S_sw3_sync_pix;
    reg  [2:0]  S_sw1_sync_pix;
    reg  [2:0]  S_sw2_sync_pix;
    always @(posedge S_pixel_clk or negedge S_rst_n_pix) begin
        if (!S_rst_n_pix) begin
            S_sw3_sync_pix <= 3'd0;
            S_sw1_sync_pix <= 3'd0;
            S_sw2_sync_pix <= 3'd0;
        end else begin
            S_sw3_sync_pix <= {S_sw3_sync_pix[1:0], I_sw3};
            S_sw1_sync_pix <= {S_sw1_sync_pix[1:0], I_sw1};
            S_sw2_sync_pix <= {S_sw2_sync_pix[1:0], I_sw2};
        end
    end
    wire S_debug_mode    = S_sw1_sync_pix[2];
    wire S_debug_dynamic = S_debug_mode &  S_sw2_sync_pix[2];
    wire S_debug_static  = S_debug_mode & ~S_sw2_sync_pix[2];
    wire S_camera_sel    = ~S_debug_static;   // 0=测试图案，1=摄像头/CV

    // KEY1=D5：短按动态调试循环 RGB(纯净) -> score -> mask
    //             长按 >=1s：发出 KEY_EVT，MCU 清零计数与轨迹
    reg [20:0] r_key1_cnt;
    reg [2:0]  r_key1_sync;
    reg        r_key1_d;
    reg [7:0]  r_key1_hold;
    reg        r_key1_long_done;
    reg        S_key1_long;
    reg [1:0]  S_disp_mode;
    reg        S_song_play;          // 静态测试态蜂鸣曲播放/暂停
    wire       key1_fall = ~r_key1_sync[2] & r_key1_d;
    wire       key1_rise =  r_key1_sync[2] & ~r_key1_d;
    always @(posedge S_pixel_clk or negedge S_rst_n_pix) begin
        if (!S_rst_n_pix) begin
            r_key1_cnt <= 21'd0; r_key1_sync <= 3'd0; r_key1_d <= 1'b0;
            r_key1_hold <= 8'd0; r_key1_long_done <= 1'b0; S_key1_long <= 1'b0;
            S_disp_mode <= 2'd3;
            S_song_play <= 1'b0;
        end else begin
            r_key1_sync <= {r_key1_sync[1:0], I_key1};
            if (r_key1_cnt == 21'd1048575) begin   // ~14ms @75MHz
                r_key1_cnt <= 21'd0;
                r_key1_d   <= r_key1_sync[2];
                if (!r_key1_sync[2]) begin
                    if (r_key1_hold < 8'd70) r_key1_hold <= r_key1_hold + 8'd1;
                    if (r_key1_hold == 8'd69) begin
                        S_key1_long     <= 1'b1;
                        r_key1_long_done <= 1'b1;
                    end else begin
                        S_key1_long <= 1'b0;
                    end
                end else begin
                    r_key1_hold      <= 8'd0;
                    S_key1_long      <= 1'b0;
                    r_key1_long_done <= 1'b0;
                end
                if (key1_fall && S_debug_dynamic && !r_key1_long_done) begin
                    if (S_disp_mode == 2'd3)      S_disp_mode <= 2'd1;
                    else if (S_disp_mode == 2'd1) S_disp_mode <= 2'd2;
                    else                          S_disp_mode <= 2'd3;
                end
                // 静态测试态：K1 短按切换蜂鸣曲播放/暂停；离开静态态自动暂停
                if (!S_debug_static) begin
                    S_song_play <= 1'b0;
                end else if (key1_rise && !r_key1_long_done) begin
                    S_song_play <= ~S_song_play;
                end
            end else begin
                r_key1_cnt <= r_key1_cnt + 21'd1;
            end
        end
    end

    // ============================================================ CV / ball 前端
    // 正常和调试态都保持检测运行；显示源由 SW1/SW2/K1 决定。
    reg [2:0] S_ball_en_sync_pix;
    always @(posedge S_pixel_clk or negedge S_rst_n_pix) begin
        if (!S_rst_n_pix) S_ball_en_sync_pix <= 3'd0;
        else              S_ball_en_sync_pix <= {S_ball_en_sync_pix[1:0], S_ball_en};
    end
    wire S_ball_mode = S_ball_en_sync_pix[2];
    wire S_cv_eff = S_ball_mode;
    // ============================================================ KEY2 长按 → 背景重采事件
    // KEY2=A9 板载按键（PULLUP，按下=0）。~14ms 采样去抖，长按 >=1s 置 r_key2_long。
    // r_key2_long 保持到松手，由 ahb_status_slave 取上升沿生成 KEY_EVT[1]。
    reg [20:0] r_key2_cnt;
    reg [2:0]  r_key2_sync;
    reg [7:0]  r_key2_hold;
    reg        r_key2_long;
    always @(posedge S_pixel_clk or negedge S_rst_n_pix) begin
        if (!S_rst_n_pix) begin
            r_key2_cnt <= 21'd0; r_key2_sync <= 3'd0;
            r_key2_hold <= 8'd0; r_key2_long <= 1'b0;
        end else begin
            r_key2_sync <= {r_key2_sync[1:0], I_key2};
            if (r_key2_cnt == 21'd1048575) begin   // ~14ms @75MHz
                r_key2_cnt <= 21'd0;
                if (!r_key2_sync[2]) begin
                    if (r_key2_hold < 8'd70) r_key2_hold <= r_key2_hold + 8'd1;
                    if (r_key2_hold == 8'd69) r_key2_long <= 1'b1;
                end else begin
                    r_key2_hold <= 8'd0;
                    r_key2_long <= 1'b0;
                end
            end else begin
                r_key2_cnt <= r_key2_cnt + 21'd1;
            end
        end
    end

    // 识别态 UI：SW1=0 整套 OSD 同时显示（Logo / 标签 / Count / 文本 / FRAME）
    wire S_ui_on = ~S_debug_mode;

    wire        S_hdmi_out_vsync;
    wire        S_hdmi_out_hsync;
    wire        S_hdmi_out_de;
    wire [23:0] S_hdmi_out_data;
    wire [3:0]  S_ball_now;       // slave → hdmi_mixer（当前框数）

    hdmi_mixer #(
        .H_OFFSET   ( 0    ),
        .V_OFFSET   ( 0    ),
        .IMG_WIDTH  ( 1280 ),
        .IMG_HEIGHT ( 720  ),
        .DEBUG_MODE ( 0    )
    ) u_hdmi_mixer (
        .I_clk           ( S_pixel_clk         ),
        .I_rst_n         ( S_rst_n_pix         ),
        .I_video_vsync   ( S_hdmi_vsync        ),
        .I_video_hsync   ( S_hdmi_hsync        ),
        .I_video_de      ( S_hdmi_de           ),
        .I_video_user    ( S_hdmi_user         ),
        .I_video_last    ( S_hdmi_last         ),
        .I_osd_on        ( 1'b0                ),
        .I_ui_on         ( S_ui_on             ),
        .I_ball_now      ( S_ball_now          ),
        .I_debug_status  ( 4'd0                ),
        .O_video_rd_en   ( S_hdmi_window_rd_en ),
        .I_video_rd_data ( S_video_rd_data     ),
        .O_hdmi_vsync    ( S_hdmi_out_vsync    ),
        .O_hdmi_hsync    ( S_hdmi_out_hsync    ),
        .O_hdmi_de       ( S_hdmi_out_de       ),
        .O_hdmi_data     ( S_hdmi_out_data     )
    );

    // ============================================================ CV 叠加 + 数据通路（v2）
    // cv_top 只留像素级前端（Sobel/run 写）+ 叠加；CCL/跟踪/计数转 MCU。
    // run_mem B 口：cv_top 写(pixel) / ahb slave 读(ahb_clk)；overlay/count：slave 写 / cv_top 读。
    wire [23:0] S_cv_data;
    wire        S_cv_de;
    wire        S_cv_vs;
    wire [10:0] S_cv_run_cnt;
    wire        S_cv_run_overflow;
    wire [7:0]  S_cv_bin_thr;
    wire [7:0]  S_cv_min_y, S_cv_max_y;
    wire [9:0]  S_run_rd_addr;     // slave → cv_top（run_mem B 口地址）
    wire [31:0] S_run_rd_data;    // cv_top → slave（run_mem B 口数据）
    wire [511:0] S_overlay;        // slave → cv_top（叠加 bbox+ID）
    wire [15:0]  S_count;          // slave → cv_top（exit 计数显示）
    wire [19:0]  S_count_bcd;      // slave → cv_top / 数码管（5 位 BCD）
    wire         S_seg_dash;       // slave → 数码管（背景重采样时全横线）
    wire [8:0]   S_gate_x;         // slave → cv_top（门线 x，320x180）
    wire [7:0]   S_gate_y0, S_gate_y1;

    // K3(B9)/K4(C7) 板载按键：CV 开时作阈值 ±1 调参（像素域去抖 → 单拍脉冲）
    // 注：脉冲必须单拍——cv_top 每周期判 I_thr_up/dn，若发 14ms 电平会被加到饱和
    //     （K4 一次冲到 255 全黑、K3 冲到 0 全白）。故只在「检测到按下的那个溢出周期」
    //     置 1，下一周期清 0（与 KEY2 翻转同模式：在溢出分支内评估一次）。
    reg [20:0] r_btn_cnt;
    reg [2:0]  r_btn0_sync, r_btn1_sync;
    reg        r_btn0_d, r_btn1_d;
    reg        R_thr_dn, R_thr_up;
    always @(posedge S_pixel_clk or negedge S_rst_n_pix) begin
        if (!S_rst_n_pix) begin
            r_btn_cnt <= 21'd0; r_btn0_sync <= 3'd0; r_btn1_sync <= 3'd0;
            r_btn0_d <= 1'b0; r_btn1_d <= 1'b0;
            R_thr_dn <= 1'b0; R_thr_up <= 1'b0;
        end else begin
            r_btn0_sync <= {r_btn0_sync[1:0], I_key3};   // K3=B9
            r_btn1_sync <= {r_btn1_sync[1:0], I_key4};   // K4=C7
            if (r_btn_cnt == 21'd1048575) begin
                r_btn_cnt <= 21'd0;
                // 用 OLD r_btn_d（按下前=1）与当前采样（按下=0）判下降沿，单拍置 1
                // K3/K4 legacy pulses; cv_top 当前不消费 I_thr_up/dn
                R_thr_dn  <= ~r_btn0_sync[2] & r_btn0_d;
                R_thr_up  <= ~r_btn1_sync[2] & r_btn1_d;
                r_btn0_d  <= r_btn0_sync[2];
                r_btn1_d  <= r_btn1_sync[2];
            end else begin
                r_btn_cnt <= r_btn_cnt + 21'd1;
                R_thr_dn  <= 1'b0;   // 其余周期清 0 → 脉冲只有 1 拍
                R_thr_up  <= 1'b0;
            end
        end
    end

    cv_top #(
        .IMG_W    ( 1280   ),
        .IMG_H    ( 720    ),
        .BIN_THR  ( 8'd91  ),
        .EDGE_THR ( 11'd80 ),
        .MASK_SRC ( 1      ),
        .MAX_RUNS ( 1024   ),
        .MASK_VIEW( 0      ),
        .FBOX_W   ( 12'd2  ),
        .MAX_OV   ( 8      ),
        .BALL_W   ( 320    ),
        .BALL_H   ( 180    ),
        .BALL_SCALE ( 4    )
    ) u_cv_top (
        .I_clk          ( S_pixel_clk      ),
        .I_rst_n        ( S_rst_n_pix      ),
        .I_cv_on        ( S_cv_eff         ),
        .I_ui_on        ( S_ui_on          ),
        .I_thr_up       ( R_thr_up         ),
        .I_thr_dn       ( R_thr_dn         ),
        .I_de           ( S_hdmi_out_de    ),
        .I_vs           ( S_hdmi_out_vsync ),
        .I_data         ( S_hdmi_out_data  ),
        .I_ball_en      ( S_ball_mode      ),
        .I_ball_bg_thr  ( S_ball_bg_thr    ),
        .I_ball_min_run ( S_ball_min_run   ),
        .I_ball_roi_y1  ( S_ball_roi_y1    ),
        .I_ball_max_run_len ( S_ball_max_run_len ),
        .I_ball_capture ( S_ball_capture   ),
        .I_disp_mode    ( S_disp_mode      ),
        .I_debug_view   ( S_debug_dynamic  ),
        .O_ball_bg_ready( S_ball_bg_ready  ),
        .O_ball_capturing(S_ball_capturing ),
        .I_ahb_clk      ( S_ahb_clk        ),
        .I_run_rd_addr  ( S_run_rd_addr    ),
        .O_run_rd_data  ( S_run_rd_data    ),
        .I_overlay      ( S_overlay        ),
        .I_count        ( S_count          ),
        .I_count_bcd    ( S_count_bcd      ),
        .I_gate_x       ( S_gate_x         ),
        .I_gate_y0      ( S_gate_y0        ),
        .I_gate_y1      ( S_gate_y1        ),
        .O_de           ( S_cv_de          ),
        .O_vs           ( S_cv_vs          ),
        .O_data         ( S_cv_data        ),
        .O_run_cnt      ( S_cv_run_cnt     ),
        .O_min_y        ( S_cv_min_y       ),
        .O_max_y        ( S_cv_max_y       ),
        .O_skip_roi_cnt ( S_skip_roi_cnt   ),
        .O_skip_len_cnt ( S_skip_len_cnt   ),
        .O_run_overflow ( S_cv_run_overflow),
        .O_bin_thr      ( S_cv_bin_thr     )
    );

    // CV 始终实时运行；run_cnt 直接送 MCU
    // ============================================================ video_mux（自研，测试图案 vs 摄像头二选一）
    wire [23:0] S_vid_data;
    wire        S_vid_de;
    wire        S_vid_vs;
    wire        S_vid_sel;

    video_mux u_video_mux (
        .clk          ( S_pixel_clk      ),
        .rst_n        ( S_rst_n_pix      ),
        .I_camera_sel ( S_camera_sel     ),
        .I_pat_data   ( S_pat_data       ),
        .I_pat_de     ( S_pat_de         ),
        .I_pat_vs     ( S_pat_vs         ),
        .I_cam_data   ( S_cv_data        ),
        .I_cam_de     ( S_cv_de          ),
        .I_cam_vs     ( S_cv_vs          ),
        .O_data       ( S_vid_data       ),
        .O_de         ( S_vid_de         ),
        .O_vs         ( S_vid_vs         ),
        .O_sel        ( S_vid_sel        )
    );

    // ============================================================ HDMI 1.4b TX（复用 IP）
    hdmi_tx u_hdmi_tx (
        .I_pixel_clk        ( S_pixel_clk   ),
        .I_serial_clk       ( S_serial_clk  ),
        .I_rst              ( ~S_pll_lock   ),
        .I_key_in           ( 1'b0          ),
        .I_edid_read_trig   ( 1'b0          ),
        .O_edid_read_valid  (               ),
        .O_edid_read_data   (               ),
        .I_video_rgb_enable ( 1'b1          ),
        .I_video_in_de      ( S_vid_de      ),
        .I_video_in_vs      ( S_vid_vs      ),
        .I_video_in_user    ( 1'b0          ),
        .I_video_in_valid   ( 1'b0          ),
        .I_video_in_last    ( 1'b0          ),
        .O_video_in_ready   (               ),
        .I_video_in_data    ( S_vid_data    ),
        .I_audio_valid      ( 1'b0          ),
        .I_audio_left_data  ( 24'd0         ),
        .I_audio_right_data ( 24'd0         ),
        .I_i2s_BCLK         ( 1'b0          ),
        .I_i2s_LRCK         ( 1'b0          ),
        .I_i2s_DOUT         ( 1'b0          ),
        .O_ddc_scl          (               ),
        .IO_ddc_sda         (               ),
        .O_hdmi_clk_p       (               ),
        .O_hdmi_tx_p        (               ),
        .O_tmds_ch0_p       ( O_tmds_ch0_p  ),
        .O_tmds_ch1_p       ( O_tmds_ch1_p  ),
        .O_tmds_ch2_p       ( O_tmds_ch2_p  ),
        .O_tmds_clk_p       ( O_tmds_clk_p  )
    );

    // ============================================================ UART 状态上报（自研，精简版）
    // DDR ready 同步到 100M 域
    reg [1:0] S_ddr_rdy_s;
    always @(posedge S_clk_100m) begin
        if (!S_rst_n_100m) S_ddr_rdy_s <= 2'b00;
        else               S_ddr_rdy_s <= {S_ddr_rdy_s[0], S_ddr_rdy};
    end

    // SW1~SW4 同步到 100M 域（供串口上报）
    reg [2:0] S_sw1_sync_100m;
    reg [2:0] S_sw2_sync_100m;
    reg [2:0] S_sw4_sync_100m;
    reg [2:0] S_sw3_sync_100m;
    reg [2:0] S_cv_on_sync_100m;
    reg [7:0] S_cv_bin_thr_s1, S_cv_bin_thr_s2;
    always @(posedge S_clk_100m) begin
        if (!S_rst_n_100m) begin
            S_sw1_sync_100m <= 3'd0;
            S_sw2_sync_100m <= 3'd0;
            S_sw4_sync_100m <= 3'd0;
            S_sw3_sync_100m <= 3'd0;
            S_cv_on_sync_100m <= 3'd0;
            S_cv_bin_thr_s1 <= 8'd0;  S_cv_bin_thr_s2 <= 8'd0;
        end else begin
            S_sw1_sync_100m <= {S_sw1_sync_100m[1:0], I_sw1};
            S_sw2_sync_100m <= {S_sw2_sync_100m[1:0], I_sw2};
            S_sw4_sync_100m <= {S_sw4_sync_100m[1:0], I_sw4};
            S_sw3_sync_100m <= {S_sw3_sync_100m[1:0], I_sw3};
            S_cv_on_sync_100m <= {S_cv_on_sync_100m[1:0], S_cv_eff};
            S_cv_bin_thr_s1  <= S_cv_bin_thr;
            S_cv_bin_thr_s2  <= S_cv_bin_thr_s1;
        end
    end

    // B7: H1 切换给 MCU —— status_report 删除，O_uart_tx 由 MCU uart0_tx 驱动
    wire S_mcu_uart0_tx;   // 前向声明（ps_wrapper 输出）
    assign O_uart_tx = S_mcu_uart0_tx;

    // ============================================================ LED 状态指示
    reg [23:0] S_hb_cnt;    // 100MHz 域心跳（约 0.17s 翻转）
    always @(posedge S_clk_100m) begin
        if (!S_rst_n_100m) S_hb_cnt <= 24'd0;
        else               S_hb_cnt <= S_hb_cnt + 1'b1;
    end

    // LED1=PLL 锁定  LED2=100M 心跳  LED3=摄像头配置完成  LED4=DDR 校准完成
    assign O_led = { S_ddr_rdy_s[1], S_cam_cfg_done, S_hb_cnt[23], S_pll_lock };

    // ============================================================ MCU 子系统（B6：状态走 AHB，窗口 0x80000000）
    // fabric APB 窗口基址文档里找不到；fabric AHB 窗口 = 0x80000000（AHBDemo 验证）。
    // 故状态从口改走 AHB：MCU AHB master → ahb_status_slave；APB master 内部悬空（ps_wrapper 默认返回）。
    //   - core_clk ← pll_mcu 300MHz；timer_clk ← u_pll C0 100MHz
    //   - ahb_clk ← MCU 输出（~150MHz）→ 喂回 ahb_status_slave 作时钟
    //   - uart0_tx → H1（B7 切换：MCU 接管串口，status_report 已删）
    wire        S_clk_300m;        // pll_mcu -> MCU core_clk
    wire        S_pll_mcu_lock;
    pll_mcu u_pll_mcu (
        .refclk   ( I_sys_clk      ),   // 50MHz 板钟
        .reset    ( 1'b0           ),   // 与 u_pll 一致：上电复位由芯片内建
        .clk0_out ( S_clk_300m     ),
        .lock     ( S_pll_mcu_lock )
    );

    // MCU 核复位（高有效；两 PLL 都锁定后释放）
    wire S_mcu_core_reset = ~(S_pll_lock & S_pll_mcu_lock);

    // ---- AHB 互连 ----
    wire [1:0]  S_htrans;
    wire        S_hwrite;
    wire [30:0] S_haddr;
    wire [2:0]  S_hsize, S_hburst;
    wire [3:0]  S_hprot;
    wire        S_hmastlock;
    wire [31:0] S_hwdata, S_hrdata;
    wire [1:0]  S_hresp;
    wire        S_hready;
    wire [31:0] S_mcu_heartbeat, S_mcu_scratch, S_mcu_frame_cnt;

    // ahb_clk 域复位（MCU 起来后 ahb_clk 才稳，reset_ctrl 在 ahb_clk 上同步释放）
    wire S_rst_n_ahb;
    reset_ctrl u_rst_ahb (.clk(S_ahb_clk), .pll_lock(S_pll_lock & S_pll_mcu_lock), .rst_n(S_rst_n_ahb));

    ahb_status_slave u_ahb_status (
        .I_hclk        ( S_ahb_clk         ),
        .I_hresetn     ( S_rst_n_ahb       ),
        .I_htrans      ( S_htrans          ),
        .I_hwrite      ( S_hwrite          ),
        .I_haddr       ( S_haddr           ),
        .I_hsize       ( S_hsize           ),
        .I_hburst      ( S_hburst          ),
        .I_hprot       ( S_hprot           ),
        .I_hmastlock   ( S_hmastlock       ),
        .I_hwdata      ( S_hwdata          ),
        .O_hrdata      ( S_hrdata          ),
        .O_hreadyout   ( S_hready          ),
        .O_hresp       ( S_hresp           ),
        // 状态输入（pixel/100M 域原信号；slave 内部 2FF 同步到 ahb_clk）
        .I_cam_id      ( S_cam_sensor_id    ),
        .I_cam_id_ok   ( S_cam_sensor_id_ok ),
        .I_cam_i2c_err ( S_cam_i2c_error    ),
        .I_cam_cfg_done( S_cam_cfg_done     ),
        .I_ddr_rdy     ( S_ddr_rdy_s[1]     ),
        .I_sw1         ( S_sw1_sync_100m[2] ),
        .I_sw2         ( S_sw2_sync_100m[2] ),
        .I_sw4         ( S_sw4_sync_100m[2] ),
        .I_sw3         ( S_sw3_sync_100m[2] ),
        .I_cv_on       ( S_cv_on_sync_100m[2]),
        .I_blob_cnt    ( 6'd0              ),   // CCL 转 MCU，无硬件检测数
        .I_bin_thr     ( S_cv_bin_thr_s2    ),
        .I_run_cnt     ( S_cv_run_cnt       ),
        .I_run_overflow( S_cv_run_overflow ),
        .I_min_y       ( S_cv_min_y         ),
        .I_max_y       ( S_cv_max_y         ),
        .I_vsync       ( S_hdmi_vsync       ),
        .I_key1_long   ( S_key1_long        ),
        .I_key2_long   ( r_key2_long        ),
        .I_skip_roi_cnt( S_skip_roi_cnt     ),
        .I_skip_len_cnt( S_skip_len_cnt     ),
        // 钢珠前端参数（C 固件唯一定义）
        .O_ball_en       ( S_ball_en         ),
        .O_ball_bg_thr   ( S_ball_bg_thr     ),
        .O_ball_min_run  ( S_ball_min_run    ),
        .O_ball_roi_y1   ( S_ball_roi_y1     ),
        .O_ball_max_run_len ( S_ball_max_run_len ),
        .O_ball_capture  ( S_ball_capture    ),
        .I_ball_bg_ready ( S_ball_bg_ready   ),
        .I_ball_capturing( S_ball_capturing  ),
        // run_mem 间接读口（slave 发地址 → cv_top B 口出数据）
        .O_run_rd_addr ( S_run_rd_addr     ),
        .I_run_rd_data ( S_run_rd_data     ),
        // overlay + count（MCU 写 → cv_top 叠加读）
        .O_overlay     ( S_overlay          ),
        .O_count       ( S_count            ),
        .O_count_bcd   ( S_count_bcd        ),
        .O_ball_now    ( S_ball_now         ),
        .O_seg_dash    ( S_seg_dash         ),
        .O_gate_x      ( S_gate_x           ),
        .O_gate_y0     ( S_gate_y0          ),
        .O_gate_y1     ( S_gate_y1          ),
        .O_cam_ae      ( S_cam_ae_ahb       ),
        .O_cam_ag      ( S_cam_ag_ahb       ),
        .O_buzz_toggle ( S_buzz_toggle_ahb  ),
        .O_buzz_cfg    ( S_buzz_cfg_ahb     ),
        .O_heartbeat   ( S_mcu_heartbeat    ),
        .O_scratch     ( S_mcu_scratch      ),
        .O_frame_cnt   ( S_mcu_frame_cnt    )
    );

    // ---- MCU（ps_wrapper，AHB master 暴露）----
    // S_mcu_uart0_tx 已在 B7 assign 段前向声明
    wire        S_mcu_core_sysrst;    // MCU 主动复位，暂悬空
    ps_wrapper u_ps (
        .I_core_clk   ( S_clk_300m        ),
        .I_timer_clk  ( S_clk_100m        ),
        .I_rst        ( S_mcu_core_reset  ),
        .O_core_sysrst( S_mcu_core_sysrst  ),
        .O_ahb_clk    ( S_ahb_clk        ),
        .O_htrans     ( S_htrans          ),
        .O_hwrite     ( S_hwrite          ),
        .O_haddr      ( S_haddr           ),
        .O_hsize      ( S_hsize           ),
        .O_hburst     ( S_hburst          ),
        .O_hprot      ( S_hprot           ),
        .O_hmastlock  ( S_hmastlock       ),
        .O_hwdata     ( S_hwdata          ),
        .I_hrdata     ( S_hrdata          ),
        .I_hresp      ( S_hresp           ),
        .I_hready     ( S_hready          ),
        .O_uart0_tx   ( S_mcu_uart0_tx    ),
        .I_uart0_rx   ( I_uart_rx        )
    );

    // ---- 8 位数码管：5 位十进制 BCD 计数（右对齐，左 3 位灭）----
    // SW6 必须拨到数码管一侧；数码管与双色 LED 复用 16 根引脚。
    seg_count_display u_seg_count (
        .I_clk   ( I_sys_clk       ),
        .I_rst_n ( S_rst_n_50m     ),
        .I_bcd   ( S_count_bcd     ),
        .I_dash  ( S_seg_dash      ),
        .O_seg   ( O_seg           ),
        .O_sel   ( O_sel           )
    );

    // ---- 蜂鸣器：识别态短鸣，静态测试态播放测试曲 ----
    // 像素域 -> 50MHz 同步
    reg [1:0] S_song_play_50m_a;
    reg       S_song_play_50m;
    reg [1:0] S_static_50m_a;
    reg       S_static_50m;
    always @(posedge I_sys_clk) begin
        S_song_play_50m_a <= {S_song_play_50m_a[0], S_song_play};
        S_song_play_50m   <= S_song_play_50m_a[1];
        S_static_50m_a    <= {S_static_50m_a[0], S_debug_static};
        S_static_50m      <= S_static_50m_a[1];
    end

    wire S_buzz_beep;
    wire S_buzz_song;
    wire S_beep_en_50m = ~S_static_50m;   // 静态测试态强制蜂鸣短鸣静音，避免切回时残响
    buzzer_beep u_buzzer_beep (
        .I_clk        ( I_sys_clk          ),
        .I_rst_n      ( S_rst_n_50m        ),
        .I_en         ( S_beep_en_50m      ),
        .I_trig_toggle( S_buzz_toggle_ahb  ),
        .I_half_clks  ( S_buzz_cfg_ahb[31:16] ),
        .I_beep_ms    ( S_buzz_cfg_ahb[15:0]  ),
        .O_buzzer     ( S_buzz_beep        )
    );

    buzzer_song u_buzzer_song (
        .I_clk   ( I_sys_clk       ),
        .I_rst_n ( S_rst_n_50m     ),
        .I_play  ( S_song_play_50m ),
        .O_buzzer( S_buzz_song     )
    );

    assign O_buzzer = S_static_50m ? S_buzz_song : S_buzz_beep;

endmodule
