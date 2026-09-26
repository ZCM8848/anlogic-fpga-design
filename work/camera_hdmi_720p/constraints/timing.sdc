# camera_hdmi_720p — 时序约束（M1：HDMI 测试图案）
# 说明：PLL 时钟由 derive_clocks 推导后重命名，供后续约束/时钟组引用

create_clock -name {sys_clk_50m} -period 20.000 -waveform {0.000 10.000} [get_ports {I_sys_clk}]

derive_clocks

rename_clock -name {pll_clk_100m}    [get_clocks {u_pll/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[0]}]
rename_clock -name {pll_clk_24m}     [get_clocks {u_pll/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[1]}]
rename_clock -name {HDMI_PIXEL_CLK}  [get_clocks {u_pll/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[4]}]
rename_clock -name {HDMI_SERIAL_CLK} [get_clocks {u_pll/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[5]}]

# M3/M5 起追加：MIPI 接收时钟（IO_rx_clk_pad_p，见 docs/plan.md）与 DDR 时钟组
