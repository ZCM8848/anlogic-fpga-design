`timescale 1ns / 1ps
//=============================================================================
// ahb_status_slave.v — AHB-Lite 从口：板级状态 + CV 数据通路（run_mem 读窗 / overlay 写窗）
// ============================================================
// 背景：fabric AHB 窗口 = 0x80000000（AHBDemo 验证）。MCU 的 AHB master 端口
//   接本从口；APB master 悬空。本从口为总线上唯一从口，hreadyout 恒 1、hresp 恒 OKAY。
//
// AHB-Lite 时序（零等待）：
//   地址相（cycle N）：haddr/htrans/hwrite/hsize 采样、锁存。
//   数据相（cycle N+1）：读→hrdata = mux(锁存地址)；写→hwdata 落入该寄存器。
//
// 寄存器映射（haddr[6:2] 选 16 个 32bit 槽）：
//   0x00 CAM_REG   [31:16]=cam_id [15]=id_ok [14]=i2c_err [13]=cfg_done
//                  [12]=ddr_rdy [11]=sw4 [10]=sw3 [9]=cv_on [5:0]=blob_cnt
//   0x04 CV_REG    [31:24]=bin_thr [20:10]=run_cnt [7:0]=frame_cnt[7:0]
//   0x08 FRAME_REG [31:0]=frame_cnt（vsync 累加）
//   0x0C VER_REG   32'h4D435602 ("MCV2") 魔术（v2：CV 通路转 MCU）
//   0x10 HEARTBEAT MCU 写；O_heartbeat 回暴露
//   0x14 SCRATCH   MCU 写；O_scratch 回暴露
//   ---- CV 数据通路（v2 新增）----
//   0x18 RUN_IDX   MCU 写：run_mem 读索引（10bit）。写入即寻址 cv_top 的 run_mem B 口。
//   0x1C RUN_DAT   MCU 读：= run_mem[上一拍 RUN_IDX]（cv_top B 口同步读 + 本从口再锁 1 拍）。
//   0x20 OV_IDX    MCU 写：overlay 写索引（3bit，0..7）。
//   0x24 OV_W0     MCU 写：overlay 项高 32bit 暂存 {valid,id,x0,y0}。
//   0x28 OV_W1     MCU 写：overlay 项低 32bit {x1,y1}；写入触发 overlay[OV_IDX]<={OV_W0,W1}。
//   0x2C META_REG  MCU 读：{run_cnt[10:0], min_y[7:0], max_y[7:0], vsync_latch, pad}。
//   0x30 OV_COUNT  MCU 写/读：exit 计数值（16bit）。
//   0x3C BALL_STATUS [0]=bg_ready [1]=capturing [2]=run_overflow
//   0x40 SW_STAT   [0]=SW1 [1]=SW2 [2]=SW3 [3]=SW4
//   0x44 BCD_COUNT MCU 写：5 位 BCD 计数
//   0x48 BALL_RUN_CFG [8:0]=roi_y1 [19:10]=max_run_len（前端 run 过滤）
//   0x4C SKIP_CNT  [15:0]=ROI 丢弃 run 数 [31:16]=超长 run 丢弃数（只读）
//
// overlay 项字段（64bit = {W0[31:0], W1[31:0]}，cv_top 叠加解析）：
//   [63] valid  [62:59] id[3:0]  [58:47] x0[11:0]  [46:35] y0[11:0]  [34:32] pad
//   [31:20] x1[11:0]  [19:8] y1[11:0]  [7:0] pad   （x1/y1 在 W1 区）
//
// 时钟域：本模块跑 ahb_clk（MCU 输出，~150MHz）。
//   状态输入（100M/pixel 域已同步版本）+ vsync + run_cnt/min_y/max_y/skip_*（pixel 域）
//   在本模块内部 2FF 同步到 ahb_clk。
//   run_mem B 口在 cv_top 内、用 ahb_clk 读；地址 O_run_rd_addr、数据 I_run_rd_data 跨模块相连。
//=============================================================================
module ahb_status_slave #(
    parameter [31:0] VER = 32'h4D435602
)(
    input  wire        I_hclk,
    input  wire        I_hresetn,

    // ---- AHB-Lite 主机（MCU 侧）信号 ----
    input  wire [1:0]  I_htrans,
    input  wire        I_hwrite,
    input  wire [30:0] I_haddr,
    input  wire [2:0]  I_hsize,
    input  wire [2:0]  I_hburst,
    input  wire [3:0]  I_hprot,
    input  wire        I_hmastlock,
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
    input  wire        I_sw1,
    input  wire        I_sw2,
    input  wire        I_sw4,
    input  wire        I_sw3,
    input  wire        I_cv_on,
    input  wire [5:0]  I_blob_cnt,
    input  wire [7:0]  I_bin_thr,
    input  wire [10:0] I_run_cnt,       // pixel 域 run 数（本帧）
    input  wire        I_run_overflow,  // pixel 域 run_mem 溢出（本帧不完整）
    input  wire [7:0]  I_min_y,          // pixel 域本帧最小亮度（自适应阈值用）
    input  wire [7:0]  I_max_y,          // pixel 域本帧最大亮度
    input  wire        I_vsync,         // pixel 域，内部 2FF + 上升沿锁存
    input  wire [15:0] I_skip_roi_cnt,  // pixel 域：本帧 ROI 丢弃 run 数
    input  wire [15:0] I_skip_len_cnt,  // pixel 域：本帧 max_run_len 丢弃 run 数

    // ---- MCU 参数：钢珠前端（C 固件写；RTL 不写死阈值）----
    output wire        O_ball_en,
    output wire [7:0]  O_ball_bg_thr,
    output wire [7:0]  O_ball_min_run,
    output wire [8:0]  O_ball_roi_y1,
    output wire [9:0]  O_ball_max_run_len,
    output wire        O_ball_capture,
    input  wire        I_ball_bg_ready,
    input  wire        I_ball_capturing,

    // ---- run_mem 间接读口（cv_top 的 run_mem B 口，ahb_clk 域读）----
    output wire [9:0]  O_run_rd_addr,
    input  wire [31:0] I_run_rd_data,   // cv_top B 口同步读输出（上一拍地址的内容）

    // ---- overlay 寄存器组输出（给 cv_top 叠加；8 项 × 64bit）+ count ----
    output wire [511:0] O_overlay,
    output wire [15:0]  O_count,
    output wire [19:0]  O_count_bcd,

    // ---- MCU 写回暴露 ----
    output wire [31:0] O_heartbeat,
    output wire [31:0] O_scratch,
    output wire [31:0] O_frame_cnt
);
    // ------------------------------------------------------------------
    // 状态 2FF 同步到 ahb_clk
    // ------------------------------------------------------------------
    reg [15:0] S_cam_id_a, S_cam_id;
    reg        S_idok_a, S_idok, S_i2cerr_a, S_i2cerr, S_cfgdn_a, S_cfgdn;
    reg        S_ddrrdy_a, S_ddrrdy, S_sw1_a, S_sw1, S_sw2_a, S_sw2;
    reg        S_sw4_a, S_sw4, S_sw3_a, S_sw3, S_cvon_a, S_cvon;
    reg [5:0]  S_blob_a, S_blob;
    reg [7:0]  S_binthr_a, S_binthr;
    reg [10:0] S_runcnt_a, S_runcnt;
    reg        S_rovf_a, S_rovf;
    reg [7:0]  S_miny_a, S_miny, S_maxy_a, S_maxy;
    reg [15:0] S_skip_roi_a, S_skip_roi, S_skip_len_a, S_skip_len;
    reg        S_bgready_a, S_bgready, S_capturing_a, S_capturing;
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
            S_sw1_a <= 1'b0; S_sw1 <= 1'b0; S_sw2_a <= 1'b0; S_sw2 <= 1'b0;
            S_sw4_a <= 1'b0; S_sw4 <= 1'b0; S_sw3_a <= 1'b0; S_sw3 <= 1'b0;
            S_cvon_a <= 1'b0; S_cvon <= 1'b0;
            S_blob_a <= 6'd0; S_blob <= 6'd0;
            S_binthr_a <= 8'd0; S_binthr <= 8'd0;
            S_runcnt_a <= 11'd0; S_runcnt <= 11'd0;
            S_rovf_a <= 1'b0; S_rovf <= 1'b0;
            S_miny_a <= 8'd0; S_miny <= 8'd0; S_maxy_a <= 8'd0; S_maxy <= 8'd0;
            S_skip_roi_a <= 16'd0; S_skip_roi <= 16'd0;
            S_skip_len_a <= 16'd0; S_skip_len <= 16'd0;
            S_bgready_a <= 1'b0; S_bgready <= 1'b0;
            S_capturing_a <= 1'b0; S_capturing <= 1'b0;
            S_vs_sync <= 2'b00; S_vs_d <= 1'b0; S_frame_cnt <= 32'd0;
        end else begin
            S_cam_id_a <= I_cam_id;       S_cam_id <= S_cam_id_a;
            S_idok_a   <= I_cam_id_ok;   S_idok   <= S_idok_a;
            S_i2cerr_a <= I_cam_i2c_err; S_i2cerr <= S_i2cerr_a;
            S_cfgdn_a  <= I_cam_cfg_done;S_cfgdn  <= S_cfgdn_a;
            S_ddrrdy_a <= I_ddr_rdy;     S_ddrrdy <= S_ddrrdy_a;
            S_sw1_a    <= I_sw1;          S_sw1    <= S_sw1_a;
            S_sw2_a    <= I_sw2;          S_sw2    <= S_sw2_a;
            S_sw4_a    <= I_sw4;          S_sw4    <= S_sw4_a;
            S_sw3_a    <= I_sw3;          S_sw3    <= S_sw3_a;
            S_cvon_a   <= I_cv_on;       S_cvon   <= S_cvon_a;
            S_blob_a   <= I_blob_cnt;    S_blob   <= S_blob_a;
            S_binthr_a <= I_bin_thr;     S_binthr <= S_binthr_a;
            S_runcnt_a <= I_run_cnt;    S_runcnt <= S_runcnt_a;
            S_rovf_a   <= I_run_overflow; S_rovf <= S_rovf_a;
            S_miny_a   <= I_min_y;       S_miny   <= S_miny_a;
            S_maxy_a   <= I_max_y;       S_maxy   <= S_maxy_a;
            S_skip_roi_a <= I_skip_roi_cnt; S_skip_roi <= S_skip_roi_a;
            S_skip_len_a <= I_skip_len_cnt; S_skip_len <= S_skip_len_a;
            S_bgready_a <= I_ball_bg_ready; S_bgready <= S_bgready_a;
            S_capturing_a <= I_ball_capturing; S_capturing <= S_capturing_a;
            S_vs_sync  <= {S_vs_sync[0], I_vsync};
            S_vs_d     <= S_vs_sync[1];
            if (vs_rise) S_frame_cnt <= S_frame_cnt + 1'b1;
        end
    end

    assign O_frame_cnt = S_frame_cnt;

    // ------------------------------------------------------------------
    // MCU 可写寄存器：HEARTBEAT / SCRATCH / RUN_IDX / OV_IDX / OV_W0 / OV_W1 / OV_COUNT
    //   overlay[8] / count
    // ------------------------------------------------------------------
    reg [31:0] S_heartbeat;
    reg [31:0] S_scratch;
    assign O_heartbeat = S_heartbeat;
    assign O_scratch  = S_scratch;

    // 钢珠前端参数（MCU C 固件唯一写入源）
    reg        S_ball_en, S_ball_capture;
    reg [15:0] S_ball_thr;
    reg [31:0] S_ball_run_cfg;
    assign O_ball_en      = S_ball_en;
    assign O_ball_capture = S_ball_capture;
    assign O_ball_bg_thr  = S_ball_thr[7:0];
    assign O_ball_min_run = S_ball_thr[15:8];
    assign O_ball_roi_y1  = S_ball_run_cfg[8:0];
    assign O_ball_max_run_len = S_ball_run_cfg[19:10];

    // run_mem 间接读
    reg [9:0]  r_run_idx;           // MCU 写 RUN_IDX
    reg [31:0] r_run_dat;           // 锁存 cv_top B 口输出
    assign O_run_rd_addr = r_run_idx;

    // overlay 寄存器组（8 项 × 64bit）+ count
    reg [63:0] S_overlay [0:7];
    reg [2:0]  r_ov_idx;
    reg [31:0] r_ov_w0;
    reg [15:0] S_count;
    reg [19:0] S_count_bcd;
    assign O_count = S_count;
    assign O_count_bcd = S_count_bcd;

    // overlay 总线打包：{ov7, ov6, ..., ov0}
    assign O_overlay = {S_overlay[7], S_overlay[6], S_overlay[5], S_overlay[4],
                        S_overlay[3], S_overlay[2], S_overlay[1], S_overlay[0]};

    // 地址相位锁存（当前拍锁存→下一拍作数据相位用）
    reg [30:0] r_haddr;
    reg        r_hwrite;
    reg        r_hvalid;
    reg [2:0]  r_hsize;

    wire xfer_now  = (I_htrans == 2'b10) || (I_htrans == 2'b11);
    wire xfer_prev = r_hvalid;

    // 字节使能
    function [3:0] f_be(input [2:0] hs, input [30:0] ha);
        begin
            case (hs[1:0])
                2'b10: f_be = 4'b1111;
                2'b01: f_be = ha[1] ? 4'b1100 : 4'b0011;
                2'b00: f_be = (4'b0001 << ha[1:0]);
                default: f_be = 4'b1111;
            endcase
        end
    endfunction

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

    // 只读寄存器字
    wire [31:0] CAM_REG = {S_cam_id, S_idok, S_i2cerr, S_cfgdn, S_ddrrdy, S_sw4, S_sw3, S_cvon, 3'b0, S_blob};
    wire [31:0] CV_REG  = {S_binthr, 3'b0, S_runcnt, 2'b0, S_frame_cnt[7:0]};
    wire [31:0] FRAME_REG = S_frame_cnt;
    wire [31:0] VER_REG  = VER;
    // META：{run_cnt[10:0], min_y[7:0], max_y[7:0], vsync_latch, 4'b0}
    wire [31:0] META_REG = {S_runcnt, S_miny, S_maxy, 1'b0, 4'b0};
    wire [31:0] BALL_CTRL_REG   = {30'b0, S_ball_capture, S_ball_en};
    wire [31:0] BALL_THR_REG    = {16'b0, S_ball_thr};
    wire [31:0] BALL_STATUS_REG = {29'b0, S_rovf, S_capturing, S_bgready};
    wire [31:0] SW_STAT_REG = {28'b0, S_sw4, S_sw3, S_sw2, S_sw1};
    wire [31:0] SKIP_REG = {S_skip_len, S_skip_roi};

    function [31:0] rdata_mux(input [4:0] idx);
        begin
            case (idx)
                5'h00: rdata_mux = CAM_REG;
                5'h01: rdata_mux = CV_REG;
                5'h02: rdata_mux = FRAME_REG;
                5'h03: rdata_mux = VER_REG;
                5'h04: rdata_mux = S_heartbeat;
                5'h05: rdata_mux = S_scratch;
                5'h07: rdata_mux = r_run_dat;        // RUN_DAT
                5'h0B: rdata_mux = META_REG;
                5'h0C: rdata_mux = {16'b0, S_count}; // OV_COUNT 回读
                5'h11: rdata_mux = {12'b0, S_count_bcd}; // BCD_COUNT @0x44
                5'h0D: rdata_mux = BALL_CTRL_REG;
                5'h0E: rdata_mux = BALL_THR_REG;
                5'h0F: rdata_mux = BALL_STATUS_REG;
                5'h10: rdata_mux = SW_STAT_REG;      // 0x40: SW1..SW4
                5'h12: rdata_mux = S_ball_run_cfg;    // 0x48: [8:0]=roi_y1 [19:10]=max_run_len
                5'h13: rdata_mux = SKIP_REG;          // 0x4C: [15:0]=skip_roi [31:16]=skip_len
                default: rdata_mux = 32'h0;
            endcase
        end
    endfunction

    integer i;
    always @(posedge I_hclk or negedge I_hresetn) begin
        if (!I_hresetn) begin
            r_haddr   <= 31'd0;
            r_hwrite  <= 1'b0;
            r_hvalid  <= 1'b0;
            r_hsize   <= 3'd0;
            S_heartbeat <= 32'd0;
            S_scratch   <= 32'd0;
            r_run_idx <= 10'd0;
            r_run_dat <= 32'd0;
            r_ov_idx  <= 3'd0;
            r_ov_w0   <= 32'd0;
            S_count   <= 16'd0;
            S_count_bcd <= 20'd0;
            S_ball_en <= 1'b0; S_ball_capture <= 1'b0; S_ball_thr <= 16'd0;
            S_ball_run_cfg <= 32'h0003_20A6;   // roi_y1=166, max_run_len=200
            for (i = 0; i < 8; i = i + 1) S_overlay[i] <= 64'd0;
        end else begin
            // run_mem B 口同步读输出锁存（每拍把 I_run_rd_data 入 r_run_dat）
            r_run_dat <= I_run_rd_data;

            // 数据相（上一拍锁存的传输）：写
            if (xfer_prev && r_hwrite) begin
                case (r_haddr[6:2])
                    5'h04: S_heartbeat <= f_merge(S_heartbeat, I_hwdata, f_be(r_hsize, r_haddr));
                    5'h05: S_scratch   <= f_merge(S_scratch,   I_hwdata, f_be(r_hsize, r_haddr));
                    5'h06: r_run_idx    <= I_hwdata[9:0];               // RUN_IDX
                    5'h08: r_ov_idx     <= I_hwdata[2:0];               // OV_IDX
                    5'h09: r_ov_w0      <= I_hwdata;                    // OV_W0 暂存
                    5'h0A: S_overlay[r_ov_idx] <= {r_ov_w0, I_hwdata};  // OV_W1 触发提交
                    5'h0C: S_count      <= I_hwdata[15:0];              // OV_COUNT
                    5'h11: S_count_bcd  <= I_hwdata[19:0];              // BCD_COUNT @0x44
                    5'h12: S_ball_run_cfg <= I_hwdata;                  // BALL_RUN_CFG @0x48
                    5'h0D: begin                                       // BALL_CTRL
                        S_ball_en      <= I_hwdata[0];
                        S_ball_capture <= I_hwdata[1];
                    end
                    5'h0E: S_ball_thr   <= I_hwdata[15:0];              // BALL_THR: [7:0]=thr [15:8]=min_run
                    default: ;
                endcase
            end
            // 地址相位锁存
            r_haddr  <= I_haddr;
            r_hwrite <= I_hwrite;
            r_hsize  <= I_hsize;
            r_hvalid <= xfer_now;
        end
    end

    // 读数据：数据相（上一拍锁存的传输）的组合输出
    always @(*) begin
        if (xfer_prev && !r_hwrite) O_hrdata = rdata_mux(r_haddr[6:2]);
        else                          O_hrdata = 32'h0;
    end

    assign O_hreadyout = 1'b1;
    assign O_hresp     = 2'b00;

endmodule
