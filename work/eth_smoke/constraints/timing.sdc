# eth_smoke 时序约束
# PLL: 50MHz 输入 → C0 125MHz(0°) / C1 125MHz(90°)

create_clock -name clk_in -period 20.000 -waveform {0 10} [get_ports {I_sys_clk}]

create_generated_clock -name clk_125 -source [get_ports {I_sys_clk}] -master_clock {clk_in} \
    -multiply_by 2.5 [get_pins {u_pll/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[0]}]

create_generated_clock -name clk_125_90 -source [get_ports {I_sys_clk}] -master_clock {clk_in} \
    -multiply_by 2.5 -phase 90 [get_pins {u_pll/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[1]}]

# PHY 送来的 RGMII RX_CLK（本工程只做存在检测）
create_clock -name rgmii_rxc -period 8.000 -waveform {0 4} [get_ports {I_rgmii_rxc}]

set_clock_groups -asynchronous -group [get_clocks {clk_125}] -group [get_clocks {rgmii_rxc}]
