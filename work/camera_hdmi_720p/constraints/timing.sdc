# camera_hdmi_720p — 时序约束（M6 三模式重构）
# PLL 时钟由 derive_clocks 推导后重命名；时钟组划分照参考工程（3 组：MIPI / system+HDMI / DDR）。

create_clock -name {sys_clk_50m} -period 20.000 -waveform {0.000 10.000} [get_ports {I_sys_clk}]

# MIPI 时钟 lane（828Mbps/lane → 414MHz DDR，周期 2.415ns）
create_clock -name {mipi_rx_ck_pad} -period 2.415 -waveform {0.000 1.208} [get_nets {IO_rx_clk_pad_p}]

derive_clocks

rename_clock -name {pll_clk_100m}    [get_clocks {u_pll/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[0]}]
rename_clock -name {pll_clk_24m}     [get_clocks {u_pll/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[1]}]
rename_clock -name {HDMI_PIXEL_CLK}  [get_clocks {u_pll/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[4]}]
rename_clock -name {HDMI_SERIAL_CLK} [get_clocks {u_pll/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[5]}]

# MCU PLL（pll_mcu：50MHz 板钟 -> 300MHz core_clk；同源于 sys_clk_50m）
rename_clock -name {pll_clk_300m} [get_clocks {u_pll_mcu/ph1p_phy_pll_wrapper_f0c09858d34b_Inst/u_PH1P_PHY_PLL.clkc[0]}]

# MIPI 字节时钟：IP 内部从时钟 lane 恢复并 4 分频（1:8 模式 = 串行时钟/4 ≈ 103.5MHz）
# 该时钟喂 csi_unpacket / raw10_unpacket / uial2axis / isp_top / video_in 写侧
rename_clock -name {MIPI_RX_BYTE_CLK} [get_clocks {u_mipi_dphy_rx_ph1p_mipiio_wrapper/u_ph1p_mipiio_rx_wrapper/u_PH1P_LOGIC_DPHY_MIPI_RX.o_fabric_div4_8_clk}]

# 时钟组（异步）：
#   1) MIPI 域（pad + 恢复字节时钟）—— HS 时钟停摆时该域逻辑冻结
#   2) system + HDMI 域（同 PLL 派生：50M/100M/24M/75M/375M 互相同步；无 reg→reg 跨域）
#   3) DDR 域（IP 输出 ddr_clk/usr_clk）
#   4) MCU core_clk(300M) —— MCU 黑盒内部把 core_clk↔apb_clk(50M) 桥接（APB 协议保证时序）；
#      TD 把 MCU 的 APB 输出端口误归到 core_clk(3.3ns)，若与 50M 同组会按"同域"分析→巨违例，
#      故单列异步组 cut 掉 300M↔其它（300M fanout=0、无 fabric reg，cut 无副作用）。
#      注：TD 把 pll_mcu 输出 pll_clk_300m 和 MCU 内部 ...PH1P_PHY_MCU_Inst.core_clk 当两个 clock 对象，
#      两者都要进异步组，否则内部 core_clk 仍会和 50M 判"同域"。
# 跨域路径：MIPI↔DDR / MIPI↔system / DDR↔system / MCU↔system 均经异步 FIFO 或 2FF 或 APB 协议保护
set_clock_groups -asynchronous \
    -group [get_clocks {mipi_rx_ck_pad MIPI_RX_BYTE_CLK}] \
    -group [get_clocks {sys_clk_50m pll_clk_100m pll_clk_24m HDMI_PIXEL_CLK HDMI_SERIAL_CLK}] \
    -group [get_clocks {u_ph1p35_324_ddr_wrapper/u_ddr2/ddr_clk u_ph1p35_324_ddr_wrapper/u_ddr2/usr_clk}] \
    -group [get_clocks {pll_clk_300m u_ps/u_MCU/MCU_f9f874759a41_Inst/PH1P_PHY_MCU_Inst.core_clk}]
