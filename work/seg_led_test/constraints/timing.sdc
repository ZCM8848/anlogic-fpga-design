# seg_led_test — 时序约束
# 设计只有板载 50MHz 单时钟域，无 PLL、无跨时钟域。

create_clock -name {sys_clk_50m} -period 20.000 -waveform {0.000 10.000} [get_ports {I_sys_clk}]

# 输入按键/开关是慢速异步信号，RTL 内已做 2FF 同步 + 20ms 消抖。
# 输出数码管为扫描式静态显示，不需要额外的 IO 时序约束。
