// eth_top.v — 以太网 TX 通断测试（独立工程，M1.3）
//
// 只做一件事：每 200ms 从 FPGA 发一个 64 字节 ARP 请求帧给 PC，
// 证明 RGMII TX 通路（FPGA → YT8511 → 网线 → PC）是通的。
//
// 与 m1_top 的差异（都是 bug 修复）：
//   1. ODDR d0/d1 对应关系修正（d0 = 上升沿 = 低 nibble）
//      —— 之前 d1=低 nibble，实际把高/低 nibble 发反了，
//         且 TX_EN 落到了下降沿，PHY 收不到有效 TX_EN
//   2. FCS 由 PC 端 zlib.crc32 预计算写死（之前 crc_lut 无驱动，FCS 全错）
//   3. 帧补齐到 64 字节（之前 46 字节，被当成 runt 丢弃）
//
// LED：
//   LED[0] D10 = PLL lock
//   LED[1] E10 = frame_sent（发过帧后常亮）
//   LED[2] C6  = RX_CLK 存在（PHY 送来 125MHz 则常亮）
//   LED[3] D6  = 50MHz 心跳
//
`timescale 1ns/1ps

module eth_top (
    input  wire        I_sys_clk,        // C4  50MHz

    output wire [3:0]  O_led,            // D10/E10/C6/D6

    // RGMII TX（FPGA → PHY）
    output wire        O_rgmii_txc,      // U9  GTX_CLK
    output wire        O_rgmii_tx_ctl,   // R10 TX_CTL
    output wire [3:0]  O_rgmii_txd,      // R11/P11/T10/R12

    // RGMII RX（PHY → FPGA，本工程只用 RX_CLK 做存在检测）
    input  wire        I_rgmii_rxc,      // V2
    input  wire        I_rgmii_rx_ctl,   // N8
    input  wire [3:0]  I_rgmii_rxd,      // N9/T7/T8/T9

    // 管理 / 控制
    output wire        O_rgmii_mdc,      // V9  （不发 MDIO，PHY 靠 strap）
    inout  wire        IO_rgmii_mdio,    // U10 （高阻）
    output wire        O_phy_rst_n       // V8
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
    // PLL：50MHz → C0 125MHz(0°) + C1 125MHz(90°)
    // ------------------------------------------------------------------
    wire clk_125;
    wire clk_125_90_raw;
    wire clk_125_90;
    wire pll_lock;

    PLL u_pll (
        .refclk   ( I_sys_clk      ),
        .clk0_out ( clk_125        ),
        .clk1_out ( clk_125_90_raw ),
        .clk4_out (                ),
        .clk5_out (                ),
        .lock     ( pll_lock       ),
        .reset    ( ~sys_rst_n     )
    );

    // C1 输出必须经全局时钟缓冲才能驱动 I/O 单元的 ODDR 时钟
    PH1P_LOGIC_BUFG u_bufg_90 (
        .i ( clk_125_90_raw ),
        .o ( clk_125_90     )
    );

    wire rst_125_n = sys_rst_n & pll_lock;

    // ------------------------------------------------------------------
    // PHY 硬复位（低有效 ≥1ms，释放后等 5ms）
    // ------------------------------------------------------------------
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

    // ------------------------------------------------------------------
    // ARP 帧发送（125MHz 域）
    // ------------------------------------------------------------------
    wire [7:0] gmii_txd;
    wire       gmii_tx_en;
    wire       gmii_tx_er;
    wire       tx_active;
    wire       frame_sent;

    arp_frame_tx #(
        .SEND_INTERVAL_CYCLES ( 32'd25_000_000 )   // 200 ms
    ) u_frame (
        .clk       ( clk_125    ),
        .rst_n     ( rst_125_n  ),
        .gmii_txd  ( gmii_txd   ),
        .gmii_tx_en( gmii_tx_en ),
        .gmii_tx_er( gmii_tx_er ),
        .tx_active ( tx_active  ),
        .frame_sent( frame_sent )
    );

    // ------------------------------------------------------------------
    // RGMII TX 物理层
    // ------------------------------------------------------------------
    rgmii_tx_phy u_rgmii_tx (
        .clk_125    ( clk_125      ),
        .clk_125_90 ( clk_125      ),   // 0° 时钟 + 引脚 OUTDEL 延迟（见 pin.adc）
        .rst        ( ~rst_125_n ),
        .gmii_txd   ( gmii_txd   ),
        .gmii_tx_en ( gmii_tx_en ),
        .gmii_tx_er ( gmii_tx_er ),
        .rgmii_txc  ( O_rgmii_txc    ),
        .rgmii_tx_ctl( O_rgmii_tx_ctl),
        .rgmii_txd  ( O_rgmii_txd    )
    );

    // ------------------------------------------------------------------
    // LED
    // ------------------------------------------------------------------
    reg [25:0] hb_cnt;
    always @(posedge I_sys_clk) hb_cnt <= hb_cnt + 1'b1;

    // RX_CLK 存在检测：只要 V2 上有 125MHz 翻转，这个寄存器就会被写成 1
    reg rxc_seen = 1'b0;
    always @(posedge I_rgmii_rxc) rxc_seen <= 1'b1;

    assign O_led[0] = pll_lock;
    assign O_led[1] = frame_sent;
    assign O_led[2] = rxc_seen;
    assign O_led[3] = hb_cnt[25];

    // ------------------------------------------------------------------
    // 不用
    // ------------------------------------------------------------------
    assign O_rgmii_mdc  = 1'b0;
    assign IO_rgmii_mdio = 1'bz;

endmodule
