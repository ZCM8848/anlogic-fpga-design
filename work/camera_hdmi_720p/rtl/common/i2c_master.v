`timescale 1ns / 1ps
//=============================================================================
// i2c_master.v — 单主机 I2C 控制器（自研，M2）
//
// 功能：
//   - 单字节写：START + dev|W + sub[15:8] + sub[7:0] + data + STOP
//   - 单字节读：START + dev|W + sub[15:8] + sub[7:0] + Sr + dev|R + data + NACK + STOP
//   - 开漏输出（只拉低/释放），依赖总线外部上拉（模组 4.7K + FPGA 引脚 PULLUP）
//   - 不处理时钟拉伸（SC520CS 不拉低 SCL）
//
// 接口：I_go 单周期脉冲启动；O_busy 期间忽略新的 I_go；O_done 单周期脉冲；
//       O_ack_err=1 表示某字节未收到从机应答（立即 STOP 并结束）。
//
// 时序：每相位 = QUART 个 clk；SCL 低半周期 = qi 0/1，高半周期 = 2/3；
//       数据在 SCL 低电平期间变化。RSTART 为 5 相位：先拉低 SCL 让双方安全
//       释放 SDA，再抬 SCL、拉低 SDA 形成重复起始（否则 SDA 上升沿会被从机
//       误判为 STOP）。
//=============================================================================
module i2c_master #(
    parameter CLK_FREQ = 100_000_000,
    parameter SCL_FREQ = 100_000
)(
    input  wire        clk,
    input  wire        rst_n,

    // 命令接口
    input  wire        I_go,        // 单周期启动脉冲
    input  wire        I_rd,        // 1=读，0=写
    input  wire [6:0]  I_dev,       // 7 位从机地址
    input  wire [15:0] I_sub,       // 16 位寄存器子地址
    input  wire [7:0]  I_wdata,     // 写数据
    output reg  [7:0]  O_rdata,     // 读数据
    output reg         O_busy,
    output reg         O_done,      // 单周期完成脉冲
    output reg         O_ack_err,   // 从机无应答

    // I2C 引脚（开漏：1=拉低，0=释放）
    output reg         O_scl_low,
    output reg         O_sda_low,
    input  wire        I_sda_in
);

    localparam integer QUART = CLK_FREQ / (SCL_FREQ * 4);  // 每相位 clk 数

    localparam [3:0] ST_IDLE  = 4'd0,
                     ST_START = 4'd1,
                     ST_TX    = 4'd2,
                     ST_ACK   = 4'd3,
                     ST_RX    = 4'd4,
                     ST_NACK  = 4'd5,
                     ST_STOP  = 4'd6,
                     ST_RSTAR = 4'd7;

    reg [3:0]  st;
    reg [2:0]  qi;      // 相位计数（ST_RSTAR 用 0..4，其余 0..3）
    reg [15:0] q;       // 相位内计数
    reg [2:0]  bit;     // 位计数 0..7
    reg [2:0]  seq;     // 序列：0=START 1=dev|W 2=subhi 3=sublo 4=wdata/Sr 5=dev|R 6=RX/STOP 7=NACK 8=STOP
    reg [7:0]  sh;      // 收发移位寄存器（MSB 先）
    reg [6:0]  dev;
    reg [15:0] sub;
    reg [7:0]  wdata;
    reg        rd;

    wire        qend  = (q == (QUART - 1));
    wire [2:0]  qlast = (st == ST_RSTAR) ? 3'd4 : 3'd3;

    // ------------------------------------------------------------------ 输出驱动（开漏）
    always @(*) begin
        O_scl_low = 1'b0;
        O_sda_low = 1'b0;
        case (st)
            ST_START: begin                        // qi0: SDA 下降(SCL 高)=START；qi1+ : SCL 低
                O_sda_low = 1'b1;
                O_scl_low = (qi >= 3'd1);
            end
            ST_RSTAR: begin                        // qi0/1: SCL 低、SDA 释放；qi2: SCL 高；qi3: SDA 下降=Sr；qi4: SCL 低
                O_scl_low = (qi <= 3'd1) || (qi == 3'd4);
                O_sda_low = (qi == 3'd3);
            end
            ST_TX: begin                           // 低半周期 qi0/1，高半 qi2/3；数据 = sh[7]
                O_scl_low = (qi < 3'd2);
                O_sda_low = ~sh[7];
            end
            ST_ACK: begin                          // 主机释放 SDA，采样从机应答
                O_scl_low = (qi < 3'd2);
                O_sda_low = 1'b0;
            end
            ST_RX: begin                           // 主机释放 SDA 接收
                O_scl_low = (qi < 3'd2);
                O_sda_low = 1'b0;
            end
            ST_NACK: begin                         // 主机发 NACK（SDA 保持高）
                O_scl_low = (qi < 3'd2);
                O_sda_low = 1'b0;
            end
            ST_STOP: begin                         // qi0: SCL 低；qi1: SDA 低；qi2: SCL 高；qi3: SDA 释放=STOP
                O_scl_low = (qi < 3'd2);
                O_sda_low = (qi >= 3'd1) && (qi < 3'd3);
            end
            default: begin
                O_scl_low = 1'b0;
                O_sda_low = 1'b0;
            end
        endcase
    end

    // ------------------------------------------------------------------ 主状态机
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st        <= ST_IDLE;
            qi        <= 3'd0;
            q         <= 16'd0;
            bit       <= 3'd0;
            seq       <= 3'd0;
            sh        <= 8'h00;
            dev       <= 7'd0;
            sub       <= 16'd0;
            wdata     <= 8'd0;
            rd        <= 1'b0;
            O_rdata   <= 8'h00;
            O_busy    <= 1'b0;
            O_done    <= 1'b0;
            O_ack_err <= 1'b0;
        end else begin
            O_done <= 1'b0;

            if (st == ST_IDLE) begin
                if (I_go) begin
                    dev       <= I_dev;
                    sub       <= I_sub;
                    wdata     <= I_wdata;
                    rd        <= I_rd;
                    seq       <= 3'd0;
                    bit       <= 3'd0;
                    qi        <= 3'd0;
                    q         <= 16'd0;
                    O_busy    <= 1'b1;
                    O_ack_err <= 1'b0;
                    st        <= ST_START;
                end
            end else if (!qend) begin
                q <= q + 1'b1;
            end else begin
                q <= 16'd0;

                // 接收采样：高半周期中点（RX 的 qlast=3，qi==2 非末相位）
                if ((st == ST_RX) && (qi == 3'd2))
                    sh <= {sh[6:0], I_sda_in};

                if (qi == qlast) begin
                    qi <= 3'd0;
                    case (st)
                        ST_START: begin
                            st  <= ST_TX;
                            seq <= 3'd1;
                            sh  <= {dev, 1'b0};
                            bit <= 3'd0;
                        end
                        ST_RSTAR: begin
                            st  <= ST_TX;
                            sh  <= {dev, 1'b1};
                            bit <= 3'd0;
                        end
                        ST_TX: begin
                            if (bit == 3'd7)
                                st <= ST_ACK;
                            else begin
                                bit <= bit + 1'b1;
                                sh  <= {sh[6:0], 1'b0};
                            end
                        end
                        ST_ACK: begin
                            if (I_sda_in) begin                  // 无应答：中止
                                O_ack_err <= 1'b1;
                                st        <= ST_STOP;
                            end else begin
                                case (seq)
                                    3'd1: begin seq <= 3'd2; sh  <= sub[15:8]; bit <= 3'd0; st <= ST_TX; end
                                    3'd2: begin seq <= 3'd3; sh  <= sub[7:0];  bit <= 3'd0; st <= ST_TX; end
                                    3'd3: begin
                                        if (rd) begin
                                            seq <= 3'd5;
                                            st  <= ST_RSTAR;
                                        end else begin
                                            seq <= 3'd4;
                                            sh  <= wdata;
                                            bit <= 3'd0;
                                            st  <= ST_TX;
                                        end
                                    end
                                    3'd4: begin seq <= 3'd6; st <= ST_STOP; end
                                    3'd5: begin seq <= 3'd6; st <= ST_RX; bit <= 3'd0; sh <= 8'h00; end
                                    default: st <= ST_STOP;
                                endcase
                            end
                        end
                        ST_RX: begin
                            if (bit == 3'd7) begin
                                O_rdata <= sh;                    // sh 已含完整 8 位
                                st      <= ST_NACK;
                            end else
                                bit <= bit + 1'b1;
                        end
                        ST_NACK: begin
                            seq <= 3'd0;   // 等效原 3'd8（3 位放不下、被静默截断成 0）；显式写 0 消除 HDL-5007
                            st  <= ST_STOP;
                        end
                        ST_STOP: begin                            // 完成：释放总线
                            O_busy <= 1'b0;
                            O_done <= 1'b1;
                            st     <= ST_IDLE;
                        end
                        default: st <= ST_IDLE;
                    endcase
                end else begin
                    qi <= qi + 1'b1;
                end
            end
        end
    end

endmodule
