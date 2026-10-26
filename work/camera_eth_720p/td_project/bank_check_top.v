// bank_check_top.v — M0 bank 兼容性 + 原语综合验证顶层
//
// 目的（M0）：
//   1. 验证 RGMII 14 引脚都能在 LVCMOS33 下被 TD 接受（无 bank / VCCIO 冲突）
//   2. 验证 PH1P_LOGIC_HD_ODDR / PH1P_LOGIC_HD_IDDR 原语可综合且能在 fabric 中例化
//   3. 通过"全 HD 变体"策略一次摸清所有 RGMII 引脚的 bank 归属：
//        - HD 变体在 HD bank 上 OK，在 HR bank 上报"can't be mapped into HRIO"
//        - 反过来即知每个 pin 的 bank 类型
//   4. 不实现任何实际网络功能（M1 起再做）
//
// 端口命名与 constraints/pin.adc 一一对应。
// 不依赖任何 IP（PLL、DDR2、MIPI 均不例化），用 I_sys_clk 直接驱动一个简单分频
// 产生"伪 125M"域仅用于让 ODDR/IDDR 有时钟可挂；M1 起会换为真 PLL 出 125M。

`timescale 1ns/1ps

module bank_check_top (
    // ---- 系统时钟 / LED / UART ----
    input  wire        I_sys_clk,       // C4 50MHz
    output wire [3:0]  O_led,           // D10/E10/C6/D6
    output wire        O_uart_tx,       // H1（M0 不驱动，留作后续）

    // ---- RGMII TX（FPGA → PHY）----
    output wire        O_rgmii_txc,     // U9  GTX_CLK
    output wire        O_rgmii_tx_ctl,  // R10 TX_EN / TX_CTL
    output wire [3:0]  O_rgmii_txd,     // R11/P11/T10/R12

    // ---- RGMII RX（PHY → FPGA）----
    input  wire        I_rgmii_rxc,     // V2  RX_CLK（原理图核实；docx 漏列）
    input  wire        I_rgmii_rx_ctl,  // N8  RX_DV / RX_CTL（板手册"RXC_DV"实际只是 DV）
    input  wire [3:0]  I_rgmii_rxd,     // N9/T7/T8/T9

    // ---- 管理 / 控制 ----
    output wire        O_rgmii_mdc,     // V9
    inout  wire        IO_rgmii_mdio,   // U10
    output wire        O_phy_rst_n      // V8
);

    // ------------------------------------------------------------------
    // 简单分频：从 50MHz 得 ~1Hz 心跳，证明 fabric 起得来 + 引脚无冲突
    // ------------------------------------------------------------------
    reg [25:0] r_cnt = 26'd0;
    wire       w_1hz;
    always @(posedge I_sys_clk) r_cnt <= r_cnt + 1'b1;
    assign w_1hz = r_cnt[25];   // 50MHz / 2^26 ≈ 0.745Hz

    // ------------------------------------------------------------------
    // PH1P_LOGIC_HD_ODDR 例化（全 HD 变体策略）
    //   每个 ODDR 对应一个 TX 引脚；HD 变体在 HR bank 上会报"can't map to HRIO"
    // ------------------------------------------------------------------
    PH1P_LOGIC_HD_ODDR u_oddr_txc (
        .q    ( O_rgmii_txc    ),
        .clk  ( I_sys_clk       ),
        .d1   ( w_1hz           ),
        .d0   ( ~w_1hz          ),
        .rst  ( 1'b0            )
    );

    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : gen_oddr_txd
            PH1P_LOGIC_HD_ODDR u_oddr_txd (
                .q    ( O_rgmii_txd[i] ),
                .clk  ( I_sys_clk       ),
                .d1   ( w_1hz           ),
                .d0   ( ~w_1hz          ),
                .rst  ( 1'b0            )
            );
        end
    endgenerate

    PH1P_LOGIC_HD_ODDR u_oddr_txc_ctl (
        .q    ( O_rgmii_tx_ctl ),
        .clk  ( I_sys_clk       ),
        .d1   ( w_1hz           ),
        .d0   ( ~w_1hz          ),
        .rst  ( 1'b0            )
    );

    // ------------------------------------------------------------------
    // PH1P_LOGIC_HD_IDDR 例化（全 HD 变体策略）
    //   RX_CLK 用 V2，RX_DV/RX_CTL 用 N8，RXD[3:0] 用 N9/T7/T8/T9
    // ------------------------------------------------------------------
    wire q1_rxc, q0_rxc;
    PH1P_LOGIC_HD_IDDR #(.MODE("OPPOSITE_EDGE")) u_iddr_rxc (
        .q1   ( q1_rxc ),
        .q0   ( q0_rxc ),
        .clk  ( I_rgmii_rxc ),
        .d    ( I_rgmii_rx_ctl ),
        .rst  ( 1'b0 )
    );

    wire q1_d0, q0_d0, q1_d1, q0_d1, q1_d2, q0_d2, q1_d3, q0_d3;
    PH1P_LOGIC_HD_IDDR #(.MODE("OPPOSITE_EDGE")) u_iddr_rxd0 (
        .q1   ( q1_d0 ), .q0 ( q0_d0 ),
        .clk  ( I_rgmii_rxc ),
        .d    ( I_rgmii_rxd[0] ),
        .rst  ( 1'b0 )
    );
    PH1P_LOGIC_HD_IDDR #(.MODE("OPPOSITE_EDGE")) u_iddr_rxd1 (
        .q1   ( q1_d1 ), .q0 ( q0_d1 ),
        .clk  ( I_rgmii_rxc ),
        .d    ( I_rgmii_rxd[1] ),
        .rst  ( 1'b0 )
    );
    PH1P_LOGIC_HD_IDDR #(.MODE("OPPOSITE_EDGE")) u_iddr_rxd2 (
        .q1   ( q1_d2 ), .q0 ( q0_d2 ),
        .clk  ( I_rgmii_rxc ),
        .d    ( I_rgmii_rxd[2] ),
        .rst  ( 1'b0 )
    );
    PH1P_LOGIC_HD_IDDR #(.MODE("OPPOSITE_EDGE")) u_iddr_rxd3 (
        .q1   ( q1_d3 ), .q0 ( q0_d3 ),
        .clk  ( I_rgmii_rxc ),
        .d    ( I_rgmii_rxd[3] ),
        .rst  ( 1'b0 )
    );

    assign O_led[0] = q0_rxc;
    assign O_led[1] = q1_rxc;
    assign O_led[2] = q0_d0 ^ q1_d1 ^ q0_d2 ^ q1_d3;  // 占位，防综合裁剪
    assign O_led[3] = w_1hz;

    // ------------------------------------------------------------------
    // 管理 / 控制：M0 仅静态驱动
    // ------------------------------------------------------------------
    assign O_rgmii_mdc   = 1'b0;           // M1 起做 MDIO 控制器
    assign IO_rgmii_mdio = 1'bz;           // 高阻，等 MCU/fabric 接管
    assign O_phy_rst_n   = 1'b1;           // PHY 拉出复位（M1 起做时序）
    assign O_uart_tx     = 1'b1;           // 空闲高

endmodule
