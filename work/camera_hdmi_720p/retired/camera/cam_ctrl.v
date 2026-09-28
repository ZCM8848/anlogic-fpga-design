`timescale 1ns / 1ps
//=============================================================================
// cam_ctrl.v — SC520CS 上电与 I2C 初始化控制（自研，M2）
//
// 流程：
//   1) 复位释放后 PWDNB(=O_cam_xshutdn) 保持低 2ms，再拉高
//   2) 拉高后等 8ms（手册 T4>=1ms / T5>=5ms 之上留裕量）
//   3) 读 SENSOR ID 高字节 0x3107：先用 7'h36；整笔 NAK 则换 7'h10 重试
//   4) 读 0x3108 低字节  -> D_id_pre
//   5) 依次写 ROM 中 165 条 {子地址,数据} 寄存器表
//   6) 等 20ms 稳定
//   7) 再读 0x3107/0x3108 -> D_id_post（原厂表加载后应为 9E4B）
//
// 错误码 D_err：0=全部正常；1=I2C 器件无应答；2=寄存器表写入 NAK；
//              4=ID 与预期不符（收到 EE4B 说明表未生效）
//=============================================================================
module cam_ctrl #(
    parameter CLK_FREQ      = 100_000_000,
    parameter PWR_LOW_MS    = 2,             // PWDNB 低电平时间
    parameter PWR_WAIT_MS   = 8,             // 上电后等待
    parameter TBL_SETTLE_MS = 20             // 寄存器表写完后等待
)(
    input  wire        clk,
    input  wire        rst_n,

    // 摄像头控制引脚
    output reg         O_cam_xshutdn,        // 1=正常工作 0=关断

    // I2C 主机接口
    output reg         I2C_go,
    output reg         I2C_rd,
    output reg  [6:0]  I2C_dev,
    output reg  [15:0] I2C_sub,
    output reg  [7:0]  I2C_wdata,
    input  wire [7:0]  I2C_rdata,
    input  wire        I2C_busy,
    input  wire        I2C_done,
    input  wire        I2C_ack_err,

    // 寄存器表 ROM
    output reg  [8:0]  ROM_idx,
    input  wire [23:0] ROM_data,

    // 状态输出（给 LED / 串口报告用）
    output reg  [15:0] D_id_pre,
    output reg  [15:0] D_id_post,
    output reg  [6:0]  D_dev,
    output reg  [8:0]  D_wr_cnt,
    output reg  [3:0]  D_err,
    output wire        O_i2c_ok,
    output wire        O_id_ok,
    output reg         D_busy
);

    localparam integer CYC_MS       = CLK_FREQ / 1000;
    localparam [31:0]  CNT_PWR_LOW  = PWR_LOW_MS    * CYC_MS;
    localparam [31:0]  CNT_PWR_WAIT = PWR_WAIT_MS   * CYC_MS;
    localparam [31:0]  CNT_SETTLE   = TBL_SETTLE_MS * CYC_MS;
    localparam [8:0]   TBL_LAST     = 9'd164;

    localparam [3:0] S_PWR_LOW   = 4'd0,
                     S_PWR_WAIT  = 4'd1,
                     S_IDR_H     = 4'd2,
                     S_IDR_L     = 4'd3,
                     S_TBL_ISSUE = 4'd4,
                     S_TBL_WR    = 4'd5,
                     S_TBL_WAIT  = 4'd6,
                     S_IDP_H     = 4'd7,
                     S_IDP_L     = 4'd8,
                     S_REPORT    = 4'd9;

    reg [3:0]  st;
    reg [31:0] cnt;
    reg [1:0]  asel;          // 0: 7'h36  1: 7'h10
    reg [2:0]  retry;

    wire [15:0] rom_sub  = ROM_data[23:8];
    wire [7:0]  rom_data = ROM_data[7:0];

    assign O_i2c_ok = (D_err == 4'd0);
    assign O_id_ok  = (D_id_post == 16'h9E4B);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st            <= S_PWR_LOW;
            cnt           <= 32'd0;
            asel          <= 2'd0;
            retry         <= 3'd0;
            O_cam_xshutdn <= 1'b0;
            I2C_go        <= 1'b0;
            I2C_rd        <= 1'b0;
            I2C_dev       <= 7'h36;
            I2C_sub       <= 16'h3107;
            I2C_wdata     <= 8'h00;
            ROM_idx       <= 9'd0;
            D_id_pre      <= 16'h0000;
            D_id_post     <= 16'h0000;
            D_dev         <= 7'h36;
            D_wr_cnt      <= 9'd0;
            D_err         <= 4'd0;
            D_busy        <= 1'b1;
        end else begin
            I2C_go  <= 1'b0;                  // 默认单周期脉冲
            D_dev   <= (asel == 2'd0) ? 7'h36 : 7'h10;

            case (st)

            // ---- 1) PWDNB 低 2ms ----
            S_PWR_LOW: begin
                O_cam_xshutdn <= 1'b0;
                if (cnt >= CNT_PWR_LOW) begin
                    cnt <= 32'd0;
                    st  <= S_PWR_WAIT;
                end else begin
                    cnt <= cnt + 32'd1;
                end
            end

            // ---- 2) PWDNB 拉高，等 8ms ----
            S_PWR_WAIT: begin
                O_cam_xshutdn <= 1'b1;
                if (cnt >= CNT_PWR_WAIT) begin
                    cnt      <= 32'd0;
                    I2C_rd   <= 1'b1;
                    I2C_dev  <= (asel == 2'd0) ? 7'h36 : 7'h10;
                    I2C_sub  <= 16'h3107;
                    I2C_go   <= 1'b1;
                    st       <= S_IDR_H;
                end else begin
                    cnt <= cnt + 32'd1;
                end
            end

            // ---- 3) 读 ID 高字节 ----
            S_IDR_H: begin
                if (I2C_done) begin
                    if (I2C_ack_err) begin
                        if (asel == 2'd0 && retry < 3'd3) begin
                            // 换 7'h10 再试
                            asel    <= 2'd1;
                            retry   <= retry + 3'd1;
                            I2C_rd  <= 1'b1;
                            I2C_dev <= 7'h10;
                            I2C_sub <= 16'h3107;
                            I2C_go  <= 1'b1;
                            st      <= S_IDR_H;
                        end else begin
                            D_err <= 4'd1;
                            st    <= S_REPORT;
                        end
                    end else begin
                        D_id_pre[15:8] <= I2C_rdata;
                        I2C_rd  <= 1'b1;
                        I2C_sub <= 16'h3108;
                        I2C_go  <= 1'b1;
                        st      <= S_IDR_L;
                    end
                end
            end

            // ---- 4) 读 ID 低字节，开始写寄存器表 ----
            S_IDR_L: begin
                if (I2C_done) begin
                    if (I2C_ack_err) begin
                        D_err <= 4'd1;
                        st    <= S_REPORT;
                    end else begin
                        D_id_pre[7:0] <= I2C_rdata;
                        ROM_idx       <= 9'd0;
                        st            <= S_TBL_ISSUE;
                    end
                end
            end

            // ---- 5a) 取 ROM 中下一条 {子地址,数据} 并下发 ----
            S_TBL_ISSUE: begin
                I2C_rd    <= 1'b0;
                I2C_sub   <= rom_sub;
                I2C_wdata <= rom_data;
                I2C_go    <= 1'b1;
                st        <= S_TBL_WR;
            end

            // ---- 5b) 逐条写寄存器表 ----
            S_TBL_WR: begin
                if (I2C_done) begin
                    if (I2C_ack_err) begin
                        D_err <= 4'd2;
                        st    <= S_REPORT;
                    end else begin
                        D_wr_cnt <= D_wr_cnt + 9'd1;
                        if (ROM_idx >= TBL_LAST) begin
                            cnt <= 32'd0;
                            st  <= S_TBL_WAIT;
                        end else begin
                            ROM_idx <= ROM_idx + 9'd1;
                            st      <= S_TBL_ISSUE;
                        end
                    end
                end
            end

            // ---- 6) 等 20ms ----
            S_TBL_WAIT: begin
                if (cnt >= CNT_SETTLE) begin
                    cnt     <= 32'd0;
                    I2C_rd  <= 1'b1;
                    I2C_sub <= 16'h3107;
                    I2C_go  <= 1'b1;
                    st      <= S_IDP_H;
                end else begin
                    cnt <= cnt + 32'd1;
                end
            end

            // ---- 7) 复读 ID ----
            S_IDP_H: begin
                if (I2C_done) begin
                    if (I2C_ack_err) begin
                        D_err <= 4'd1;
                        st    <= S_REPORT;
                    end else begin
                        D_id_post[15:8] <= I2C_rdata;
                        I2C_rd  <= 1'b1;
                        I2C_sub <= 16'h3108;
                        I2C_go  <= 1'b1;
                        st      <= S_IDP_L;
                    end
                end
            end

            S_IDP_L: begin
                if (I2C_done) begin
                    if (I2C_ack_err) begin
                        D_err <= 4'd1;
                    end else begin
                        D_id_post[7:0] <= I2C_rdata;
                        D_err <= ({D_id_post[15:8], I2C_rdata} == 16'h9E4B) ? 4'd0 : 4'd4;
                    end
                    st <= S_REPORT;
                end
            end

            // ---- 8) 结束，保持状态 ----
            S_REPORT: begin
                D_busy <= 1'b0;
                st     <= S_REPORT;
            end

            default: st <= S_REPORT;
            endcase
        end
    end

endmodule
