// m1_top.v — RGMII TX 测试：发 ARP 请求，PC 端 Wireshark 抓包
//
// 跳过 MDIO（厂商示例工程也不使用 MDIO，PHY 靠 strap 自动配置）
// 直接验证 RGMII TX 数据通路：FPGA → PHY → 网线 → PC
//
// PLL 50MHz → 125MHz（C0）
// ARP 帧生成器（125MHz 域）→ GMII 8-bit → RGMII TX DDR → PHY
//
// LED:
//   LED[0] (D10) = phy_rst_done
//   LED[1] (E10) = PLL lock
//   LED[2] (C6)  = ARP TX busy（帧发送中亮）
//   LED[3] (D6)  = 心跳
//
// 预期：烧 bit 后，PC 端 Wireshark 应收到来自 01:23:45:67:89:AB 的 ARP 请求

`timescale 1ns/1ps

module m1_top (
    input  wire        I_sys_clk,        // C4 50MHz
    output wire [3:0]  O_led,            // D10/E10/C6/D6
    output wire        O_uart_tx,        // H1（保留，空闲高）

    // RGMII TX（FPGA → PHY）
    output wire        O_rgmii_txc,     // U9  GTX_CLK
    output wire        O_rgmii_tx_ctl,  // R10 TX_CTL
    output wire [3:0]  O_rgmii_txd,     // R11/P11/T10/R12

    // RGMII RX（PHY → FPGA，暂不使用）
    input  wire        I_rgmii_rxc,     // V2
    input  wire        I_rgmii_rx_ctl,  // N8
    input  wire [3:0]  I_rgmii_rxd,     // N9/T7/T8/T9

    // 管理/控制
    output wire        O_rgmii_mdc,     // V9（不驱动）
    inout  wire        IO_rgmii_mdio,   // U10（高阻）
    output wire        O_phy_rst_n      // V8
);
    // ------------------------------------------------------------------
    // 上电复位
    // ------------------------------------------------------------------
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

    // ------------------------------------------------------------------
    // PLL: 50MHz → 125MHz (C0) + 保留原 C1/C4/C5
    // ------------------------------------------------------------------
    wire clk_125;
    wire clk_125_90;  // 125MHz 90 度相移（RGMII TX delay）
    wire pll_lock;
    PLL u_pll (
        .refclk   ( I_sys_clk  ),
        .clk0_out ( clk_125    ),
        .clk1_out ( clk_125_90 ),
        .clk4_out (            ),
        .clk5_out (            ),
        .lock     ( pll_lock   ),
        .reset    ( ~sys_rst_n )
    );

    // 125MHz 域复位（PLL lock + sys_rst_n）
    wire rst_125_n = sys_rst_n & pll_lock;

    // ------------------------------------------------------------------
    // PHY 复位序列器（50MHz 域）
    // ------------------------------------------------------------------
    wire phy_rst_done;
    phy_rst #(
        .RESET_TIME_MS (2),
        .POST_RST_MS   (5),
        .CLK_FREQ_HZ   (50_000_000)
    ) u_phy_rst (
        .clk        ( I_sys_clk   ),
        .rst_n      ( sys_rst_n   ),
        .phy_rst_n  ( O_phy_rst_n ),
        .rst_done   ( phy_rst_done)
    );

    // ------------------------------------------------------------------
    // ARP 帧生成器（125MHz 域）
    // ------------------------------------------------------------------
    wire [7:0] gmii_txd;
    wire       gmii_tx_en;
    wire       gmii_tx_er;
    wire       tx_busy;
    wire       frame_sent;

    arp_tx #(
        .SEND_INTERVAL_CYCLES ( 125_000_000 * 1 )  // 1 秒发一次
    ) u_arp_tx (
        .clk_125    ( clk_125    ),
        .rst_n      ( rst_125_n  ),
        .gmii_txd   ( gmii_txd   ),
        .gmii_tx_en ( gmii_tx_en ),
        .gmii_tx_er ( gmii_tx_er ),
        .tx_busy    ( tx_busy    ),
        .frame_sent ( frame_sent )
    );

    // ------------------------------------------------------------------
    // RGMII TX DDR：GMII 8-bit @ 125M → RGMII 4-bit DDR
    // ------------------------------------------------------------------
    rgmii_tx_ddr u_rgmii_tx (
        .clk_125m    ( clk_125       ),
        .clk_125m_90 ( clk_125_90    ),  // 恢复 90° delay + GTX_CLK 极性修正
        .gmii_txd    ( gmii_txd      ),
        .gmii_tx_en  ( gmii_tx_en    ),
        .gmii_tx_er  ( gmii_tx_er    ),
        .rgmii_txc   ( O_rgmii_txc   ),
        .rgmii_txd   ( O_rgmii_txd   ),
        .rgmii_tx_ctl( O_rgmii_tx_ctl)
    );

    // ------------------------------------------------------------------
    // LED 状态 + RGMII RX_CLK 诊断
    // ------------------------------------------------------------------
    reg [25:0] hb_cnt;
    wire       hb;
    always @(posedge I_sys_clk) hb_cnt <= hb_cnt + 1'b1;
    assign hb = hb_cnt[25];

    // clk_125 诊断：用 125MHz 自己计数，确认 PLL 输出是否在跑
    //   clk_125 = 125MHz → cnt[23] ≈ 7.45Hz 快闪 = PLL 在跑
    reg [24:0] clk125_cnt;
    always @(posedge clk_125) clk125_cnt <= clk125_cnt + 1'b1;

    assign O_led[0] = phy_rst_done;
    assign O_led[1] = clk125_cnt[23];  // PLL 125MHz 是否在跑
    assign O_led[2] = frame_sent;   // 锁存：发过帧后持续亮
    assign O_led[3] = hb;

    // ------------------------------------------------------------------
    // 不使用的引脚
    // ------------------------------------------------------------------
    assign O_rgmii_mdc = 1'b0;
    assign IO_rgmii_mdio = 1'bz;
    assign O_uart_tx = 1'b1;  // 空闲高

    // I_rgmii_rxc / I_rgmii_rx_ctl / I_rgmii_rxd 悬空（M1.2 起做 RX）

endmodule
