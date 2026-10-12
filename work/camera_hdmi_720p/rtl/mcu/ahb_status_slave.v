`timescale 1ns / 1ps
//=============================================================================
// ahb_status_slave.v — AHB-Lite 从口：把板级状态暴露给 RISC-V MCU（经 AHB 窗口 0x80000000）
// ============================================================
// 背景：fabric APB 窗口基址在文档里找不到；fabric AHB 窗口 = 0x80000000（AHBDemo 验证）。
//   故把状态从口从 APB 改到 AHB。MCU 的 AHB master 端口接本从口；APB master 改悬空。
//
// AHB-Lite 协议（零等待，hreadyout 恒 1）：
//   地址相（cycle N）：haddr/htrans/hwrite/hsize 有效；从口采样、锁存。
//   数据相（cycle N+1）：读→hrdata = mux(锁存地址对应的寄存器)；写→hwdata 写入该寄存器。
//   本从口为 AHB master 端口上唯一从口，须对所有传输 hready=1/hresp=OKAY（否则总线挂）。
//   地址解码：haddr[6:2] 选 32 个 32bit 槽（与 apb_status_slave 一致），高位忽略。
//
// 寄存器映射（同 apb_status_slave）：
//   0x00 CAM_REG   [31:16]=cam_id [15]=id_ok [14]=i2c_err [13]=cfg_done
//                  [12]=ddr_rdy [11]=sw4 [10]=sw3 [9]=cv_on [5:0]=blob_cnt
//   0x04 CV_REG    [31:24]=bin_thr [21:11]=run_cnt [10]=ccl_busy [9]=run_overflow [7:0]=frame_cnt[7:0]
//   0x08 FRAME_REG [31:0]=frame_cnt（vsync 累加）
//   0x0C VER_REG   32'h4D435601 ("MCV1") 魔术，供固件自检
//   0x10 HEARTBEAT MCU 写；O_heartbeat 回暴露给 fabric（LED/状态自证）
//   0x14 SCRATCH   MCU 写；O_scratch 回暴露
//
// 时钟域：本模块跑在 ahb_clk（MCU 输出的 AHB 总线时钟，~150MHz = core_clk/2）。
//   状态输入（来自 100M/pixel 域的已同步版本）+ vsync（pixel 域）在本模块内部 2FF 同步到 ahb_clk。
//=============================================================================
module ahb_status_slave #(
    parameter [31:0] VER = 32'h4D435601
)(
    input  wire        I_hclk,
    input  wire        I_hresetn,

    // ---- AHB-Lite 主机（MCU 侧）信号 ----
    input  wire [1:0]  I_htrans,     // 00 IDLE / 01 BUSY / 10 NONSEQ / 11 SEQ
    input  wire        I_hwrite,
    input  wire [30:0] I_haddr,
    input  wire [2:0]  I_hsize,
    input  wire [2:0]  I_hburst,     // 保留
    input  wire [3:0]  I_hprot,      // 保留
    input  wire        I_hmastlock,  // 保留
    input  wire [31:0] I_hwdata,
    output reg  [31:0] O_hrdata,
    output wire        O_hreadyout,
    output wire [1:0]  O_hresp,

    // ---- 状态输入（顶层已同步到 100M 域的版本；本模块再 2FF 到 ahb_clk）----
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
    input  wire        I_vsync,       // pixel 域，内部 2FF

    // ---- MCU 写回暴露 ----
    output wire [31:0] O_heartbeat,
    output wire [31:0] O_scratch,
    output wire [31:0] O_frame_cnt
);
    // ------------------------------------------------------------------
    // 状态 2FF 同步到 ahb_clk（多 bit 状态显示用，毛刺可接受，与 status_report 同级）
    // ------------------------------------------------------------------
    reg [15:0] S_cam_id_a, S_cam_id;
    reg        S_idok_a, S_idok, S_i2cerr_a, S_i2cerr, S_cfgdn_a, S_cfgdn;
    reg        S_ddrrdy_a, S_ddrrdy, S_sw4_a, S_sw4, S_sw3_a, S_sw3, S_cvon_a, S_cvon;
    reg [5:0]  S_blob_a, S_blob;
    reg [7:0]  S_binthr_a, S_binthr;
    reg [10:0] S_runcnt_a, S_runcnt;
    reg        S_cclbsy_a, S_cclbsy, S_runof_a, S_runof;
    reg [1:0]  S_vs_sync;
    reg        S_vs_d;
    reg [31:0] S_frame_cnt;
    wire       vs_rise = S_vs_sync[1] & ~S_vs_d;

    always @(posedge I_hclk or negedge I_hresetn) begin
        if (!I_hresetn) begin
            S_cam_id_a <= 16'd0; S_cam_id <= 16'd0;
            S_idok_a <= 1'b0; S_idok <= 1'b0; S_i2cerr_a <= 1'b0; S_i2cerr <= 1'b0;
            S_cfgdn_a <= 1'b0; S_cfgdn <= 1'b0;
            S_ddrrdy_a <= 1'b0; S_ddrrdy <= 1'b0;
            S_sw4_a <= 1'b0; S_sw4 <= 1'b0; S_sw3_a <= 1'b0; S_sw3 <= 1'b0;
            S_cvon_a <= 1'b0; S_cvon <= 1'b0;
            S_blob_a <= 6'd0; S_blob <= 6'd0;
            S_binthr_a <= 8'd0; S_binthr <= 8'd0;
            S_runcnt_a <= 11'd0; S_runcnt <= 11'd0;
            S_cclbsy_a <= 1'b0; S_cclbsy <= 1'b0; S_runof_a <= 1'b0; S_runof <= 1'b0;
            S_vs_sync <= 2'b00; S_vs_d <= 1'b0; S_frame_cnt <= 32'd0;
        end else begin
            S_cam_id_a <= I_cam_id;       S_cam_id <= S_cam_id_a;
            S_idok_a   <= I_cam_id_ok;   S_idok   <= S_idok_a;
            S_i2cerr_a <= I_cam_i2c_err; S_i2cerr <= S_i2cerr_a;
            S_cfgdn_a  <= I_cam_cfg_done;S_cfgdn  <= S_cfgdn_a;
            S_ddrrdy_a <= I_ddr_rdy;     S_ddrrdy <= S_ddrrdy_a;
            S_sw4_a    <= I_sw4;         S_sw4    <= S_sw4_a;
            S_sw3_a    <= I_sw3;         S_sw3    <= S_sw3_a;
            S_cvon_a   <= I_cv_on;       S_cvon   <= S_cvon_a;
            S_blob_a   <= I_blob_cnt;    S_blob   <= S_blob_a;
            S_binthr_a <= I_bin_thr;     S_binthr <= S_binthr_a;
            S_runcnt_a <= I_run_cnt;     S_runcnt <= S_runcnt_a;
            S_cclbsy_a <= I_ccl_busy;    S_cclbsy <= S_cclbsy_a;
            S_runof_a  <= I_run_overflow;S_runof  <= S_runof_a;
            S_vs_sync  <= {S_vs_sync[0], I_vsync};
            S_vs_d     <= S_vs_sync[1];
            if (vs_rise) S_frame_cnt <= S_frame_cnt + 1'b1;
        end
    end

    assign O_frame_cnt = S_frame_cnt;

    // ------------------------------------------------------------------
    // MCU 可写寄存器：HEARTBEAT / SCRATCH
    //   AHB 写在数据相落寄存器：用「上一拍锁存的地址相位」r_haddr/r_hwrite/r_hvalid
    //   + 当前拍 hwdata（数据相位）。按 HSIZE+HADDR 派生字节使能。
    // ------------------------------------------------------------------
    reg [31:0] S_heartbeat;
    reg [31:0] S_scratch;
    assign O_heartbeat = S_heartbeat;
    assign O_scratch  = S_scratch;

    // 地址相位锁存（当前拍锁存→下一拍作为数据相位用）
    reg [30:0] r_haddr;
    reg        r_hwrite;
    reg        r_hvalid;        // htrans != IDLE（NONSEQ/SEQ/BUSY 视为有传输；BUSY 主机暂停，从口不应写——简化：只在 NONSEQ/SEQ 视为有效写/读）
    reg [2:0]  r_hsize;

    // 真实传输：htrans[1]==1（NONSEQ=10 / SEQ=11）；BUSY(01) 是主机暂停，不当数据相位
    wire xfer_now = (I_htrans == 2'b10) || (I_htrans == 2'b11);
    wire xfer_prev = (r_hvalid);   // 锁存时已按 NONSEQ/SEQ 判定

    // 字节使能：由 HSIZE + HADDR 派生（数据相位用 r_hsize/r_haddr）
    function [3:0] f_be(input [2:0] hs, input [30:0] ha);
        begin
            case (hs[1:0])
                2'b10: f_be = 4'b1111;                       // word
                2'b01: f_be = ha[1] ? 4'b1100 : 4'b0011;     // halfword
                2'b00: f_be = (4'b0001 << ha[1:0]);          // byte
                default: f_be = 4'b1111;
            endcase
        end
    endfunction

    // 字节合并
    function [31:0] f_merge(input [31:0] oldv, input [31:0] newv, input [3:0] be);
        integer k;
        reg [31:0] r;
        begin
            r = oldv;
            for (k = 0; k < 4; k = k + 1)
                if (be[k]) r[k*8 +: 8] = newv[k*8 +: 8];
            f_merge = r;
        end
    endfunction

    // 只读寄存器字（同步后版本）
    wire [31:0] CAM_REG = {S_cam_id, S_idok, S_i2cerr, S_cfgdn, S_ddrrdy, S_sw4, S_sw3, S_cvon, 3'b0, S_blob};
    wire [31:0] CV_REG  = {S_binthr, 1'b0, S_runcnt, S_cclbsy, S_runof, 1'b0, S_frame_cnt[7:0]};
    wire [31:0] FRAME_REG = S_frame_cnt;
    wire [31:0] VER_REG  = VER;

    function [31:0] rdata_mux(input [4:0] idx);
        begin
            case (idx)
                5'h00: rdata_mux = CAM_REG;
                5'h01: rdata_mux = CV_REG;
                5'h02: rdata_mux = FRAME_REG;
                5'h03: rdata_mux = VER_REG;
                5'h04: rdata_mux = S_heartbeat;
                5'h05: rdata_mux = S_scratch;
                default: rdata_mux = 32'h0;
            endcase
        end
    endfunction

    always @(posedge I_hclk or negedge I_hresetn) begin
        if (!I_hresetn) begin
            r_haddr   <= 31'd0;
            r_hwrite  <= 1'b0;
            r_hvalid  <= 1'b0;
            r_hsize   <= 3'd0;
            S_heartbeat <= 32'd0;
            S_scratch   <= 32'd0;
        end else begin
            // 数据相位（上一拍锁存的传输）：写
            if (xfer_prev && r_hwrite) begin
                case (r_haddr[6:2])
                    5'h04: S_heartbeat <= f_merge(S_heartbeat, I_hwdata, f_be(r_hsize, r_haddr));
                    5'h05: S_scratch   <= f_merge(S_scratch,   I_hwdata, f_be(r_hsize, r_haddr));
                    default: ; // 其它写地址忽略
                endcase
            end
            // 地址相位锁存（当前拍）
            r_haddr  <= I_haddr;
            r_hwrite <= I_hwrite;
            r_hsize  <= I_hsize;
            r_hvalid <= xfer_now;
        end
    end

    // 读数据：数据相位（上一拍锁存的传输）的组合输出
    always @(*) begin
        if (xfer_prev && !r_hwrite) O_hrdata = rdata_mux(r_haddr[6:2]);
        else                          O_hrdata = 32'h0;
    end

    assign O_hreadyout = 1'b1;     // 零等待，恒就绪
    assign O_hresp     = 2'b00;    // OKAY

endmodule
