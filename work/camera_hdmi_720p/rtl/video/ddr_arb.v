/*******************************************************************************
 * camera_hdmi_720p — DDR 应用口仲裁器（自研，M5-②）
 *
 * 单口仲裁：读（显示预取）优先、写（帧缓存排空）次之；同一时刻只发一条命令。
 * 协议（IPUG035 表 3-5 + 厂商 lab 用法，M5-② 计划已三方核对）：
 *   · 单拍命令：一次 en = 1×128bit 字；cmd[0]：1=读、0=写；
 *   · 写数据同拍给出（wdf_wren=1、wdf_end=1、mask=0 表示全写）；
 *   · 命令被接收的判据 = 采样到 (I_mc_rdy & I_mc_wdf_rdy) 同拍为 1（该拍即
 *     AXI valid/ready 同拍）—— 与厂商 mc_to_user_interface 完全一致的用法，
 *     但本设计把命令保持到「采样到就绪」为止再撤销（比厂商 1 拍脉冲更稳）。
 *   · 读响应单拍 1 个 128bit 字、按序返回（paxi_rready 在包装层恒 1）。
 *   · 命令被接收后插入 1 拍冷却（S_cd）：主机在「接收后的下一拍」才看到 gnt 并
 *     更新自己的计数/地址，若冷却前重新采样会拿到同一地址 → 重复读、字序错位
 *     （M5-② 仿真抓到的真实缺陷）。
 *
 * 读看门狗（金丝雀，正常永不触发）：有未回收读且 4096 拍内既无新读被接收、
 *   也无响应 → 判定接口异常：O_err 脉冲（fb_ctrl 计 ER）+ O_rd_flush 拉高；
 *   冲刷期间不发命令，等连续 4096 拍无响应（吸收在途/迟到响应）后清在途计数、
 *   撤销 flush（fb_rd 收到后从当前行第 0 字重取，读幂等）。
 ******************************************************************************/
