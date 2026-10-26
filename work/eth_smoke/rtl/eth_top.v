// eth_top.v — 以太网 TX + RX 联调（eth_smoke）
//
// TX：每 200ms 发一个 128 字节 ARP 请求（广播），验证 RGMII TX 通路。
// RX：解析 PC 回的 ARP reply，学到对端 MAC/IP，并通过 USB-UART 每秒打印：
//
//        N=XXXX A=XXXX M=XXXXXXXXXXXX        (COM4, 115200 8N1)
//          N = 收到的帧总数   A = ARP reply 命中次数   M = 学到的 MAC
//
// LED：
//   LED1 D10 = PLL lock
//   LED2 E10 = frame_sent（TX 发过帧）
//   LED3 C6  = RX alive（收到过至少一帧）
//   LED4 D6  = 50MHz 心跳
//
`timescale 1ns/1ps

module eth_top (
    input  wire        I_sys_clk,        // C4  50MHz

    output wire [3:0]  O_led,            // D10/E10/C6/D6
    output wire        O_uart_tx,        // H1  115200 8N1

    // RGMII TX（FPGA → PHY）
    output wire        O_rgmii_txc,      // U9  GTX_CLK
    output wire        O_rgmii_tx_ctl,   // R10 TX_CTL
    output wire [3:0]  O_rgmii_txd,      // R11/P11/T10/R12

    // RGMII RX（PHY → FPGA）
    input  wire        I_rgmii_rxc,      // V3  RX_CLK
    input  wire        I_rgmii_rx_ctl,   // N8  RX_DV
    input  wire [3:0]  I_rgmii_rxd,      // N9/T7/T8/T9

    // 管理 / 控制
    output wire        O_rgmii_mdc,      // V9
    inout  wire        IO_rgmii_mdio,    // U10
    output wire        O_phy_rst_n       // V8
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
    // PLL：50MHz → C0 125MHz(0°)
    //   C0 = (FIN/REFCLK_DIV) × FBCLK_DIV = 50/2 × 5 = 125MHz
    //   VCO = 125 × CLKC0_DIV(12) = 1500MHz
    // ==================================================================
    wire clk_125;
    wire pll_lock;

    PLL u_pll (
        .refclk   ( I_sys_clk  ),
        .clk0_out ( clk_125    ),
        .clk1_out (            ),
        .clk4_out (            ),
        .clk5_out (            ),
        .lock     ( pll_lock   ),
        .reset    ( ~sys_rst_n )
    );

    wire rst_125_n = sys_rst_n & pll_lock;

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
    // TX：ARP 请求帧
    // ==================================================================
    wire [7:0] txd_gmii;
    wire       tx_en;
    wire       tx_er;
    wire       tx_active;
    wire       frame_sent;

    arp_frame_tx #(
        .SEND_INTERVAL_CYCLES ( 32'd25_000_000 )   // 200 ms
    ) u_frame (
        .clk       ( clk_125    ),
        .rst_n     ( rst_125_n  ),
        .gmii_txd  ( txd_gmii   ),
        .gmii_tx_en( tx_en      ),
        .gmii_tx_er( tx_er      ),
        .tx_active ( tx_active  ),
        .frame_sent( frame_sent )
    );

    rgmii_tx_phy u_rgmii_tx (
        .clk_125    ( clk_125      ),
        .clk_125_90 ( clk_125      ),   // GTX_CLK 用 0° + 引脚 OUTDEL
        .rst        ( ~rst_125_n   ),
        .gmii_txd   ( txd_gmii     ),
        .gmii_tx_en ( tx_en        ),
        .gmii_tx_er ( tx_er        ),
        .rgmii_txc  ( O_rgmii_txc    ),
        .rgmii_tx_ctl( O_rgmii_tx_ctl),
        .rgmii_txd  ( O_rgmii_txd    )
    );

    // ==================================================================
    // RX：RGMII → GMII → 字节流 → ARP 解析
    //   全部同步于 PHY 送来的 RX_CLK
    // ==================================================================
    wire       rst_rx_n = sys_rst_n & pll_lock;

    wire [7:0] rxd_gmii;
    wire       rx_dv;
    wire       rx_er;

    rgmii_rx_phy u_rgmii_rx (
        .rgmii_rxc   ( I_rgmii_rxc   ),
        .rgmii_rx_ctl( I_rgmii_rx_ctl),
        .rgmii_rxd   ( I_rgmii_rxd   ),
        .gmii_rxd    ( rxd_gmii      ),
        .gmii_rx_dv  ( rx_dv         ),
        .gmii_rx_er  ( rx_er         )
    );

    wire        f_start;
    wire [7:0]  f_data;
    wire [10:0] f_idx;
    wire        f_byte_v;
    wire        f_end;
    wire [10:0] f_len;
    wire        f_err;

    eth_rx_mac u_rx_mac (
        .clk         ( I_rgmii_rxc ),
        .rst_n       ( rst_rx_n    ),
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
        .LOCAL_IP ( 32'hC0A801C8 )      // 192.168.1.200
    ) u_arp_rx (
        .clk         ( I_rgmii_rxc ),
        .rst_n       ( rst_rx_n    ),
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
    // RX 域 → 50MHz 域（MAC 用 toggle 握手；计数器仅调试用 2FF 同步）
    // ==================================================================
    reg mac_tog;                       // RX 域
    always @(posedge I_rgmii_rxc or negedge rst_rx_n) begin
        if (!rst_rx_n) mac_tog <= 1'b0;
        else if (arp_hit) mac_tog <= ~mac_tog;
    end

    reg [2:0] mac_tog_s;
    always @(posedge I_sys_clk) mac_tog_s <= { mac_tog_s[1:0], mac_tog };
    wire mac_upd = mac_tog_s[2] ^ mac_tog_s[1];

    reg [47:0] mac_50;
    always @(posedge I_sys_clk) begin
        if (mac_upd) mac_50 <= peer_mac;
    end

    reg [15:0] frm_s1, frm_s2, arp_s1, arp_s2;
    always @(posedge I_sys_clk) begin
        frm_s1 <= rx_frame_cnt;
        frm_s2 <= frm_s1;
        arp_s1 <= arp_cnt;
        arp_s2 <= arp_s1;
    end

    reg rx_alive;
    always @(posedge I_sys_clk) begin
        if (frm_s2 != 16'd0) rx_alive <= 1'b1;
    end

    // ==================================================================
    // UART 状态打印
    // ==================================================================
    wire       u_valid;
    wire [7:0] u_data;
    wire       u_ready;

    dbg_uart_report #(
        .CLK_FREQ ( 50_000_000 )
    ) u_report (
        .clk        ( I_sys_clk ),
        .rst_n      ( sys_rst_n ),
        .frames     ( frm_s2    ),
        .arps       ( arp_s2    ),
        .mac        ( mac_50    ),
        .uart_valid ( u_valid   ),
        .uart_data  ( u_data    ),
        .uart_ready ( u_ready   )
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
    assign O_led[1] = frame_sent;
    assign O_led[2] = rx_alive;
    assign O_led[3] = hb_cnt[25];

    // ==================================================================
    // 不用
    // ==================================================================
    assign O_rgmii_mdc   = 1'b0;
    assign IO_rgmii_mdio = 1'bz;

endmodule
