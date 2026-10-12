`timescale 1ns / 1ps
//=============================================================================
// apb_status_slave.v — APB 从口：把板级状态暴露给 RISC-V MCU（Phase 1）
// ============================================================
// 背景：原 status_report.v 在 fabric 里用字符串 FSM + uart_tx 把状态
//   打印到串口；本次迁移把"拼串 + 串口"搬到 MCU，fabric 只保留一个
//   APB 从口，MCU 经 APB 读状态寄存器、写心跳寄存器即可。
//
// APB 协议（与 ps_wrapper.v 输出一致，AMBA APB）：
//   setup : psel=1, penable=0, paddr/pwrite/pwdata 有效
//   access: penable=1 → 从口采样地址/数据，读时驱动 prdata，写时落寄存器
//   本从口恒就绪：pready=1, pslverr=0。
//
// 寄存器映射（paddr 字节地址；按字对齐，paddr[6:2] 选 32 个 32bit 槽）：
//   ---- 读（fabric→MCU，只读）----
//   0x00 CAM_REG   [31:16]=cam_id[15:0]
//                  [15]=cam_id_ok [14]=cam_i2c_err [13]=cam_cfg_done
//                  [12]=ddr_rdy   [11]=sw4         [10]=sw3
//                  [ 9]=cv_on     [ 5:0]=blob_cnt[5:0]
//   0x04 CV_REG    [31:24]=bin_thr[7:0]
//                  [21:11]=run_cnt[10:0]
//                  [   10]=ccl_busy   [    9]=run_overflow
//                  [ 7: 0]=frame_cnt[7:0]（低 8 位，方便 MCU 一眼看出帧在跑）
//   0x08 FRAME_REG [31:0]=frame_cnt（32 位全量帧计数，vsync 累加）
//   0x0C VER_REG   [31:0]=32'h4D435601 ("MCV1") 从口版本/魔术，供 MCU 自检
//   ---- 写（MCU→fabric）----
//   0x10 HEARTBEAT MCU 写递增值；O_heartbeat 回暴露给 fabric（status/LED 自证 MCU 活着）
//   0x14 SCRATCH   通用调试写寄存器
//   0x18..0x3C     预留 Phase 2/3（counter / otsu_thr / track 表 / det 表）
//
// 时钟域：本模块跑在 APB 域（= S_100m_clk）。cam/ddr/sw/cv 等状态输入
//   约定由顶层已 2FF 同步到 100M 域（与原 status_report 的输入一致）。
//   I_vsync 是像素域信号，本模块内部 2FF 同步到 APB 域后用于帧计数。
//=============================================================================
module apb_status_slave #(
    parameter [31:0] VER = 32'h4D435601   // "MCV1"
)(
    input  wire        I_apb_clk,
    input  wire        I_apb_rst_n,

    // ---- APB 主机（MCU 侧）信号 ----
    input  wire [19:0] I_paddr,
    input  wire        I_psel,
    input  wire        I_penable,
    input  wire        I_pwrite,
    input  wire [31:0] I_pwdata,
    input  wire [3:0]  I_pstrobe,
    input  wire [2:0]  I_pprot,        // 保留，不处理
    output wire [31:0] O_prdata,   // = S_prdata（reg 在 always 里驱动，见下）
    output wire        O_pready,
    output wire        O_pslverr,

    // ---- 状态输入（顶层已同步到 100M 域）----
    input  wire [15:0] I_cam_id,
    input  wire        I_cam_id_ok,
    input  wire        I_cam_i2c_err,
    input  wire        I_cam_cfg_done,
    input  wire        I_ddr_rdy,
    input  wire        I_sw4,
    input  wire        I_sw3,
    input  wire        I_cv_on,
    input  wire [5:0]  I_blob_cnt,
    input  wire [7:0]  I_bin_thr,
    input  wire [10:0] I_run_cnt,
    input  wire        I_ccl_busy,
    input  wire        I_run_overflow,

    // ---- 帧同步（像素域，内部 2FF 同步到 APB 域）----
    input  wire        I_vsync,

    // ---- MCU 写回暴露 ----
    output wire [31:0] O_heartbeat,
    output wire [31:0] O_scratch,
    output wire [31:0] O_frame_cnt
);

    // ------------------------------------------------------------------
    // vsync 跨域同步（像素域 → APB 域）+ 上升沿 + 32 位帧计数
    // ------------------------------------------------------------------
    reg [1:0] S_vs_sync;
    reg       S_vs_d;
    reg [31:0] S_frame_cnt;
    wire       vs_rise = S_vs_sync[1] & ~S_vs_d;

    always @(posedge I_apb_clk or negedge I_apb_rst_n) begin
        if (!I_apb_rst_n) begin
            S_vs_sync   <= 2'b00;
            S_vs_d      <= 1'b0;
            S_frame_cnt <= 32'd0;
        end else begin
            S_vs_sync <= {S_vs_sync[0], I_vsync};
            S_vs_d    <= S_vs_sync[1];
            if (vs_rise) S_frame_cnt <= S_frame_cnt + 1'b1;
        end
    end

    assign O_frame_cnt = S_frame_cnt;

    // ------------------------------------------------------------------
    // MCU 可写寄存器：HEARTBEAT / SCRATCH
    //   APB 写在 access 相（psel & penable & pwrite & pready）落寄存器；
    //   按 I_pstrobe 做字节使能（每字节独立写入）。
    // ------------------------------------------------------------------
    reg [31:0] S_heartbeat;
    reg [31:0] S_scratch;

    assign O_heartbeat = S_heartbeat;
    assign O_scratch  = S_scratch;

    wire wr_access = I_psel & I_penable & I_pwrite;   // 写访问窗口（pready 恒 1）
    wire [4:0] widx = I_paddr[6:2];                   // 32 个字槽

    // 字节使能：pstrobe[n] 管字节 n
    function [31:0] f_merge(input [31:0] oldv, input [31:0] newv, input [3:0] strb);
        integer k;
        reg [31:0] r;
        begin
            r = oldv;
            for (k = 0; k < 4; k = k + 1)
                if (strb[k]) r[k*8 +: 8] = newv[k*8 +: 8];
            f_merge = r;
        end
    endfunction

    always @(posedge I_apb_clk or negedge I_apb_rst_n) begin
        if (!I_apb_rst_n) begin
            S_heartbeat <= 32'd0;
            S_scratch   <= 32'd0;
        end else if (wr_access) begin
            case (widx)
                5'h04: S_heartbeat <= f_merge(S_heartbeat, I_pwdata, I_pstrobe); // 0x10
                5'h05: S_scratch   <= f_merge(S_scratch,   I_pwdata, I_pstrobe); // 0x14
                default: ; // 其它写地址：忽略
            endcase
        end
    end

    // ------------------------------------------------------------------
    // 读数据：组合 mux（状态量少，时序裕足）。
    //   按 APB：setup 相 psel&!penable&!pwrite 时地址稳定，下一拍 access
    //   相 penable=1 期间 prdata 须有效。组合 mux 在 setup 即已稳定，
    //   access 期间自然有效。对 O_prdata 寄存一拍以切断长组合路径、
    //   并让读时序更稳（MCU 在 access 相采到）。
    // ------------------------------------------------------------------
    reg [31:0] S_prdata;

    // 各只读寄存器字
    wire [31:0] CAM_REG = {I_cam_id, I_cam_id_ok, I_cam_i2c_err, I_cam_cfg_done,
                           I_ddr_rdy, I_sw4, I_sw3, I_cv_on, 3'b0, I_blob_cnt};
    wire [31:0] CV_REG  = {I_bin_thr, 1'b0, I_run_cnt, I_ccl_busy, I_run_overflow, 1'b0, S_frame_cnt[7:0]};
    wire [31:0] FRAME_REG = S_frame_cnt;
    wire [31:0] VER_REG  = VER;

    always @(posedge I_apb_clk or negedge I_apb_rst_n) begin
        if (!I_apb_rst_n)
            S_prdata <= 32'd0;
        else if (I_psel && !I_pwrite)
            S_prdata <= rdata_mux(widx);
    end

    function [31:0] rdata_mux(input [4:0] idx);
        begin
            case (idx)
                5'h00: rdata_mux = CAM_REG;
                5'h01: rdata_mux = CV_REG;
                5'h02: rdata_mux = FRAME_REG;
                5'h03: rdata_mux = VER_REG;
                5'h04: rdata_mux = S_heartbeat;   // 回读
                5'h05: rdata_mux = S_scratch;     // 回读
                default: rdata_mux = 32'h0;
            endcase
        end
    endfunction

    assign O_prdata  = S_prdata;
    assign O_pready  = 1'b1;     // 恒就绪
    assign O_pslverr = 1'b0;    // 无错误

endmodule
