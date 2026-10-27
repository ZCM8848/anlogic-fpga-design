# camera_eth_720p 时序约束
# PLL: 50MHz 输入 → C0 125MHz（C0 = (FIN/REFCLK_DIV) × FBCLK_DIV = 50/2 × 5）

create_clock -name clk_in -period 20.000 -waveform {0 10} [get_ports {I_sys_clk}]

create_generated_clock -name clk_125 -source [get_ports {I_sys_clk}] -master_clock {clk_in} \
    -multiply_by 2.5 [get_pins {u_pll/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[0]}]

# PHY 送来的 RGMII RX_CLK（125MHz；RX 逻辑全部跑在这个域）
create_clock -name rgmii_rxc -period 8.000 -waveform {0 4} [get_ports {I_rgmii_rxc}]

# PLL C1 = 23.81MHz（摄像头 XCLK + I2C 配置逻辑）
#   TD 不允许在 PLL 的 clkc[1] 上 create_clock/create_generated_clock（USR-8159）。
#   结果：这 23.8MHz 域被并进 clk_in 一起分析，final 报告里会出现一个
#   HWNS ≈ -1.05ns 的「假 hold 违例」，路径全部是 uicfgcs520 的准静态寄存器
#   （I2C 配置值 / 传感器 ID），同一物理时钟的两个分支，实际不影响功能。
#   若以后要消掉：让 TD 用 derive_clocks 自己推导该时钟，再 rename_clock。

# D-PHY 恢复的字节时钟：SC520CS 2lane/RAW10/720p60，lane 828Mbps
#   → 字节时钟 = 828/8 = 103.5MHz（周期 9.66ns），仅用于 CSI 解包 + FIFO 写侧
#   挂 wrapper 输出端口会 fanout=0（网表里被合并了），要挂内部实际驱动的网络
create_clock -name MIPI_RX_BYTE_CLK -period 9.660 -waveform {0 4.830} \
    [get_nets {u_cam/u_dphy/u_ph1p_mipiio_rx_wrapper/S_mipiio_hs_rx_clk}]

# 时钟域互相异步；摄像头字节流经异步 FIFO 跨到 clk_125
set_clock_groups -asynchronous \
    -group [get_clocks {clk_in}] \
    -group [get_clocks {clk_125}] \
    -group [get_clocks {rgmii_rxc}] \
    -group [get_clocks {MIPI_RX_BYTE_CLK}]
