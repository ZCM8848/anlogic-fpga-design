# camera_hdmi_720p — 时序约束（M1：HDMI 测试图案）
# 说明：PLL 时钟由 derive_clocks 推导后重命名，供后续约束/时钟组引用

create_clock -name {sys_clk_50m} -period 20.000 -waveform {0.000 10.000} [get_ports {I_sys_clk}]

# M3：MIPI 时钟 lane（828Mbps/lane → 414MHz DDR，周期 2.415ns）
create_clock -name {mipi_rx_ck_pad} -period 2.415 -waveform {0.000 1.208} [get_nets {IO_rx_clk_pad_p}]

derive_clocks

rename_clock -name {pll_clk_100m}    [get_clocks {u_pll/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[0]}]
rename_clock -name {pll_clk_24m}     [get_clocks {u_pll/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[1]}]
rename_clock -name {HDMI_PIXEL_CLK}  [get_clocks {u_pll/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[4]}]
rename_clock -name {HDMI_SERIAL_CLK} [get_clocks {u_pll/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[5]}]

# ---- M3：MIPI CSI-2 接收时钟域 ----
# 字节时钟由 IP 内部从时钟 lane 恢复并 4 分频（1:8 模式）；实例名与 IP 配套流程一致
rename_clock -name {MIPI_RX_BYTE_CLK} [get_clocks {u_mipi_dphy_rx_ph1p_mipiio_wrapper/u_ph1p_mipiio_rx_wrapper/u_PH1P_LOGIC_DPHY_MIPI_RX.o_fabric_div4_8_clk}]

# MIPI 域与本地时钟域异步；跨域数据由 mipi_stats 的 req/ack 双相握手保护（多周期稳定）
set_clock_groups -asynchronous \
    -group [get_clocks {mipi_rx_ck_pad MIPI_RX_BYTE_CLK}] \
    -group [get_clocks {sys_clk_50m pll_clk_100m pll_clk_24m HDMI_PIXEL_CLK HDMI_SERIAL_CLK}]

# M5 起追加：DDR 时钟组
