// m1_top.v — M1.1 顶层：PHY 复位 + MDIO 自启 + LED 状态指示
//
// 烧录后预期现象（M1.1 验收）：
//   LED[0] (D10) = phy_rst_done       复位序列完成（启动后约 7ms 亮）
//   LED[1] (E10) = phy_id_valid       PHY 响应了 MDIO 读 ID（亮则 MDIO 通路 OK）
//   LED[2] (C6)  = link_up            以太网链路 UP（PC 连上网线后会亮）
//   LED[3] (D6)  = ~0.74Hz 心跳        综合起得来 + 时钟 OK
//
// 不实现 RGMII 数据通路（M1.2 起做）；RGMII TX 引脚静态 0，RX 引脚悬空不读

`timescale 1ns/1ps

module m1_top (
    input  wire        I_sys_clk,        // C4 50MHz
    output wire [3:0]  O_led,            // D10/E10/C6/D6
    output wire        O_uart_tx,        // H1（M1.1 不用，保持空闲高）

    // RGMII（M1.1 只用 MDIO + RESET_N，其余不用）
    output wire        O_rgmii_txc,     // U9
    output wire        O_rgmii_tx_ctl,  // R10
    output wire [3:0]  O_rgmii_txd,     // R11/P11/T10/R12
    input  wire        I_rgmii_rxc,     // V2
    input  wire        I_rgmii_rx_ctl,  // N8
    input  wire [3:0]  I_rgmii_rxd,     // N9/T7/T8/T9
    output wire        O_rgmii_mdc,     // V9
    inout  wire        IO_rgmii_mdio,   // U10
    output wire        O_phy_rst_n      // V8
);
    // ------------------------------------------------------------------
    // 上电复位（M1.1 不引 PLL，用计数器产生 POR）
    // ------------------------------------------------------------------
    reg [19:0] por_cnt;
    reg        sys_rst_n;
    initial begin
        por_cnt   = 20'd0;
        sys_rst_n = 1'b0;
    end
    always @(posedge I_sys_clk) begin
        if (por_cnt < 20'hF_FFFF) begin
            por_cnt   <= por_cnt + 1'b1;
            sys_rst_n <= 1'b0;
        end else begin
            sys_rst_n <= 1'b1;
        end
    end

    // ------------------------------------------------------------------
    // PHY 复位序列器
    // ------------------------------------------------------------------
    wire phy_rst_done;
    phy_rst #(
        .RESET_TIME_MS (2),
        .POST_RST_MS   (5),
        .CLK_FREQ_HZ   (50_000_000)
    ) u_phy_rst (
        .clk        ( I_sys_clk       ),
        .rst_n      ( sys_rst_n       ),
        .phy_rst_n  ( O_phy_rst_n     ),
        .rst_done   ( phy_rst_done    )
    );

    // ------------------------------------------------------------------
    // MDIO 控制器（自启：read ID → config 0x9 → poll link）
    // ------------------------------------------------------------------
    wire [15:0] physid1, physid2;
    wire        phy_id_valid;
    wire        link_up;
    wire        mdio_busy;
    wire [4:0]  phy_addr_cur;
    wire        mdio_phy_low;
    wire [1:0]  ta_sample;

    mdio_ctrl #(
        .CLK_FREQ_HZ ( 50_000_000 ),
        .MDC_FREQ_HZ ( 1_000_000  )   // 慢化 MDC 到 1MHz（排除 2.5MHz 太快 PHY 跟不上）
    ) u_mdio (
        .clk           ( I_sys_clk     ),
        .rst_n         ( sys_rst_n     ),
        .phy_rst_done  ( 1'b0        ),  // 对照实验：停止 MDIO 帧发送，只发 MDC，看 PHY LED 是否变化
        .physid1       ( physid1      ),
        .physid2       ( physid2      ),
        .phy_id_valid  ( phy_id_valid ),
        .link_up       ( link_up      ),
        .busy          ( mdio_busy    ),
        .phy_addr_cur  ( phy_addr_cur ),
        .mdio_phy_low  ( mdio_phy_low ),
        .ta_sample     ( ta_sample    ),
        .mdc           ( O_rgmii_mdc  ),
        .mdio          ( IO_rgmii_mdio)
    );

    // ------------------------------------------------------------------
    // LED 状态指示 + 心跳 + MDC 诊断 + MDIO 电平诊断
    //   LED[0] (D10) = phy_rst_done
    //   LED[1] (E10) = mdio_low_flag（MDIO 线曾为 0；亮=有帧输出，不亮=MDIO 一直 1）
    //   LED[2] (C6)  = MDC 诊断：MDC 在跑则慢闪
    //   LED[3] (D6)  = 心跳
    // ------------------------------------------------------------------
    reg [25:0] hb_cnt;
    wire       hb;
    always @(posedge I_sys_clk) hb_cnt <= hb_cnt + 1'b1;
    assign hb = hb_cnt[25];   // ~0.745Hz

    // MDC 诊断：采样 O_rgmii_mdc 做上升沿计数
    reg [2:0] mdc_samp_d;
    always @(posedge I_sys_clk) mdc_samp_d <= {mdc_samp_d[1:0], O_rgmii_mdc};
    wire mdc_samp_rise = mdc_samp_d[1] & ~mdc_samp_d[2];
    reg [22:0] mdc_edge_cnt;
    always @(posedge I_sys_clk) begin
        if (mdc_samp_rise) mdc_edge_cnt <= mdc_edge_cnt + 1'b1;
    end

    // MDIO 电平诊断：采样 IO_rgmii_mdio 线，一旦检测到 0 就锁存 flag
    //   MDIO 帧里 ST=01 / OP=00 / PHYAD/REGAD 都有 0 bit，master 发帧时 MDIO 必有 0
    //   LED[1] 亮 = MDIO 线有 0 → master 在驱动帧
    //   LED[1] 不亮 = MDIO 一直 1 → master 根本没驱动 MDIO（mdio_oe_r/o_r bug 或物理上拉问题）
    reg [2:0] mdio_samp_d;
    always @(posedge I_sys_clk) mdio_samp_d <= {mdio_samp_d[1:0], IO_rgmii_mdio};
    wire mdio_is_low = (mdio_samp_d[1] == 1'b0);
    reg mdio_low_flag;
    always @(posedge I_sys_clk) begin
        if (mdio_is_low) mdio_low_flag <= 1'b1;   // 锁存，一旦为 0 就持续亮
    end

    assign O_led[0] = phy_rst_done;
    assign O_led[1] = mdio_low_flag;
    assign O_led[2] = mdc_edge_cnt[20];   // MDC=2.5MHz → ~1.2Hz 慢闪
    assign O_led[3] = hb;

    // ------------------------------------------------------------------
    // MDIO 状态串口打印（每 500ms 一行：id1/id2/valid/link/busy）
    //   串口：115200 8N1，PC 端用 COM4（FTDI USB-UART）接收
    // ------------------------------------------------------------------
    mdio_status_print #(
        .CLK_FREQ  ( 50_000_000 ),
        .BAUD      ( 115200     ),
        .REPEAT_MS ( 500        )
    ) u_status (
        .clk           ( I_sys_clk     ),
        .rst_n         ( sys_rst_n     ),
        .I_phy_addr_cur( phy_addr_cur  ),
        .I_physid1     ( physid1       ),
        .I_physid2     ( physid2       ),
        .I_phy_id_valid( phy_id_valid  ),
        .I_link_up     ( link_up       ),
        .I_mdio_busy   ( mdio_busy    ),
        .I_mdio_low    ( mdio_low_flag ),
        .I_mdio_phy_low( mdio_phy_low ),
        .I_ta_sample   ( ta_sample    ),
        .O_uart_tx     ( O_uart_tx    )
    );

    // ------------------------------------------------------------------
    // 未使用的 RGMII 数据引脚：M1.1 静态驱动，M1.2 起接 MAC
    // ------------------------------------------------------------------
    assign O_rgmii_txc    = 1'b0;
    assign O_rgmii_tx_ctl = 1'b0;
    assign O_rgmii_txd    = 4'b0000;

    // I_rgmii_rxc / I_rgmii_rx_ctl / I_rgmii_rxd 悬空（PHY 在 M1.1 不产生有效数据）

endmodule
