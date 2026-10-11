`timescale 1ns / 1ps
//=============================================================================
// ps_wrapper.v — MCU 例化包装（B2：适配 TD6.2 重生的 mcu IP）
// ============================================================
// MCU IP 按《PH1P35 内 MCU 核使用指南》重生：JTAG off（走板载 USB-JTAG 专用 pad，
// 不进 fabric）、GPIO0-7 off、UART1/I2C/QSPI1 off、UART0/AHB/APB on。端口表大幅精简。
// 本包装只引出本项目要用的：APB/UART0/AHB(悬空)/时钟复位 + core_sysrst。
//   - APB 主机口（O_apb_*）→ apb_status_slave（fabric 侧状态寄存器）
//   - UART0（O_uart0_tx/I_uart0_rx）→ 顶层接 H1/J1（B7 切换时）
//   - AHB 全部悬空（无 AHB 从设备，给默认 OKAY/ready=1，与指南一致）
//   - core_sysrst：MCU 主动复位输出（暂悬空，留扩展）
//   - core_clk = pll_mcu 300MHz；timer_clk = C0 100MHz；apb_clk = I_sys_clk 50MHz
//   - 实例名保留 u_MCU（不改 u_mcu），让 timing.sdc 里 MCU 内部 core_clk 路径只动哈希
//=============================================================================
module ps_wrapper (
    input wire        I_core_clk,
    input wire        I_timer_clk,
    input wire        I_rst,

    output wire       O_core_sysrst,

    input wire        I_apb_clk,
    input wire        I_apb_rst,
    output wire [19:0] O_apb_paddr,
    output wire       O_apb_psel,
    output wire       O_apb_penable,
    output wire       O_apb_pwrite,
    output wire [31:0] O_apb_pwdata,
    output wire [3:0]  O_apb_pstrobe,
    output wire [2:0]  O_apb_pprot,
    input wire [31:0] I_apb_prdata,
    input wire        I_apb_pready,
    input wire        I_apb_pslverr,

    output wire       O_uart0_tx,
    input wire        I_uart0_rx
);

    mcu u_MCU(
        .core_clk   ( I_core_clk    ),
        .timer_clk  ( I_timer_clk   ),
        .core_reset ( I_rst         ),
        .por_reset  ( I_rst         ),
        .nmi        ( 1'b0          ),
        .clic_irq   ( 23'd0         ),
        .core_sysrst( O_core_sysrst ),

        .apb_clk    ( I_apb_clk     ),
        .apb_rst    ( I_apb_rst     ),
        .paddr      ( O_apb_paddr   ),
        .psel       ( O_apb_psel    ),
        .penable    ( O_apb_penable ),
        .pwrite     ( O_apb_pwrite  ),
        .pwdata     ( O_apb_pwdata  ),
        .pstrobe    ( O_apb_pstrobe ),
        .pprot      ( O_apb_pprot   ),
        .prdata     ( I_apb_prdata  ),
        .pready     ( I_apb_pready  ),
        .pslverr    ( I_apb_pslverr ),

        // AHB 不用（无 AHB 从设备，默认 OKAY/ready=1，与指南一致）
        .ahb_clk    (               ),
        .htrans     (               ),
        .hwrite     (               ),
        .haddr      (               ),
        .hsize      (               ),
        .hburst     (               ),
        .hprot      (               ),
        .hmastlock  (               ),
        .hwdata     (               ),
        .hrdata     ( 32'd0         ),
        .hresp      ( 2'b00         ),
        .hready     ( 1'b1          ),

        .uart0_tx   ( O_uart0_tx    ),
        .uart0_rx   ( I_uart0_rx    )
    );

endmodule
