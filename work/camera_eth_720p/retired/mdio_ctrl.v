// mdio_ctrl.v — MDIO 主机 + 上电自启状态机
//
// 协议：IEEE 802.3 clause 22
//   MDC ≤ 2.5 MHz（本模块 2.5 MHz）；MDIO 开漏双向
//   帧格式（MSB 先发，共 64 bit）：
//     PRE(32 个 1) + ST(01) + OP(00 读/01 写) + PHYAD(5) + REGAD(5) + TA(2) + DATA(16)
//   读：master 发完前 46 bit + 2 bit TA 后释放 MDIO，slave 在 DATA 16 bit 期间驱动
//   写：master 全程 64 bit 驱动
//
// 自启序列（rst_done 后自动跑）：
//   1. read reg 0x2 (PHYSID1) → physid1
//   2. read reg 0x3 (PHYSID2) → physid2
//   3. 若 physid1 != 0xFFFF（PHY 响应了）则 phy_id_valid=1
//   4. write reg 0x9 = 0x0300（1000M enable + RGMII TX delay；bit[8]=1=TX delay，
//      bit[9]=1=1000BASE-T 广告，bit[5]=0 不开 RX delay 留给 FPGA IDELAY 调）
//      注：YT8511 实际寄存器位含义见 datasheet §7.6，0x9 是 1000BASE-T 控制
//   5. 持续 poll reg 0x1 (BMSR)，link_up = bit[1]
//
// 状态 LED 输出：
//   physid1/physid2：PHY ID 寄存器原始值（M1.2 起可经 UART 打印）
//   phy_id_valid：PHY 响应（非 0xFFFF）
//   link_up：BMSR bit[1]
//   busy：MDIO 帧在跑

