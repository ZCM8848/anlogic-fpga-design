// rgmii_ddr.v — RGMII DDR 原语封装（PH1P_LOGIC_HD_ODDR / HD_IDDR 例化）
//
// 由 M0 核实结论定调：
//   所有 RGMII 引脚都在 HDIO bank，必须用 HD 变体（不能普通 IDDR/ODDR）
//   - TX：5× PH1P_LOGIC_HD_ODDR（GTX_CLK + TX_CTL + TXD[3:0]）
//   - RX：5× PH1P_LOGIC_HD_IDDR（RX_CLK 解 RX_CTL + RXD[3:0]）
//
// RGMII v2.0 时序约定：
//   - 125 MHz DDR：上升沿传低位 nibble + DV/EN，下降沿传高位 nibble + ER
//   - TX_CLK 由 FPGA 产生，可用 PHY 内部 delay 或 FPGA IDELAY 调 clock-data skew
//   - RX_CLK 由 PHY 产生，FPGA 直接采样
//
`timescale 1ns/1ps

// =====================================================================
// RGMII TX：GMII 8-bit @ 125M → RGMII 4-bit DDR
// =====================================================================
module rgmii_tx_ddr (
    input  wire        clk_125m,       // GMII 域 125 MHz 时钟（0 度，驱动 TX_DATA）
    input  wire        clk_125m_90,    // 125 MHz 90 度相移时钟（驱动 GTX_CLK，RGMII TX delay ~2ns）
    input  wire [7:0]  gmii_txd,       // GMII 发送数据
    input  wire        gmii_tx_en,     // GMII 发送使能
    input  wire        gmii_tx_er,     // GMII 发送错误
    output wire        rgmii_txc,      // RGMII GTX_CLK
    output wire [3:0]  rgmii_txd,      // RGMII TXD（4-bit DDR）
    output wire        rgmii_tx_ctl    // RGMII TX_CTL（上升沿=EN，下降沿=ER）
);
    // GTX_CLK：d1=1(上升沿), d0=0(下降沿) → 先高后低标准 50% 方波
    PH1P_LOGIC_HD_ODDR u_oddr_txc (
        .q    ( rgmii_txc    ),
        .clk  ( clk_125m_90  ),
        .d1   ( 1'b1       ),     // 上升沿输出 1
        .d0   ( 1'b0       ),     // 下降沿输出 0
        .rst  ( 1'b0        )
    );

    // TXD[3:0] DDR：上升沿 = gmii_txd[3:0]，下降沿 = gmii_txd[7:4]
    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : gen_txd
            PH1P_LOGIC_HD_ODDR u_oddr_txd (
                .q    ( rgmii_txd[i]    ),
                .clk  ( clk_125m        ),
                .d1   ( gmii_txd[i]     ),     // 上升沿
                .d0   ( gmii_txd[i+4]   ),     // 下降沿
                .rst  ( 1'b0            )
            );
        end
    endgenerate

    // TX_CTL DDR：上升沿 = TX_EN，下降沿 = TX_ER
    PH1P_LOGIC_HD_ODDR u_oddr_txctl (
        .q    ( rgmii_tx_ctl ),
        .clk  ( clk_125m     ),
        .d1   ( gmii_tx_en   ),     // 上升沿 = EN
        .d0   ( gmii_tx_er   ),     // 下降沿 = ER
        .rst  ( 1'b0          )
    );
endmodule

// =====================================================================
// RGMII RX：RGMII 4-bit DDR → GMII 8-bit @ 125M（同步于 PHY 输入的 RX_CLK）
// =====================================================================
module rgmii_rx_ddr (
    input  wire        rgmii_rxc,      // RGMII RX_CLK（PHY 提供，125 MHz）
    input  wire [3:0]  rgmii_rxd,      // RGMII RXD（4-bit DDR）
    input  wire        rgmii_rx_ctl,   // RGMII RX_CTL（上升沿=DV，下降沿=ER）
    input  wire        rst_n,
    output reg  [7:0]  gmii_rxd,       // GMII 接收数据（已 1 拍流水）
    output reg         gmii_rx_dv,     // GMII 接收使能
    output reg         gmii_rx_er      // GMII 接收错误
);
    // RXD[3:0] DDR 解码：q1=上升沿数据（→低 nibble），q0=下降沿数据（→高 nibble）
    wire [3:0] q1_rxd, q0_rxd;
    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : gen_rxd
            PH1P_LOGIC_HD_IDDR #(.MODE("OPPOSITE_EDGE")) u_iddr_rxd (
                .q1   ( q1_rxd[i]    ),     // 上升沿采样
                .q0   ( q0_rxd[i]    ),     // 下降沿采样
                .clk  ( rgmii_rxc    ),
                .d    ( rgmii_rxd[i] ),
                .rst  ( rst_n        )
            );
        end
    endgenerate

    // RX_CTL DDR 解码：q1=RX_DV（上升沿），q0=RX_ER（下降沿）
    wire q1_ctl, q0_ctl;
    PH1P_LOGIC_HD_IDDR #(.MODE("OPPOSITE_EDGE")) u_iddr_rxctl (
        .q1   ( q1_ctl        ),
        .q0   ( q0_ctl        ),
        .clk  ( rgmii_rxc     ),
        .d    ( rgmii_rx_ctl   ),
        .rst  ( rst_n          )
    );

    // 在 rgmii_rxc 域寄存 1 拍，得到稳定的 GMII 输出
    //   上升沿时刻：q1_rxd 刚采到（低 nibble），q0_rxd 是上一拍下降沿的（高 nibble）
    //   合成：gmii_rxd = {q0_rxd, q1_rxd}  [7:4]=高 nibble, [3:0]=低 nibble
    always @(posedge rgmii_rxc or negedge rst_n) begin
        if (!rst_n) begin
            gmii_rxd    <= 8'd0;
            gmii_rx_dv  <= 1'b0;
            gmii_rx_er  <= 1'b0;
        end else begin
            gmii_rxd    <= {q0_rxd, q1_rxd};
            gmii_rx_dv  <= q1_ctl;
            gmii_rx_er  <= q0_ctl;
        end
    end
endmodule
