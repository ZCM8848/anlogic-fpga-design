create_clock -name SYS_CLK -period 20 -waveform {0 10} [get_ports {FPGA_SYS_50M_CLK_P}]
create_generated_clock  -name pclk -source [get_ports {FPGA_SYS_50M_CLK_P}] -master_clock SYS_CLK -multiply_by 4.76 [get_nets {pxlclk_i}]
create_generated_clock  -name sclk5 -source [get_ports {FPGA_SYS_50M_CLK_P}] -master_clock SYS_CLK -multiply_by 23.8 [get_nets {pxlclk_5x_i}]