`timescale 1ns/1ps

module mdio_ctrl #(
    parameter CLK_FREQ_HZ = 50_000_000,
    parameter MDC_FREQ_HZ = 2_500_000
    // PHY_ADDR 不再固定：板上 strap 不可见，改成自动扫描 0..7
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        phy_rst_done,  // 来自 phy_rst 模块

    // 状态输出
    output reg  [15:0] physid1,
    output reg  [15:0] physid2,
    output reg         phy_id_valid,
    output reg         link_up,
    output reg         busy,
    output reg  [4:0]  phy_addr_cur,  // 当前扫描到的 PHY_ADDR（找到响应后锁定，0..31）
    output reg         mdio_phy_low,  // 诊断：master 释放 MDIO 期间检测到 MDIO=0（PHY 在驱动）
    output reg  [1:0]  ta_sample,     // 诊断：F_REL_TA_R 期间采样的 2 bit TA 值（bit47,bit46）

    // MDIO 物理接口
    output wire        mdc,
    inout  wire        mdio
);
    // =================================================================
    // MDC 生成：50 MHz ÷ 20 = 2.5 MHz（半周期 10 个 50MHz 周期 = 200 ns）
    // =================================================================
    localparam MDC_HALF = (CLK_FREQ_HZ / (2 * MDC_FREQ_HZ));   // = 10
    reg [7:0] mdc_cnt;
    reg       mdc_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mdc_cnt <= 8'd0;
            mdc_r   <= 1'b0;
        end else if (mdc_cnt >= MDC_HALF - 1) begin
            mdc_cnt <= 8'd0;
            mdc_r   <= ~mdc_r;
        end else begin
            mdc_cnt <= mdc_cnt + 1'b1;
        end
    end
    assign mdc = mdc_r;   // MDC 标准极性（反转实验后恢复，两种极性 ta 都=3，排除极性问题）

    // =================================================================
    // MDIO 三态：mdio_oe=1 时驱动 mdio_o；=0 时高阻读 mdio_i
    // =================================================================
    reg         mdio_o_r;
    reg         mdio_oe_r;
    assign mdio = mdio_oe_r ? mdio_o_r : 1'bz;
    wire        mdio_i = mdio;

    // 检测 MDC 边沿（标准极性：PHY 在 MDC 上升沿采样，master 在下降沿 setup）
    reg mdc_d1, mdc_d2;
    always @(posedge clk) begin
        mdc_d1 <= mdc_r;
        mdc_d2 <= mdc_d1;
    end
    wire mdc_rise = mdc_d1 & ~mdc_d2;   // MDC 上升沿（advance/采样）
    wire mdc_fall = ~mdc_d1 & mdc_d2;   // MDC 下降沿（setup）

    reg [4:0]  scan_phy_addr;   // 0..31 循环扫描，找到响应后锁定
    reg         cmd_start;
    reg         cmd_rw;          // 0=read, 1=write
    reg  [4:0]  cmd_regaddr;
    reg  [15:0] cmd_wdata;
    reg         cmd_done;
    reg  [15:0] cmd_rdata;
    reg         cmd_busy;

    reg [63:0]  frame;            // 整帧移位寄存器（MSB = frame[63]）
    reg [6:0]   bit_pos;         // 当前 bit 在帧中的位置（0..63）
    reg [2:0]   f_state;
    localparam F_IDLE        = 3'd0;
    localparam F_DRIVE_CMD   = 3'd1;  // 驱动 PRE+ST+OP+PHYAD+REGAD（46 bit, pos 0..45）
    localparam F_DRIVE_TA_W = 3'd2;  // 写：驱动 TA(10)，pos 0..1
    localparam F_DRIVE_DATA = 3'd3;  // 写：驱动 DATA(16)，pos 0..15
    localparam F_READ_DATA  = 3'd4;  // 读：采样 DATA(16)，pos 0..15
    localparam F_TAIL       = 3'd5;  // 1 bit 空闲（MDIO 高阻）
    localparam F_DONE       = 3'd6;
    localparam F_REL_TA_R   = 3'd7;  // 读：TA 2 bit 等待（master 已释放，slave 接管）

    // 帧组装（在 cmd_start 时锁存）
    always @(posedge clk) begin
        if (cmd_start) begin
            frame[63:32] <= 32'hFFFFFFFF;                  // PRE = 32 个 1
            frame[31:30] <= 2'b01;                          // ST
            frame[29:28] <= cmd_rw ? 2'b01 : 2'b00;        // OP（00 读, 01 写）
            frame[27:23] <= scan_phy_addr;             // PHYAD（5 位动态扫描 0..31）
            frame[22:18] <= cmd_regaddr;                   // REGAD
            // TA：写=10（master 全程驱动）；读=Z0（master 第一拍释放高阻，slave 第二拍驱动 0）
            // 简化处理：读时 master 在 F_DRIVE_CMD 末尾直接释放 OE，slave 在 TA 第二拍开始驱动
            frame[17:16] <= cmd_rw ? 2'b10 : 2'b00;
            if (cmd_rw) frame[15:0] <= cmd_wdata;          // DATA（仅写）
        end
    end

    // 帧执行（MDC 同步）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f_state   <= F_IDLE;
            bit_pos   <= 0;
            mdio_o_r  <= 1'b1;
            mdio_oe_r <= 1'b0;
            cmd_done  <= 1'b0;
            cmd_rdata <= 16'd0;
            cmd_busy  <= 1'b0;
        end else begin
            cmd_done <= 1'b0;
            case (f_state)
                F_IDLE: begin
                    cmd_busy <= 1'b0;
                    if (cmd_start) begin
                        cmd_busy  <= 1'b1;
                        f_state   <= F_DRIVE_CMD;
                        bit_pos   <= 0;
                        mdio_oe_r <= 1'b1;
                        mdio_o_r  <= 1'b1;     // PRE 起始
                    end
                end

                F_DRIVE_CMD: begin
                    // 在 MDC 下降沿 setup bit_pos 位（PHY 在下个上升沿采样）
                    if (mdc_fall && (bit_pos < 46)) begin
                        mdio_o_r <= frame[63 - bit_pos];
                    end
                    if (mdc_rise) begin
                        if (bit_pos == 45) begin
                            // 46 bit 驱动完毕（PRE+ST+OP+PHYAD+REGAD = bit 0..45）
                            if (cmd_rw) begin
                                // 写：进入 TA 驱动（TA = 2'b10，frame[17:16]）
                                f_state <= F_DRIVE_TA_W;
                                bit_pos <= 0;
                            end else begin
                                // 读：释放 MDIO，进入 TA 2 bit 等待（slave 接管）
                                mdio_oe_r <= 1'b0;
                                f_state   <= F_REL_TA_R;
                                bit_pos   <= 0;
                            end
                        end else begin
                            bit_pos <= bit_pos + 1;
                        end
                    end
                end

                F_DRIVE_TA_W: begin
                    // 写 TA = 2'b10：bit0=1, bit1=0（frame[17]=1, frame[16]=0）
                    //   每位用 mdc_fall setup，mdc_rise 让 PHY 采样
                    if (mdc_fall) begin
                        if (bit_pos == 0) mdio_o_r <= 1'b1;     // TA bit0=1
                        else               mdio_o_r <= 1'b0;    // TA bit1=0
                    end
                    if (mdc_rise) begin
                        if (bit_pos == 0) begin
                            bit_pos <= 1;
                        end else begin
                            // TA 完成，进入 DATA
                            f_state <= F_DRIVE_DATA;
                            bit_pos <= 0;
                        end
                    end
                end

                F_DRIVE_DATA: begin
                    // 写 DATA = 16 bit，frame[15:0]，MSB 先
                    //   每位用 mdc_fall setup，mdc_rise 让 PHY 采样
                    if (mdc_fall && (bit_pos < 16)) begin
                        mdio_o_r <= frame[15 - bit_pos];
                    end
                    if (mdc_rise) begin
                        if (bit_pos == 15) begin
                            f_state <= F_TAIL;
                            bit_pos <= 0;
                        end else begin
                            bit_pos <= bit_pos + 1;
                        end
                    end
                end

                F_REL_TA_R: begin
                    // TA: 2 bit 等待（master 已释放 MDIO，slave 在 bit 1 驱动 0）
                    //   采样 mdio_i 用于诊断 TA bit 值
                    if (mdc_rise) begin
                        ta_sample <= {ta_sample[0], mdio_i};  // 移位采样：bit_pos=0→bit46, bit_pos=1→bit47
                        if (bit_pos == 1) begin
                            f_state <= F_READ_DATA;
                            bit_pos <= 0;
                        end else begin
                            bit_pos <= bit_pos + 1;
                        end
                    end
                end

                F_READ_DATA: begin
                    // 采样 MDIO（slave 驱动），上升沿采样
                    if (mdc_rise) begin
                        cmd_rdata <= {cmd_rdata[14:0], mdio_i};
                        if (bit_pos == 15) begin
                            f_state <= F_TAIL;
                            bit_pos <= 0;
                        end else begin
                            bit_pos <= bit_pos + 1;
                        end
                    end
                end

                F_TAIL: begin
                    mdio_oe_r <= 1'b0;
                    if (mdc_rise) begin
                        f_state  <= F_DONE;
                    end
                end

                F_DONE: begin
                    cmd_done <= 1'b1;
                    cmd_busy <= 1'b0;
                    f_state  <= F_IDLE;
                end
            endcase
        end
    end

    // =================================================================
    // 上电自启顶层状态机
    // =================================================================
    localparam T_IDLE           = 4'd0;
    localparam T_READ_ID1_REQ   = 4'd1;
    localparam T_READ_ID1_WAIT  = 4'd2;
    localparam T_READ_ID2_REQ   = 4'd3;
    localparam T_READ_ID2_WAIT  = 4'd4;
    localparam T_CONFIG_REQ    = 4'd5;
    localparam T_CONFIG_WAIT    = 4'd6;
    localparam T_POLL_REQ       = 4'd7;
    localparam T_POLL_WAIT      = 4'd8;
    localparam T_POLL_DELAY     = 4'd9;   // poll 之间的间隔（10ms @ 50MHz = 500K cycles）

    reg [3:0]  t_state;
    reg [19:0] delay_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            t_state       <= T_IDLE;
            physid1      <= 16'd0;
            physid2      <= 16'd0;
            phy_id_valid <= 1'b0;
            link_up      <= 1'b0;
            cmd_start    <= 1'b0;
            cmd_rw       <= 1'b0;
            cmd_regaddr  <= 5'd0;
            cmd_wdata    <= 16'd0;
            delay_cnt    <= 20'd0;
            scan_phy_addr <= 5'd0;   // 从 PHY_ADDR=0 开始扫（0..31）
        end else begin
            cmd_start <= 1'b0;
            case (t_state)
                T_IDLE: begin
                    if (phy_rst_done) t_state <= T_READ_ID1_REQ;
                end
                T_READ_ID1_REQ: begin
                    cmd_start   <= 1'b1;
                    cmd_rw      <= 1'b0;          // read
                    cmd_regaddr <= 5'd2;           // PHYSID1
                    t_state     <= T_READ_ID1_WAIT;
                end
                T_READ_ID1_WAIT: begin
                    if (cmd_done) begin
                        physid1  <= cmd_rdata;
                        t_state  <= T_READ_ID2_REQ;
                    end
                end
                T_READ_ID2_REQ: begin
                    cmd_start   <= 1'b1;
                    cmd_rw      <= 1'b0;
                    cmd_regaddr <= 5'd3;           // PHYSID2
                    t_state     <= T_READ_ID2_WAIT;
                end
                T_READ_ID2_WAIT: begin
                    if (cmd_done) begin
                        physid2      <= cmd_rdata;
                        // PHY 响应判据：physid1 不是 0xFFFF（无 PHY 时 MDIO 上拉读全 1）
                        // 也不是 0x0000（异常）
                        phy_id_valid <= (physid1 != 16'hFFFF) && (physid1 != 16'h0000);
                        if ((physid1 != 16'hFFFF) && (physid1 != 16'h0000)) begin
                            // 找到响应的 PHY_ADDR，锁定 scan_phy_addr（不变），继续配置
                            t_state <= T_CONFIG_REQ;
                        end else begin
                            // 没响应，scan_phy_addr++（mod 32 自动溢出），换下一个地址试
                            scan_phy_addr <= scan_phy_addr + 5'd1;
                            t_state <= T_READ_ID1_REQ;
                        end
                    end
                end
                T_CONFIG_REQ: begin
                    cmd_start   <= 1'b1;
                    cmd_rw      <= 1'b1;           // write
                    cmd_regaddr <= 5'd9;           // 1000BASE-T control
                    cmd_wdata   <= 16'h0300;       // 1000M enable + RGMII TX delay
                    t_state     <= T_CONFIG_WAIT;
                end
                T_CONFIG_WAIT: begin
                    if (cmd_done) t_state <= T_POLL_REQ;
                end
                T_POLL_REQ: begin
                    cmd_start   <= 1'b1;
                    cmd_rw      <= 1'b0;
                    cmd_regaddr <= 5'd1;           // BMSR
                    t_state     <= T_POLL_WAIT;
                end
                T_POLL_WAIT: begin
                    if (cmd_done) begin
                        link_up   <= cmd_rdata[1]; // BMSR bit[1] = LINK_STATUS
                        t_state   <= T_POLL_DELAY;
                        delay_cnt <= 0;
                    end
                end
                T_POLL_DELAY: begin
                    if (delay_cnt >= 20'd500_000 - 1) begin  // 10ms @ 50MHz
                        t_state <= T_POLL_REQ;
                    end else begin
                        delay_cnt <= delay_cnt + 1;
                    end
                end
            endcase
        end
    end

    always @(posedge clk) begin
        busy <= cmd_busy | (t_state != T_IDLE);
        phy_addr_cur <= scan_phy_addr;
        // 诊断：master 释放 MDIO 期间（mdio_oe_r=0），如果 MDIO=0 说明 PHY 在驱动
        if (~mdio_oe_r & ~mdio_i) mdio_phy_low <= 1'b1;
    end
endmodule
