// eth_top.v — camera_eth_720p 顶层
//
//   SC520CS RAW10 (MIPI 2lane)
//     → cam_raw10_rx (D-PHY → CSI-2 → RAW10 → 40bit FIFO → 字节流)
//     → vid_udp_src  (800 包 × 1440B / 帧)
//     → eth_udp_tx   (Ethernet + IPv4 + UDP + CRC32)
//     → rgmii_tx_phy (HD_ODDR)
//
//   同时保留 RGMII RX（ARP 解析 / 状态统计）与 UART 每秒状态行。
//
// 时钟：
//   C0 = 125 MHz  (REFCLK_DIV=2, FBCLK_DIV=5, DIV=12, VCO=1500)
//   C1 = 23.81 MHz (DIV=63) → 摄像头 XCLK + I2C
//   RX_CLK = PHY 提供 125 MHz
//
// LED：
//   LED1 D10 = PLL lock
//   LED2 E10 = 摄像头 I2C 配置完成
//   LED3 C6  = 摄像头帧活动（收到帧就闪）
//   LED4 D6  = 50MHz 心跳
//
`timescale 1ns/1ps

module eth_top (
    input  wire        I_sys_clk,        // C4 50MHz
    output wire [3:0]  O_led,            // D10/E10/C6/D6
    output wire        O_uart_tx,        // H1

    // RGMII TX
    output wire        O_rgmii_txc,      // U9
    output wire        O_rgmii_tx_ctl,   // R10
    output wire [3:0]  O_rgmii_txd,      // R11/P11/T10/R12
    // RGMII RX
    input  wire        I_rgmii_rxc,      // V3
    input  wire        I_rgmii_rx_ctl,   // N8
    input  wire [3:0]  I_rgmii_rxd,      // N9/T7/T8/T9
    // 管理
    output wire        O_rgmii_mdc,      // V9
    inout  wire        IO_rgmii_mdio,    // U10
    output wire        O_phy_rst_n,      // V8

    // 摄像头控制
    output wire        O_cam_xclk,       // L3
    output wire        O_cam_pwdnb,      // L2
    output wire        O_cam_scl,        // K3
    inout  wire        IO_cam_sda,       // J3
    // MIPI 硬核 pad
    inout  wire        IO_rx_clk_pad_p,  // V16
    inout  wire        IO_rx_clk_pad_n,  // U16
    inout  wire [3:0]  IO_rx_data_pad_p, // V14/V15/V17/U18
    inout  wire [3:0]  IO_rx_data_pad_n  // U14/U15/U17/V18
);

    // ==================================================================
    // 上电复位
    // ==================================================================
    reg [19:0] por_cnt;
    reg        sys_rst_n;
    initial begin
        por_cnt   = 20'd0;
        sys_rst_n = 1'b0;
    end
    always @(posedge I_sys_clk) begin
        if (por_cnt < 20'hF_FFFF) begin
            por_cnt   <= por_cnt + 1'b1;
            sys_rst_n <= 1'b0;
        end else begin
            sys_rst_n <= 1'b1;
        end
    end

    // ==================================================================
    // PLL
    // ==================================================================
    wire clk_125;
    wire clk_24m;
    wire pll_lock;

    PLL u_pll (
        .refclk   ( I_sys_clk  ),
        .clk0_out ( clk_125    ),
        .clk1_out ( clk_24m    ),
        .clk4_out (            ),
        .clk5_out (            ),
        .lock     ( pll_lock   ),
        .reset    ( ~sys_rst_n )
    );

    wire rst_125_n = sys_rst_n & pll_lock;
    wire rst_24m_n = sys_rst_n & pll_lock;

    // ==================================================================
    // PHY 硬复位
    // ==================================================================
    wire phy_rst_done;
    phy_rst #(
        .RESET_TIME_MS (2),
        .POST_RST_MS   (5),
        .CLK_FREQ_HZ   (50_000_000)
    ) u_phy_rst (
        .clk       ( I_sys_clk   ),
        .rst_n     ( sys_rst_n   ),
        .phy_rst_n ( O_phy_rst_n ),
        .rst_done  ( phy_rst_done)
    );

    // ==================================================================
    // 摄像头：MIPI → RAW10 字节流
    // ==================================================================
    wire [7:0]  cam_byte;
    wire        cam_byte_v;
    wire        cam_byte_rd;
    wire        cam_fs;
    wire [10:0] cam_avail;
    wire [15:0] cam_frame_cnt;
    wire        cam_cfg_done, cam_sensor_ok;
    wire [15:0] cam_sensor_id;
    wire        cam_ovf, cam_lane_err;

    cam_raw10_rx u_cam (
        .I_clk_24m       ( clk_24m        ),
        .I_rst_n_24m     ( rst_24m_n      ),
        .I_clk_sys       ( clk_125        ),
        .I_rst_n_sys     ( rst_125_n      ),
        .O_cam_xclk      ( O_cam_xclk     ),
        .O_cam_pwdnb     ( O_cam_pwdnb    ),
        .O_cam_scl       ( O_cam_scl      ),
        .IO_cam_sda      ( IO_cam_sda     ),
        .IO_rx_clk_pad_p ( IO_rx_clk_pad_p),
        .IO_rx_clk_pad_n ( IO_rx_clk_pad_n),
        .IO_rx_data_pad_p( IO_rx_data_pad_p),
        .IO_rx_data_pad_n( IO_rx_data_pad_n),
        .O_byte          ( cam_byte       ),
        .O_byte_v        ( cam_byte_v     ),
        .I_byte_rd       ( cam_byte_rd    ),
        .O_frame_start   ( cam_fs         ),
        .O_avail_words   ( cam_avail      ),
        .O_frame_cnt     ( cam_frame_cnt  ),
        .O_cfg_done      ( cam_cfg_done   ),
        .O_sensor_ok     ( cam_sensor_ok  ),
        .O_sensor_id     ( cam_sensor_id  ),
        .O_ovf           ( cam_ovf        ),
        .O_lane_err      ( cam_lane_err   )
    );

    // ==================================================================
    // UDP 视频流
    // ==================================================================
    wire        vid_req, vid_busy, vid_done;
    wire [15:0] vid_frame_id, vid_pkt_idx, vid_pkt_total;
    wire [7:0]  txd_gmii;
    wire        tx_en;

    vid_udp_src #(
        .START_WORDS ( 11'd292      ),   // ≥1460 字节
        .PKT_TOTAL   ( 16'd800      )
    ) u_src (
        .clk         ( clk_125      ),
        .rst_n       ( rst_125_n    ),
        .avail_words ( cam_avail    ),
        .frame_start ( cam_fs       ),
        .req         ( vid_req      ),
        .frame_id    ( vid_frame_id ),
        .pkt_idx     ( vid_pkt_idx  ),
        .pkt_total   ( vid_pkt_total),
        .done        ( vid_done     )
    );

    eth_udp_tx #(
        .DATA_BYTES ( 16'd1440  ),
        .IP_TOTAL   ( 16'd1476  ),
        .UDP_LEN    ( 16'd1456  ),
        .SRC_PORT   ( 16'd4660  ),
        .DST_PORT   ( 16'd4660  )
    ) u_udp (
        .clk        ( clk_125      ),
        .rst_n      ( rst_125_n    ),
        .req        ( vid_req      ),
        .dst_mac    ( 48'hFF_FF_FF_FF_FF_FF ),
        .src_mac    ( 48'h02_00_00_00_00_01 ),
        .frame_id   ( vid_frame_id ),
        .pkt_idx    ( vid_pkt_idx  ),
        .pkt_total  ( vid_pkt_total),
        .pay_data   ( cam_byte     ),
        .pay_rd     ( cam_byte_rd  ),
        .busy       ( vid_busy     ),
        .done       ( vid_done     ),
        .gmii_tx_en ( tx_en        ),
        .gmii_txd   ( txd_gmii     )
    );

    rgmii_tx_phy u_rgmii_tx (
        .clk_125    ( clk_125      ),
        .clk_125_90 ( clk_125      ),
        .rst        ( ~rst_125_n   ),
        .gmii_txd   ( txd_gmii     ),
        .gmii_tx_en ( tx_en        ),
        .gmii_tx_er ( 1'b0         ),
        .rgmii_txc  ( O_rgmii_txc    ),
        .rgmii_tx_ctl( O_rgmii_tx_ctl),
        .rgmii_txd  ( O_rgmii_txd    )
    );

    // ==================================================================
    // RX（状态统计 + ARP 学习）
    // ==================================================================
    wire [7:0] rxd_gmii;
    wire       rx_dv, rx_er;

    rgmii_rx_phy u_rgmii_rx (
        .rgmii_rxc   ( I_rgmii_rxc   ),
        .rgmii_rx_ctl( I_rgmii_rx_ctl),
        .rgmii_rxd   ( I_rgmii_rxd   ),
        .gmii_rxd    ( rxd_gmii      ),
        .gmii_rx_dv  ( rx_dv         ),
        .gmii_rx_er  ( rx_er         )
    );

    wire        f_start, f_byte_v, f_end, f_err;
    wire [7:0]  f_data;
    wire [10:0] f_idx, f_len;

    eth_rx_mac u_rx_mac (
        .clk         ( I_rgmii_rxc ),
        .rst_n       ( rst_125_n    ),
        .gmii_rxd    ( rxd_gmii    ),
        .gmii_rx_dv  ( rx_dv       ),
        .gmii_rx_er  ( rx_er       ),
        .frame_start ( f_start     ),
        .frame_data  ( f_data      ),
        .frame_idx   ( f_idx       ),
        .frame_byte_v( f_byte_v    ),
        .frame_end   ( f_end       ),
        .frame_len   ( f_len       ),
        .frame_err   ( f_err       )
    );

    wire        arp_hit;
    wire [47:0] peer_mac;
    wire [31:0] peer_ip;
    wire [15:0] arp_cnt;
    wire [15:0] rx_frame_cnt;

    arp_rx #(
        .LOCAL_IP ( 32'hC0A801C8 )
    ) u_arp_rx (
        .clk         ( I_rgmii_rxc ),
        .rst_n       ( rst_125_n    ),
        .frame_start ( f_start     ),
        .frame_data  ( f_data      ),
        .frame_idx   ( f_idx       ),
        .frame_byte_v( f_byte_v    ),
        .frame_end   ( f_end       ),
        .frame_len   ( f_len       ),
        .frame_err   ( f_err       ),
        .arp_hit     ( arp_hit     ),
        .peer_mac    ( peer_mac    ),
        .peer_ip     ( peer_ip     ),
        .arp_cnt     ( arp_cnt     ),
        .rx_frame_cnt( rx_frame_cnt)
    );

    // ==================================================================
    // 状态跨到 50MHz 域（调试用 2FF 直采）
    // ==================================================================
    reg [15:0] camf_s1, camf_s2;
    reg [15:0] fid_s1,  fid_s2;
    reg [15:0] rxf_s1,  rxf_s2;
    reg [15:0] sid_s1,  sid_s2;
    reg [2:0]  cfg_s, ok_s, ovf_s;
    reg        rx_alive;

    always @(posedge I_sys_clk) begin
        camf_s1 <= cam_frame_cnt;   camf_s2 <= camf_s1;
        fid_s1  <= vid_frame_id;    fid_s2  <= fid_s1;
        rxf_s1  <= rx_frame_cnt;    rxf_s2  <= rxf_s1;
        sid_s1  <= cam_sensor_id;   sid_s2  <= sid_s1;
        cfg_s   <= {cfg_s[1:0],   cam_cfg_done};
        ok_s    <= {ok_s[1:0],    cam_sensor_ok};
        ovf_s   <= {ovf_s[1:0],   cam_ovf};
        if (rxf_s2 != 16'd0) rx_alive <= 1'b1;
    end

    // ==================================================================
    // UART 状态
    // ==================================================================
    wire        u_valid;
    wire [7:0] u_data;
    wire       u_ready;

    dbg_uart_report #(
        .CLK_FREQ ( 50_000_000 )
    ) u_report (
        .clk        ( I_sys_clk       ),
        .rst_n      ( sys_rst_n       ),
        .rx_frames  ( rxf_s2          ),
        .tx_frames  ( fid_s2          ),
        .cam_frames ( camf_s2         ),
        .sensor_id  ( sid_s2          ),
        .status     ( { rx_alive, ovf_s[2], ok_s[2], cfg_s[2] } ),
        .uart_valid ( u_valid         ),
        .uart_data  ( u_data          ),
        .uart_ready ( u_ready         )
    );

    uart_tx #(
        .CLK_FREQ ( 50_000_000 ),
        .BAUD     ( 115200     )
    ) u_uart (
        .clk      ( I_sys_clk ),
        .rst_n    ( sys_rst_n ),
        .I_valid  ( u_valid   ),
        .I_data   ( u_data    ),
        .O_tx     ( O_uart_tx ),
        .O_ready  ( u_ready   )
    );

    // ==================================================================
    // LED
    // ==================================================================
    reg [25:0] hb_cnt;
    always @(posedge I_sys_clk) hb_cnt <= hb_cnt + 1'b1;

    assign O_led[0] = pll_lock;
    assign O_led[1] = cfg_s[2];
    assign O_led[2] = camf_s2[4];      // 60fps → 每 16 帧翻转 ≈ 1.9Hz 闪
    assign O_led[3] = hb_cnt[25];

    // ==================================================================
    // 不用
    // ==================================================================
    assign O_rgmii_mdc   = 1'b0;
    assign IO_rgmii_mdio = 1'bz;

endmodule
