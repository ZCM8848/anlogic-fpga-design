# buzzer_music — 时序约束
# 设计只有板载 50MHz 单时钟域，无 PLL、无跨时钟域。
# 输入按键为慢速异步信号，RTL 内已做 2FF 同步 + 20ms 消抖。
# 蜂鸣器输出为方波/电平驱动，不需要额外的 IO 时序约束。

create_clock -name {sys_clk_50m} -period 20.000 -waveform {0.000 10.000} [get_ports {I_sys_clk}]
