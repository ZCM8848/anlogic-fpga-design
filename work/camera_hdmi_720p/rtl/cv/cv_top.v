`timescale 1ns / 1ps
//=============================================================================
// cv_top.v — 钢珠亮斑检测 + 白框叠加（M7 / Phase A，单帧检测无跟踪）
//
// 串在 hdmi_mixer → video_mux 之间。组合直通（O_de/O_vs/O_data 与输入同拍，
// 不引入额外寄存器级数，保持 M6 的 pattern/camera +3 同相对齐）。
// I_cv_on=1 时在视频上叠加白色 bbox 边框。
//
// 算法（简化 CCL，无 union-find）：
//   段1 流式 run 提取（active, de=1）：Y>阈值 → 1-bit → 连续 1-串打包成 run{y,xs,xe}
//   段2 CCL（vblank）：逐 run 扫 prev 行缓存，取【第一个 x 重叠的 prev label】（或新 label），
//       直接累加 feature[label]{min/max x/y, area}；无 union-find → 无 f_find 嵌套异步读
//       （TD 异步嵌套读 RAM 会 coredump）。过滤 feature 根节点 → overlay 表。
//       代价：有内部间隙的 blob 偶尔过分割（圆球无间隙→不受影响）。
//   段3 叠加（下一帧 active）：像素(x,y) 与 overlay 表并行比较 → 落边框→白
//
// 存储实现（TD 兼容）：
//   run_mem：BRAM 同步读（active 写、vblank 读，无冲突）。
//   feature/rca/ov：dram（分布式 LUTRAM，支持异步读；地址均来自寄存器、1 级不嵌套→不崩溃；
//     写为同步单口→无 part-select 写译码爆炸）。ov 的叠加读为常量变址（loop 展开）→固定 tap。
//
// 1 帧延迟：本帧 vblank 算的 bbox 用于下一帧叠加。
// 调参：见 parameter 段（编译期，改完 run.bat 重建）。每个参数有【调参N】标注。
//=============================================================================
module cv_top #(
    parameter IMG_W            = 1280,
    parameter IMG_H            = 720,
    parameter [7:0]  BIN_THR   = 8'd120,  // 【调参1】亮度阈值(0..255)，Y>此值判为亮
                                          //   ↑：只留更亮核心，噪声少但暗反光漏；↓：检出多但噪声多
    parameter [15:0] MIN_AREA  = 16'd8,   // 【调参2】blob 最小像素数，小于则丢（去小噪声）
    parameter [15:0] MAX_AREA  = 16'd20000, // 【调参3】blob 最大像素数，大于则丢（去大背景/过曝）
    parameter [5:0]  MIN_FILL  = 6'd15,   // 【调参4】最小填充率%(area*100/box)。钢珠反光较实
                                          //   ↑：要求更饱满，稀疏噪声易丢；↓：容忍稀疏
    parameter [5:0]  MIN_RATIO = 6'd25,   // 【调参5】最小长短比%(min(w,h)*100/max(w,h))。圆球接近100
                                          //   ↑：要求更圆，细长条易丢；↓：容忍细长
    parameter [11:0] EDGE_MG   = 12'd4,   // 【调参6】贴边剔除 margin(px)。bbox 离图像边<此值丢
                                          //   ↑：只留中部完整球；↓：边缘球也框
    parameter         MAX_BLOBS = 16,    // 叠加比较器数（同屏最多框多少球；32 时路由压力大致超时，暂 16）
    parameter         MAX_RUNS  = 1024,   // run_mem 深度（溢出则饱和停写）
    parameter         MAX_RPR   = 32,     // 每行 run 缓存深度
    parameter         MAX_LABELS= 32,     // 临时标签上限（64 时 feature 读 mux 深度翻倍，暂 32）
    parameter [11:0]  FBOX_W    = 12'd2,  // 边框线宽（px，向内画）
    parameter         MASK_VIEW = 1       // 1=CV 模式显示二值掩膜(亮=白/暗=黑)+红框(诊断/调参)；
                                         //   0=白框叠加在彩色画面上(原行为)
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_cv_on,
    input  wire        I_thr_up,        // 运行期 BIN_THR +1（单拍脉冲，已去抖）
    input  wire        I_thr_dn,        // 运行期 BIN_THR -1
    input  wire        I_de,
    input  wire        I_vs,
    input  wire [23:0] I_data,
    output wire        O_de,
    output wire        O_vs,
    output wire [23:0] O_data,
    output wire [5:0]  O_blob_cnt,
    output wire [10:0] O_run_cnt,
    output wire        O_ccl_busy,
    output wire        O_run_overflow,
    output wire [7:0]  O_bin_thr        // 当前阈值（供串口 TH= 上报）
);
    localparam FW  = 1 + 12 + 12 + 12 + 12 + 16; // 65  feature entry
    localparam RPW = (MAX_RPR == 32) ? 5 : 6;

    // ======================================================================
    // x/y 重建
    // ======================================================================
    reg [11:0] r_x, r_y;
    reg        r_vs_d;
    wire       vs_rise = I_vs & ~r_vs_d;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r_x <= 12'd0; r_y <= 12'd0; r_vs_d <= 1'b0;
        end else begin
            r_vs_d <= I_vs;
            if (vs_rise) begin
                r_x <= 12'd0; r_y <= 12'd0;
            end else if (I_de) begin
                if (r_x == IMG_W - 1) begin
                    r_x <= 12'd0; r_y <= r_y + 12'd1;
                end else r_x <= r_x + 12'd1;
            end
        end
    end

    // ======================================================================
    // 亮度 + 阈值（运行期可调 r_bin_thr）
    // ======================================================================
    reg [7:0] r_bin_thr;
    wire [7:0] w_y =
        {2'b0, I_data[23:18]} + {1'b0, I_data[15:9]} + {2'b0, I_data[7:2]};
    wire       w_mask = (w_y > r_bin_thr);

    // ======================================================================
    // 存储
    // ======================================================================
    (* ram_style = "block" *) reg [33:0] run_mem [0:MAX_RUNS-1];   // {y,xs,xe}，同步读
    (* ram_style = "dram" *)  reg [FW-1:0] feature [0:MAX_LABELS-1]; // {valid,min_x,max_x,min_y,max_y,area}
    (* ram_style = "dram" *)  reg [29:0]   rca     [0:2*MAX_RPR-1]; // 双缓冲 {xs,xe,label}
    (* ram_style = "dram" *)  reg [48:0]   ov      [0:MAX_BLOBS-1]; // {valid,min_x,max_x,min_y,max_y}

    // run 提取
    reg [10:0] r_run_wr, r_run_cnt;
    reg        r_run_act, r_run_overflow, r_de_d;
    reg [11:0] r_run_xs, r_run_xe;
    wire       row_last = I_de & (r_x == IMG_W - 1);
    // run_mem 同步读
    reg [10:0] r_run_rd;   reg [33:0] r_run_rd_d;

    // FSM
    localparam S_IDLE=4'd0, S_INIT=4'd1, S_RD=4'd2, S_SCAN=4'd3,
               S_COLLECT=4'd4, S_DONE=4'd5;
    reg [3:0]  r_st;
    reg [10:0] r_i;
    reg [5:0]  r_next_label, r_j, r_cur_lbl;
    reg        r_found_any;
    reg [5:0]  r_lv, r_collect;
    reg        r_prev_sel;
    reg [5:0]  r_prev_len, r_cur_len;
    reg [11:0] r_cur_row_y;

    assign O_ccl_busy = (r_st != S_IDLE);

    // ---- 当前 run ----
    wire [33:0] w_run = r_run_rd_d;
    wire [9:0]  w_ry  = w_run[33:24];
    wire [11:0] w_rxs = w_run[23:12];
    wire [11:0] w_rxe = w_run[11:0];

    // ---- prev 行当前条目（rca dram 异步读，地址来自寄存器）----
    wire [RPW-1:0] r_j_idx = r_j[RPW-1:0];
    wire [5:0]     prev_idx = {r_prev_sel, r_j_idx};
    wire [29:0]    w_prev = rca[prev_idx];
    wire [11:0]    w_pxs  = w_prev[29:18];
    wire [11:0]    w_pxe  = w_prev[17:6];
    wire [5:0]     w_plbl = w_prev[5:0];
    wire           w_ovl  = (w_rxs <= w_pxe) && (w_pxs <= w_rxe);
    wire           w_past = (w_pxs > w_rxe);
    wire [11:0]    w_ry_ext = {2'b0, w_ry};
    wire           w_row_chg = (w_ry_ext != r_cur_row_y);
    wire           w_adj     = (w_ry_ext == r_cur_row_y + 12'd1);

    // ---- 扫描结束时的最终 label（无 union：第一个重叠 label 或新 label）----
    wire [5:0] final_lbl = !r_found_any ? r_next_label : r_cur_lbl;

    // ---- feature 读口（单口，按状态选地址：S_COLLECT 用 r_lv，S_SCAN 用 final_lbl）----
    wire [5:0] feat_rd = (r_st == S_COLLECT) ? r_lv : final_lbl;
    wire [FW-1:0] feat_d = feature[feat_rd];
    wire        f_valid = feat_d[64];
    wire [11:0] f_min_x = feat_d[63:52];
    wire [11:0] f_max_x = feat_d[51:40];
    wire [11:0] f_min_y = feat_d[39:28];
    wire [11:0] f_max_y = feat_d[27:16];
    wire [15:0] f_area  = feat_d[15:0];
    // RMW 新值（S_SCAN：把当前 run 并入 feature[final_lbl]）
    wire [15:0] seg_len  = w_rxe - w_rxs + 12'd1;
    wire [11:0] nf_min_x = (!f_valid) ? w_rxs : ((w_rxs < f_min_x) ? w_rxs : f_min_x);
    wire [11:0] nf_max_x = (!f_valid) ? w_rxe : ((w_rxe > f_max_x) ? w_rxe : f_max_x);
    wire [11:0] nf_min_y = (!f_valid) ? w_ry  : ((w_ry  < f_min_y) ? w_ry  : f_min_y);
    wire [11:0] nf_max_y = (!f_valid) ? w_ry  : ((w_ry  > f_max_y) ? w_ry  : f_max_y);
    wire [15:0] nf_area  = (!f_valid) ? seg_len : (f_area + seg_len);

    // ---- COLLECT 过滤（feature[r_lv]）----
    wire [11:0] cf_w = f_max_x - f_min_x + 12'd1;
    wire [11:0] cf_h = f_max_y - f_min_y + 12'd1;
    wire [23:0] cf_box   = cf_w * cf_h;
    wire [29:0] fill_thr = MIN_FILL * cf_box;
    wire [22:0] area100  = f_area * 7'd100;
    wire [11:0] cf_mn = (cf_w < cf_h) ? cf_w : cf_h;
    wire [11:0] cf_mx = (cf_w < cf_h) ? cf_h : cf_w;
    wire [18:0] ratio_num = cf_mn * 7'd100;
    wire [17:0] ratio_den = MIN_RATIO * cf_mx;
    wire        cf_edge = (f_min_x < EDGE_MG) || (f_min_y < EDGE_MG) ||
                          (f_max_x >= IMG_W - EDGE_MG) || (f_max_y >= IMG_H - EDGE_MG);
    wire        w_pass = f_valid &&
                         (f_area >= MIN_AREA) && (f_area <= MAX_AREA) &&
                         ({9'd0, area100} >= fill_thr) &&
                         (ratio_num >= ratio_den) && (!cf_edge);

    // ======================================================================
    // run 提取（active 写 run_mem）
    // ======================================================================
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r_run_wr <= 11'd0; r_run_cnt <= 11'd0; r_run_act <= 1'b0;
            r_run_xs <= 12'd0; r_run_xe <= 12'd0; r_run_overflow <= 1'b0; r_de_d <= 1'b0;
            r_bin_thr <= BIN_THR;
        end else begin
            r_de_d <= I_de;
            // 运行期阈值调节（CV 调参：N2 减 / J14 加，顶层去抖后单拍脉冲）
            if (I_thr_up && r_bin_thr != 8'hFF) r_bin_thr <= r_bin_thr + 8'd1;
            else if (I_thr_dn && r_bin_thr != 8'h00) r_bin_thr <= r_bin_thr - 8'd1;
            if (vs_rise) begin
                if (r_run_act && (r_run_wr < MAX_RUNS)) begin
                    run_mem[r_run_wr] <= {r_y[9:0], r_run_xs, r_run_xe};
                    r_run_wr <= r_run_wr + 11'd1;
                end
                r_run_cnt <= r_run_wr;
                r_run_wr <= 11'd0;
                r_run_act <= 1'b0;
                r_run_overflow <= 1'b0;
            end else if (I_cv_on && I_de) begin
                if (row_last && r_run_act) begin
                    r_run_xe <= r_x;
                    if (r_run_wr < MAX_RUNS) begin
                        run_mem[r_run_wr] <= {r_y[9:0], r_run_xs, r_run_xe};
                        r_run_wr <= r_run_wr + 11'd1;
                    end else r_run_overflow <= 1'b1;
                    r_run_act <= 1'b0;
                end else begin
                    if (w_mask) begin
                        if (!r_run_act) begin
                            r_run_act <= 1'b1; r_run_xs <= r_x; r_run_xe <= r_x;
                        end else r_run_xe <= r_x;
                    end else if (r_run_act) begin
                        if (r_run_wr < MAX_RUNS) begin
                            run_mem[r_run_wr] <= {r_y[9:0], r_run_xs, r_run_xe};
                            r_run_wr <= r_run_wr + 11'd1;
                        end else r_run_overflow <= 1'b1;
                        r_run_act <= 1'b0;
                    end
                end
            end
        end
    end

    // run_mem 同步读
    always @(posedge I_clk) begin
        r_run_rd_d <= run_mem[r_run_rd];
    end

    // ======================================================================
    // CCL FSM（无 union-find：直接累加 feature[final_lbl]）
    // ======================================================================
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r_st <= S_IDLE; r_i <= 11'd0; r_run_rd <= 11'd0;
            r_next_label <= 6'd0; r_prev_sel <= 1'b0;
            r_prev_len <= 6'd0; r_cur_len <= 6'd0; r_cur_row_y <= 12'h7FF;
            r_j <= 6'd0; r_cur_lbl <= 6'd0; r_found_any <= 1'b0;
            r_lv <= 6'd0; r_collect <= 6'd0;
        end else begin
            case (r_st)
                S_IDLE: if (vs_rise) r_st <= S_INIT;

                S_INIT: begin
                    feature[r_lv] <= {1'b0, 12'hFFF, 12'h000, 12'hFFF, 12'h000, 16'd0};
                    if (r_lv < MAX_BLOBS) ov[r_lv] <= {1'b0, 48'd0};
                    if (r_lv == MAX_LABELS - 1) begin
                        r_lv <= 6'd0; r_i <= 11'd0;
                        r_next_label <= 6'd0; r_prev_sel <= 1'b0;
                        r_prev_len <= 6'd0; r_cur_len <= 6'd0; r_cur_row_y <= 12'h7FF;
                        r_st <= S_RD;
                    end else r_lv <= r_lv + 6'd1;
                end

                S_RD: begin
                    if (r_i >= r_run_cnt) begin
                        r_lv <= 6'd0; r_collect <= 6'd0; r_st <= S_COLLECT;
                    end else begin
                        r_run_rd <= r_i;
                        r_j <= 6'd0; r_found_any <= 1'b0; r_cur_lbl <= 6'd0;
                        r_st <= S_SCAN;
                    end
                end

                S_SCAN: begin
                    if (w_row_chg) begin
                        r_prev_sel <= ~r_prev_sel;
                        r_prev_len <= w_adj ? r_cur_len : 6'd0;
                        r_cur_len  <= 6'd0;
                        r_cur_row_y <= w_ry_ext;
                        r_j <= 6'd0;
                    end else if (r_j < r_prev_len) begin
                        if (w_ovl) begin
                            if (!r_found_any) begin
                                r_cur_lbl <= w_plbl; r_found_any <= 1'b1;
                            end
                            // 无 union：只取第一个重叠 label，其余忽略（有间隙的 blob 可能过分割）
                            r_j <= r_j + 6'd1;
                        end else if (w_past) begin
                            r_j <= r_prev_len;
                        end else begin
                            r_j <= r_j + 6'd1;
                        end
                    end else begin
                        // 扫描结束：定型 final_lbl，累加 feature[final_lbl]（RMW）
                        feature[final_lbl] <= {1'b1, nf_min_x, nf_max_x, nf_min_y, nf_max_y, nf_area};
                        if (r_cur_len < MAX_RPR)
                            rca[{~r_prev_sel, r_cur_len[RPW-1:0]}] <= {w_rxs, w_rxe, final_lbl};
                        r_cur_len <= r_cur_len + 6'd1;
                        if (!r_found_any && (r_next_label < MAX_LABELS))
                            r_next_label <= r_next_label + 6'd1;
                        r_i <= r_i + 11'd1;
                        r_st <= S_RD;
                    end
                end

                S_COLLECT: begin
                    if (r_lv == MAX_LABELS) begin
                        r_st <= S_DONE;
                    end else begin
                        if (w_pass && (r_collect < MAX_BLOBS)) begin
                            ov[r_collect] <= {1'b1, f_min_x, f_max_x, f_min_y, f_max_y};
                            r_collect <= r_collect + 6'd1;
                        end
                        r_lv <= r_lv + 6'd1;
                    end
                end

                S_DONE: r_st <= S_IDLE;

                default: r_st <= S_IDLE;
            endcase
        end
    end

    // ======================================================================
    // 叠加：MAX_BLOBS 路 bbox 并行比较（ov[gi] 常量变址 → 固定 tap，并行）
    // ======================================================================
    integer oi;
    reg r_border;
    always @(*) begin
        r_border = 1'b0;
        for (oi = 0; oi < MAX_BLOBS; oi = oi + 1) begin
            if (ov[oi][48]) begin
                // 竖边（左右各 FBOX_W 宽）在 y 范围内
                if ((((r_x >= ov[oi][47:36]) && (r_x < ov[oi][47:36] + FBOX_W)) ||
                     ((r_x <= ov[oi][35:24]) && (r_x > ov[oi][35:24] - FBOX_W))) &&
                    (r_y >= ov[oi][23:12]) && (r_y <= ov[oi][11:0]))
                    r_border = 1'b1;
                // 横边（上下各 FBOX_W 宽）在 x 范围内
                if ((((r_y >= ov[oi][23:12]) && (r_y < ov[oi][23:12] + FBOX_W)) ||
                     ((r_y <= ov[oi][11:0]) && (r_y > ov[oi][11:0] - FBOX_W))) &&
                    (r_x >= ov[oi][47:36]) && (r_x <= ov[oi][35:24]))
                    r_border = 1'b1;
            end
        end
    end

    // ======================================================================
    // 输出（组合直通；CV 开时显示机器视角）
    //   MASK_VIEW=1：二值掩膜(亮=白/暗=黑) + 红框(bbox)——诊断/调参
    //   MASK_VIEW=0：白框叠加在彩色画面上——原行为
    // ======================================================================
    wire [23:0] cv_base = (MASK_VIEW != 0) ? (w_mask ? 24'hFFFFFF : 24'h000000) : I_data;
    wire [23:0] cv_box  = (MASK_VIEW != 0) ? 24'hFF0000 : 24'hFFFFFF;
    assign O_de   = I_de;
    assign O_vs   = I_vs;
    assign O_data = (I_cv_on && I_de) ? (r_border ? cv_box : cv_base) : I_data;

    assign O_blob_cnt     = r_collect;
    assign O_run_cnt      = r_run_cnt;
    assign O_run_overflow = r_run_overflow;
    assign O_bin_thr      = r_bin_thr;

endmodule