`timescale 1ns / 1ps

module ddr_arb (
    input  wire         clk,           // 用户域 S_ddr_clk
    input  wire         rst_n,

    // ---- 写主机（fb_wr 排空引擎）----
    input  wire         I_wr_req,
    input  wire [24:0]  I_wr_addr,
    input  wire [127:0] I_wr_data,
    output reg          O_wr_gnt,

    // ---- 读主机（fb_rd 预取引擎）----
    input  wire         I_rd_req,
    input  wire [24:0]  I_rd_addr,
    output reg          O_rd_gnt,

    // ---- 应用口（→ ph1p35_324_ddr_wrapper）----
    output reg  [24:0]  O_mc_addr,
    output reg  [2:0]   O_mc_cmd,
    output reg          O_mc_en,
    output reg  [127:0] O_mc_wdf_data,
    output reg          O_mc_wdf_end,
    output reg  [15:0]  O_mc_wdf_mask,
    output reg          O_mc_wdf_wren,
    input  wire         I_mc_rdy,      // O_mc_app_rdy
    input  wire         I_mc_wdf_rdy,  // O_mc_app_wdf_rdy
    input  wire [127:0] I_mc_rd_data,
    input  wire         I_mc_rd_valid,

    // ---- 响应直通（fb_rd）与异常 ----
    output wire [127:0] O_rd_data,
    output wire         O_rd_dvalid,
    output reg          O_rd_flush,
    output reg          O_err
);

    localparam ST_IDLE = 2'd0;
    localparam ST_RD   = 2'd1;
    localparam ST_WR   = 2'd2;
    localparam ST_FL   = 2'd3;

    reg  [1:0]  S_st;
    reg         S_cd;          // 接受后 1 拍冷却：等主机计数/地址更新，防重复采样
    reg  [7:0]  S_out;         // 未回收读计数（诊断/看门狗用）
    reg  [15:0] S_wd_cnt;      // 距上次读活动（接收/响应）的拍数
    reg  [15:0] S_fl_cnt;      // 冲刷静默计时

    wire        S_rd_acc  = (S_st == ST_RD) && I_mc_rdy && I_mc_wdf_rdy;  // 本拍读被接收
    wire        S_out_dec = I_mc_rd_valid && (S_out != 8'd0);

    always @(posedge clk) begin
        if (!rst_n) begin
            S_st       <= ST_IDLE;
            S_cd       <= 1'b0;
            S_out      <= 8'd0;
            S_wd_cnt   <= 16'd0;
            S_fl_cnt   <= 16'd0;
            O_wr_gnt   <= 1'b0;
            O_rd_gnt   <= 1'b0;
            O_mc_en    <= 1'b0;
            O_mc_wdf_wren <= 1'b0;
            O_mc_addr  <= 25'd0;
            O_mc_cmd   <= 3'd0;
            O_mc_wdf_data <= 128'd0;
            O_mc_wdf_end  <= 1'b0;
            O_mc_wdf_mask <= 16'd0;
            O_rd_flush <= 1'b0;
            O_err      <= 1'b0;
        end else begin
            O_wr_gnt <= 1'b0;
            O_rd_gnt <= 1'b0;
            O_err    <= 1'b0;

            // 看门狗计时
            if (S_rd_acc || I_mc_rd_valid) S_wd_cnt <= 16'd0;
            else if (S_wd_cnt != 16'hFFFF) S_wd_cnt <= S_wd_cnt + 16'd1;

            case (S_st)
                ST_IDLE: begin
                    O_mc_en       <= 1'b0;
                    O_mc_wdf_wren <= 1'b0;
                    if (S_cd) begin
                        S_cd <= 1'b0;      // 冷却拍：主机此刻才看到 gnt 并更新计数
                    end else if (I_rd_req) begin     // 读优先
                        O_mc_addr     <= I_rd_addr;
                        O_mc_cmd      <= 3'b001;        // cmd[0]=1：读
                        O_mc_en       <= 1'b1;
                        O_mc_wdf_wren <= 1'b0;
                        O_mc_wdf_end  <= 1'b0;
                        O_mc_wdf_mask <= 16'd0;
                        O_mc_wdf_data <= 128'd0;
                        S_st          <= ST_RD;
                    end else if (I_wr_req) begin
                        O_mc_addr     <= I_wr_addr;
                        O_mc_cmd      <= 3'b000;        // cmd[0]=0：写
                        O_mc_en       <= 1'b1;
                        O_mc_wdf_wren <= 1'b1;
                        O_mc_wdf_end  <= 1'b1;          // 单拍 128bit：本拍即末拍
                        O_mc_wdf_mask <= 16'd0;         // 全写
                        O_mc_wdf_data <= I_wr_data;
                        S_st          <= ST_WR;
                    end
                end
                ST_RD: begin
                    // 命令/地址保持到采样到就绪（valid/ready 同拍即被接收）
                    if (I_mc_rdy && I_mc_wdf_rdy) begin
                        O_mc_en  <= 1'b0;
                        O_rd_gnt <= 1'b1;
                        S_cd     <= 1'b1;
                        S_st     <= ST_IDLE;
                    end
                end
                ST_WR: begin
                    if (I_mc_rdy && I_mc_wdf_rdy) begin
                        O_mc_en       <= 1'b0;
                        O_mc_wdf_wren <= 1'b0;
                        O_wr_gnt      <= 1'b1;
                        S_cd          <= 1'b1;
                        S_st          <= ST_IDLE;
                    end
                end
                default: begin                      // ST_FL：冲刷（吸收在途响应）
                    O_mc_en       <= 1'b0;
                    O_mc_wdf_wren <= 1'b0;
                    if (I_mc_rd_valid) begin
                        S_fl_cnt <= 16'd0;
                    end else if (S_fl_cnt == 16'd4095) begin
                        S_fl_cnt   <= 16'd0;
                        S_out      <= 8'd0;
                        O_rd_flush <= 1'b0;
                        S_st       <= ST_IDLE;
                    end else begin
                        S_fl_cnt <= S_fl_cnt + 16'd1;
                    end
                end
            endcase

            // 在途读计数（同时收发 → 不变）
            if (S_rd_acc && !S_out_dec)      S_out <= S_out + 8'd1;
            else if (!S_rd_acc && S_out_dec) S_out <= S_out - 8'd1;

            // 看门狗触发
            if ((S_out != 8'd0) && (S_wd_cnt == 16'd4095) && (S_st != ST_FL)) begin
                O_err      <= 1'b1;
                O_rd_flush <= 1'b1;
                S_fl_cnt   <= 16'd0;
                S_st       <= ST_FL;
            end
        end
    end

    assign O_rd_data   = I_mc_rd_data;
    assign O_rd_dvalid = I_mc_rd_valid;

endmodule
