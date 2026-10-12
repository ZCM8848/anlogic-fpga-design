`timescale 1ns / 1ps
//=============================================================================
// ps_wrapper.v — MCU 例化包装（B6：状态从口改走 AHB，窗口 0x80000000）
// ============================================================
// fabric APB 窗口基址文档里找不到；fabric AHB 窗口 = 0x80000000（AHBDemo 验证）。
// 故把状态从口从 APB 改到 AHB：
//   - AHB master 端口（O_ahb_*）→ 外部 ahb_status_slave（fabric 侧状态寄存器）
//   - APB master 端口：不用，内部默认返回 ready=1/error=0（apb_clk 喂 timer_clk 保持域活）
//   - UART0（O_uart0_tx/I_uart0_rx）→ 顶层接 H1/J1（B7 切换时）
//   - core_sysrst：MCU 主动复位输出，暂悬空
//   - core_clk = pll_mcu 300MHz；timer_clk = C0 100MHz；ahb_clk 由 MCU 输出（~150MHz）喂回从口
//=============================================================================
module ps_wrapper (
    input wire        I_core_clk,
    input wire        I_timer_clk,
    input wire        I_rst,

    output wire       O_core_sysrst,

    // ---- AHB master → 外部 ahb_status_slave ----
    output wire        O_ahb_clk,
    output wire [1:0]  O_htrans,
    output wire        O_hwrite,
    output wire [30:0] O_haddr,
    output wire [2:0]  O_hsize,
    output wire [2:0]  O_hburst,
    output wire [3:0]  O_hprot,
    output wire        O_hmastlock,
    output wire [31:0] O_hwdata,
    input  wire [31:0] I_hrdata,
    input  wire [1:0]  I_hresp,
    input  wire        I_hready,

    // ---- UART0 ----
    output wire       O_uart0_tx,
    input  wire        I_uart0_rx
);

    mcu u_MCU(
        .core_clk   ( I_core_clk    ),
        .timer_clk  ( I_timer_clk   ),
        .core_reset ( I_rst         ),
        .por_reset  ( I_rst         ),
        .nmi        ( 1'b0          ),
        .clic_irq   ( 23'd0         ),
        .core_sysrst( O_core_sysrst ),

        // AHB master → 外部从口
        .ahb_clk    ( O_ahb_clk     ),
        .htrans     ( O_htrans      ),
        .hwrite     ( O_hwrite      ),
        .haddr      ( O_haddr       ),
        .hsize      ( O_hsize       ),
        .hburst     ( O_hburst      ),
        .hprot      ( O_hprot       ),
        .hmastlock  ( O_hmastlock   ),
        .hwdata     ( O_hwdata      ),
        .hrdata     ( I_hrdata      ),
        .hresp      ( I_hresp       ),
        .hready     ( I_hready      ),

        // APB master 不用：时钟喂 timer_clk 保持域活；响应默认 ready=1/error=0
        .apb_clk    ( I_timer_clk   ),
        .apb_rst    ( I_rst         ),
        .paddr      (               ),
        .psel       (               ),
        .penable    (               ),
        .pwrite     (               ),
        .pwdata     (               ),
        .pstrobe    (               ),
        .pprot      (               ),
        .prdata     ( 32'd0         ),
        .pready     ( 1'b1          ),
        .pslverr    ( 1'b0          ),

        .uart0_tx   ( O_uart0_tx    ),
        .uart0_rx   ( I_uart0_rx    )
    );

endmodule
