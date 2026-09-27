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
    output wire        O_uart_tx,    // H1 = FPGA uart_tx（依据官方例程 uart_test.adc；J1 是 uart_rx，本阶段未用）

    // ---- M4：画面切换开关（板手册 2-22 乒乓开关：SW4 = D11，拨上=1、拨下=0）----
    input  wire        I_sw4,        // 1=摄像头画面，0=彩条测试图案

    // ---- M5：DDR2 帧缓存（器件 DDR PHY 专用脚）----
    // 引脚/位置约束由 ip/ddr2 自带的 ddr2.adc/.sdc 提供（经 ddr2.xml 的 fileSet 自动引入），
    // 端口名必须与 IP 自带约束里的命名完全一致，勿改名；也不写进我们的 pin.adc。
    output wire [12:0] ddr_addr,     // 地址 A0~A12
    output wire [1:0]  ddr_ba,       // bank 地址
    output wire [0:0]  ddr_cke,      // 时钟使能（IP 约束写作 ddr_cke[0]，故声明为 [0:0]）
    output wire [0:0]  ddr_odt,      // ODT（同上）
    output wire [0:0]  ddr_cs_n,     // 片选（同上）
    output wire        ddr_ras_n,
    output wire        ddr_cas_n,
    output wire        ddr_we_n,
    output wire [0:0]  ddr_ck_p,     // DDR 差分时钟
    output wire [0:0]  ddr_ck_n,
    inout  wire [1:0]  ddr_dm,       // 数据掩码
    inout  wire [15:0] ddr_dq,       // 数据（16bit）
    inout  wire [1:0]  ddr_dqs_p,    // 数据选通
    inout  wire [1:0]  ddr_dqs_n
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
    wire S_rst_n_ddr;    // M5-②：DDR 用户域复位（reset_ctrl 实例在 DDR 段：
                         // 锁定条件 = PLL lock & DDR 校准完成，见下方）

    reset_ctrl u_rst_100m (.clk(S_clk_100m),  .pll_lock(S_pll_lock), .rst_n(S_rst_n_100m));
    reset_ctrl u_rst_pix  (.clk(S_pixel_clk), .pll_lock(S_pll_lock), .rst_n(S_rst_n_pix));

    // ------------------------------------------------- M5：DDR2 控制器（复用 IP，空载校准版①）
    // 接法照厂商三个 lab：ref_clk / apb_pclk = 板上 50MHz 晶振（I_sys_clk，未经我们的 PLL）；
    // 用户侧逻辑时钟 = IP 输出的 dhi_clk（S_ddr_clk），M5-② 的读写引擎将跑在该域。
    // 本阶段只例化 IP 并观察校准完成状态，不发起任何 DDR 访问。
    // 顶层实例名固定为 u_ph1p35_324_ddr_wrapper：timing.sdc 的 DDR 时钟组按该路径引用
    // （写法与厂商 lab 完全一致），改名必须同步改 sdc。
    wire       S_ddr_clk;        // IP 输出用户时钟（dhi_clk）
    wire       S_ddr_rdy;        // ddrphy_rdy：校准完成
    wire       S_ddr_ardy;       // O_mc_app_rdy：应用口就绪（空闲应为 1）
    wire       S_ddr_wrdy;       // O_mc_app_wdf_rdy：写数据口就绪（空闲应为 1）
    reg  [1:0] S_ddr_rdy_s;      // 下面三个 2 级同步进 100MHz 域（仅串口上报用）
    reg  [1:0] S_ddr_ardy_s;
    reg  [1:0] S_ddr_wrdy_s;

    always @(posedge S_clk_100m) begin
        if (!S_rst_n_100m) begin
            S_ddr_rdy_s  <= 2'b00;
            S_ddr_ardy_s <= 2'b00;
            S_ddr_wrdy_s <= 2'b00;
        end else begin
            S_ddr_rdy_s  <= { S_ddr_rdy_s[0],  S_ddr_rdy  };
            S_ddr_ardy_s <= { S_ddr_ardy_s[0], S_ddr_ardy };
            S_ddr_wrdy_s <= { S_ddr_wrdy_s[0], S_ddr_wrdy };
        end
    end

    // M5-②：应用口信号（由自研 ddr_arb 驱动/接收）
    wire [24:0]  S_mc_addr;
    wire [2:0]   S_mc_cmd;
    wire         S_mc_en;
    wire [127:0] S_mc_wdf_data;
    wire         S_mc_wdf_end;
    wire [15:0]  S_mc_wdf_mask;
    wire         S_mc_wdf_wren;
    wire [127:0] S_mc_rd_data;
    wire         S_mc_rd_valid;

    ph1p35_324_ddr_wrapper u_ph1p35_324_ddr_wrapper (
        .I_sys_clk             ( I_sys_clk    ),   // 板上 50MHz（与厂商接法一致）
        .I_sys_rst_n           ( S_rst_n_100m ),   // 自研同步复位（PLL 锁定后释放）
        .O_ddr_clk             ( S_ddr_clk    ),
        .O_init_calib_complete ( S_ddr_rdy    ),

        // 应用口：M5-② 起接自研仲裁器（ddr_arb；读=显示预取优先，写=帧排空）
        .I_mc_app_addr         ( S_mc_addr     ),
        .I_mc_app_cmd          ( S_mc_cmd      ),
        .I_mc_app_en           ( S_mc_en       ),
        .I_mc_app_wdf_data     ( S_mc_wdf_data ),
        .I_mc_app_wdf_end      ( S_mc_wdf_end  ),
        .I_mc_app_wdf_mask     ( S_mc_wdf_mask ),
        .I_mc_app_wdf_wren     ( S_mc_wdf_wren ),
        .O_mc_app_rd_data      ( S_mc_rd_data  ),
        .O_mc_app_rd_data_end  (               ),
        .O_mc_app_rd_data_valid( S_mc_rd_valid ),
        .O_mc_app_rdy          ( S_ddr_ardy    ),
        .O_mc_app_wdf_rdy      ( S_ddr_wrdy    ),

        .ddr_addr              ( ddr_addr     ),
        .ddr_ba                ( ddr_ba       ),
        .ddr_cke               ( ddr_cke      ),
        .ddr_odt               ( ddr_odt      ),
        .ddr_cs_n              ( ddr_cs_n     ),
        .ddr_ras_n             ( ddr_ras_n    ),
        .ddr_cas_n             ( ddr_cas_n    ),
        .ddr_we_n              ( ddr_we_n     ),
        .ddr_ck_p              ( ddr_ck_p     ),
        .ddr_ck_n              ( ddr_ck_n     ),
        .ddr_dm                ( ddr_dm       ),
        .ddr_dq                ( ddr_dq       ),
        .ddr_dqs_p             ( ddr_dqs_p    ),
        .ddr_dqs_n             ( ddr_dqs_n    )
    );

    // M5-②：DDR 用户域复位 —— PLL 锁定且 DDR 校准完成后释放
    reset_ctrl u_rst_ddr (.clk(S_ddr_clk), .pll_lock(S_pll_lock & S_ddr_rdy), .rst_n(S_rst_n_ddr));

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

    // ------------------------------------------------- M5-②：DDR2 帧缓存（自研读写引擎 + 仲裁）
    // 数据通路：MIPI 字节域 → fb_wr（打包 128bit 字/16 像素 → 行缓冲乒乓）→ ddr_arb
    //           → 复用 IP u_ph1p35_324_ddr_wrapper → DDR2；
    //           显示侧 fb_rd 逐行预取（显示第 y 行期间取第 y+1 行）→ 双 bank 行缓存
    //           → video_mux → hdmi_tx。
    // 三帧缓冲由 fb_ctrl 管理：fs/fe 核对通过的帧才标记 READY；显示 vsync 只取
    // 最新 READY（无撕裂、无滚动；无新帧时重复旧帧）。
    wire [23:0] S_cam_gray;
    wire        S_cam_de, S_cam_vs;

    wire [24:0] S_fb_wr_base, S_fb_rd_base;
    wire        S_fb_wr_start, S_fb_wr_done, S_fb_wr_bad;
    wire        S_fb_wr_req, S_fb_wr_gnt;
    wire [24:0] S_fb_wr_addr;
    wire [127:0]S_fb_wr_data;
    wire        S_fb_rd_valid;
    wire        S_fb_rd_req, S_fb_rd_gnt;
    wire [24:0] S_fb_rd_addr;
    wire [127:0]S_fb_rd_data;
    wire        S_fb_rd_dvalid;
    wire        S_fb_vsync_p, S_fb_undf, S_fb_arb_err, S_fb_flush;
    wire [15:0] S_ddr_wr_bcd, S_ddr_rd_bcd;
    wire [7:0]  S_ddr_ov, S_ddr_un, S_ddr_er;
    wire        S_fb_req_t, S_fb_ack_t;
    wire [23:0] S_vid_data;
    wire        S_vid_de, S_vid_vs, S_vid_sel;

    // ⚠ 以下字节域信号必须**先声明**再使用：本实例在文件中出现得早，而它们的声明
    //    原本在文件后半段。Verilog 的「先用后声明」会让工具按**隐式 1 位线网**处理
    //    （TD 报 HDL-7225 CRITICAL-WARNING），字节域信号（尤其 D-PHY 恢复时钟
    //    S_rx_byte_clk）的线网被拆坏 —— 这就是 M4 首轮上板 MIPI 全停（RX=0）的根因。
    wire        S_rx_byte_clk;     // o_fabric_div4_8_clk（1:8 模式 = 串行时钟/4 ≈ 103.5MHz）
    wire        S_rst_n_rx;        // 字节域复位（源：S_rx_rst_sync[1]，见文件后部）
    wire        S_fs;              // FS 短包（M5-②：fb_wr 帧开始）
    wire        S_fe;              // FE 短包（M5-②：fb_wr 帧结束）
    wire        S_pay_start;       // CSI-2 负载首拍
    wire        S_pay_end;         // CSI-2 负载末拍
    wire        S_px_valid;        // RAW10 像素组有效
    wire [39:0] S_px;              // RAW10 像素组（4×10bit）

    // ---- M5-②：写引擎（字节域入队 FIFO + 用户域打包/行缓冲/排空）----
    fb_wr u_fb_wr (
        .I_clk_b        ( S_rx_byte_clk ),
        .I_rst_n_b      ( S_rst_n_rx    ),
        .I_fs           ( S_fs          ),
        .I_fe           ( S_fe          ),
        .I_line_start   ( S_pay_start   ),
        .I_grp_valid    ( S_px_valid    ),
        .I_grp          ( S_px          ),
        .I_clk_d        ( S_ddr_clk     ),
        .I_rst_n_d      ( S_rst_n_ddr   ),
        .I_wr_base      ( S_fb_wr_base  ),
        .O_frame_start  ( S_fb_wr_start ),
        .O_frame_done   ( S_fb_wr_done  ),
        .O_frame_bad    ( S_fb_wr_bad   ),
        .O_wr_req       ( S_fb_wr_req   ),
        .O_wr_addr      ( S_fb_wr_addr  ),
        .O_wr_data      ( S_fb_wr_data  ),
        .I_wr_gnt       ( S_fb_wr_gnt   )
    );

    // ---- M5-②：显示读引擎（行预取 + 双 bank 行缓存 + 像素域读出）----
    fb_rd u_fb_rd (
        .clk_d          ( S_ddr_clk     ),
        .rst_n_d        ( S_rst_n_ddr   ),
        .I_rd_base      ( S_fb_rd_base  ),
        .I_rd_valid_f   ( S_fb_rd_valid ),
        .O_vsync_pulse  ( S_fb_vsync_p  ),
        .O_line_underflow( S_fb_undf    ),
        .O_rd_req       ( S_fb_rd_req   ),
        .O_rd_addr      ( S_fb_rd_addr  ),
        .I_rd_gnt       ( S_fb_rd_gnt   ),
        .I_rd_data      ( S_fb_rd_data  ),
        .I_rd_dvalid    ( S_fb_rd_dvalid),
        .I_rd_flush     ( S_fb_flush    ),
        .clk_p          ( S_pixel_clk   ),
        .rst_n_p        ( S_rst_n_pix   ),
        .I_vs           ( S_vs          ),
        .I_de           ( S_de          ),
        .I_x            ( S_x           ),
        .I_y            ( S_y           ),
        .O_data         ( S_cam_gray    ),
        .O_de           ( S_cam_de      ),
        .O_vs           ( S_cam_vs      )
    );

    // ---- M5-②：应用口仲裁（读优先；写=排空）----
    ddr_arb u_ddr_arb (
        .clk            ( S_ddr_clk     ),
        .rst_n          ( S_rst_n_ddr   ),
        .I_wr_req       ( S_fb_wr_req   ),
        .I_wr_addr      ( S_fb_wr_addr  ),
        .I_wr_data      ( S_fb_wr_data  ),
        .O_wr_gnt       ( S_fb_wr_gnt   ),
        .I_rd_req       ( S_fb_rd_req   ),
        .I_rd_addr      ( S_fb_rd_addr  ),
        .O_rd_gnt       ( S_fb_rd_gnt   ),
        .O_mc_addr      ( S_mc_addr     ),
        .O_mc_cmd       ( S_mc_cmd      ),
        .O_mc_en        ( S_mc_en       ),
        .O_mc_wdf_data  ( S_mc_wdf_data ),
        .O_mc_wdf_end   ( S_mc_wdf_end  ),
        .O_mc_wdf_mask  ( S_mc_wdf_mask ),
        .O_mc_wdf_wren  ( S_mc_wdf_wren ),
        .I_mc_rdy       ( S_ddr_ardy    ),
        .I_mc_wdf_rdy   ( S_ddr_wrdy    ),
        .I_mc_rd_data   ( S_mc_rd_data  ),
        .I_mc_rd_valid  ( S_mc_rd_valid ),
        .O_rd_data      ( S_fb_rd_data  ),
        .O_rd_dvalid    ( S_fb_rd_dvalid),
        .O_rd_flush     ( S_fb_flush    ),
        .O_err          ( S_fb_arb_err  )
    );

    // ---- M5-②：三缓冲管理 + 计数（WR/RD/OV/UN/ER → 串口）----
    fb_ctrl u_fb_ctrl (
        .clk            ( S_ddr_clk     ),
        .rst_n          ( S_rst_n_ddr   ),
        .I_frame_start  ( S_fb_wr_start ),
        .I_frame_done   ( S_fb_wr_done  ),
        .I_frame_bad    ( S_fb_wr_bad   ),
        .I_vsync_pulse  ( S_fb_vsync_p  ),
        .I_line_underflow( S_fb_undf    ),
        .I_arb_err      ( S_fb_arb_err  ),
        .O_wr_base      ( S_fb_wr_base  ),
        .O_rd_base      ( S_fb_rd_base  ),
        .O_rd_valid     ( S_fb_rd_valid ),
        .O_req_t        ( S_fb_req_t    ),
        .I_ack_t        ( S_fb_ack_t    ),
        .O_ack_t        ( S_fb_ack_t    ),
        .clk_s          ( S_clk_100m    ),
        .rst_n_s        ( S_rst_n_100m  ),
        .O_wr_cnt       ( S_ddr_wr_bcd  ),
        .O_rd_cnt       ( S_ddr_rd_bcd  ),
        .O_ov_cnt       ( S_ddr_ov      ),
        .O_un_cnt       ( S_ddr_un      ),
        .O_er_cnt       ( S_ddr_er      )
    );

    video_mux u_video_mux (
        .clk        ( S_pixel_clk ),
        .rst_n      ( S_rst_n_pix ),
        .I_sw4      ( I_sw4       ),       // D11：拨上(1)=摄像头画面
        .I_pat_data ( S_pat_data  ),
        .I_pat_de   ( S_pat_de    ),
        .I_pat_vs   ( S_pat_vs    ),
        .I_cam_data ( S_cam_gray  ),
        .I_cam_de   ( S_cam_de    ),
        .I_cam_vs   ( S_cam_vs    ),
        .O_data     ( S_vid_data  ),
        .O_de       ( S_vid_de    ),
        .O_vs       ( S_vid_vs    ),
        .O_sel      ( S_vid_sel   )
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
        .I_video_in_de      ( S_vid_de      ),
        .I_video_in_vs      ( S_vid_vs      ),
        .I_video_in_user    ( 1'b0          ),
        .I_video_in_valid   ( 1'b0          ),
        .I_video_in_last    ( 1'b0          ),
        .O_video_in_ready   (               ),
        .I_video_in_data    ( S_vid_data    ),

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
    // 注：S_rx_byte_clk / S_rst_n_rx / S_pay_start / S_pay_end / S_px_valid / S_px
    //     的声明已提前到文件前部「M4：摄像头灰度直通」段（必须在首次使用之前）。
    wire        S_hs_valid;
    wire [15:0] S_hs_data;
    wire [1:0]  S_lane_err;
    wire        S_di_valid;      // lane_deint 重排后的 CSI-2 字节流
    wire [15:0] S_di_data;
    wire        S_lp0_p, S_lp0_n;   // M4 诊断：D-PHY LP 接收状态（lane0）

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

        .O_lp_rx_lane0_p       ( S_lp0_p                     ),
        .O_lp_rx_lane0_n       ( S_lp0_n                     ),

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
    assign S_rst_n_rx = S_rx_rst_sync[1];   // 声明已提前，见文件前部注释

    // ---- M4 诊断（100MHz 域，字节域停摆时仍可观测）----
    // lpa：lane0 出现过非 LP-11 → 传感器确实在驱动总线（有 LP 活动）
    // rxa：字节域复位链是否已释放 → 字节时钟（D-PHY 恢复时钟）到底跑没跑过
    reg S_lp_act, S_rx_alive;
    always @(posedge S_clk_100m) begin
        if (!S_rst_n_100m) begin
            S_lp_act   <= 1'b0;
            S_rx_alive <= 1'b0;
        end else begin
            if (!(S_lp0_p & S_lp0_n)) S_lp_act   <= 1'b1;
            if (S_rst_n_rx)           S_rx_alive <= 1'b1;
        end
    end

    // ---- CSI-2 包解析 ----
    wire        S_ls, S_le;
    wire        S_pay_valid;
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
    wire        S_pkt_done;
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
    // M4：SW4 在 100MHz 域再同步一路（用于串口上报；视频侧 video_mux 内部另有独立同步）
    reg [2:0] S_sw4_sync;
    always @(posedge S_clk_100m) begin
        if (!S_rst_n_100m) S_sw4_sync <= 3'd0;
        else               S_sw4_sync <= {S_sw4_sync[1:0], I_sw4};
    end
    wire S_sw4_100m = S_sw4_sync[2];

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
        .D_sw4      ( S_sw4_100m   ),
        .D_lp0_p    ( S_lp0_p      ),
        .D_lp0_n    ( S_lp0_n      ),
        .D_lp_act   ( S_lp_act     ),
        .D_rx_alive ( S_rx_alive   ),
        .D_ddr_rdy  ( S_ddr_rdy_s[1]  ),
        .D_ddr_ardy ( S_ddr_ardy_s[1] ),
        .D_ddr_wrdy ( S_ddr_wrdy_s[1] ),
        .D_ddr_wr   ( S_ddr_wr_bcd    ),   // M5-②：写完成帧数（BCD）
        .D_ddr_rd   ( S_ddr_rd_bcd    ),   // M5-②：上屏帧数（BCD）
        .D_ddr_ov   ( S_ddr_ov        ),   // M5-②：写冲突丢帧
        .D_ddr_un   ( S_ddr_un        ),   // M5-②：行预取欠载
        .D_ddr_er   ( S_ddr_er        ),   // M5-②：帧异常计数
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
