`timescale 1ns / 1ps
//=============================================================================
// cv_top.v — 钢珠亮斑检测 + 白框叠加（M7 / Phase A，单帧检测无跟踪）
//
// 串在 hdmi_mixer → video_mux 之间。组合直通（O_de/O_vs/O_data 与输入同拍，
// 不引入额外寄存器级数，保持 M6 的 pattern/camera +3 同相对齐）。
// I_cv_on=1 时在视频上叠加白色 bbox 边框。
//
// 存储实现说明（TD 兼容性）：
//   run_mem / label_ram：unpacked 数组 + ram_style="block"（同步读，BRAM，无问题）。
//   feature/parent/rca/ov：用 packed reg 向量 + 变址 part-select（+:）。
//     原因：这些表需要「异步变址读」（filter/RMW/f_find 的 parent[t]=parent[parent[..]]
//     6 层嵌套异步读）。若用 unpacked 数组，TD 推断为 RAM 异步读口，Map Macro 阶段
//     coredump。packed 向量把这些访问综合成 mux/逻辑（嵌套读=嵌套 mux），TD 可综合。
//
// 调参：见 parameter 段（编译期，改完 run.bat 重建）。每个参数有【调参N】标注。
//=============================================================================
module cv_top #(
    parameter IMG_W            = 1280,
    parameter IMG_H            = 720,
    parameter [7:0]  BIN_THR   = 8'd120,  // 【调参1】亮度阈值(0..255)，Y>此值判为亮
    parameter [15:0] MIN_AREA  = 16'd8,   // 【调参2】blob 最小像素数，小于则丢
    parameter [15:0] MAX_AREA  = 16'd20000, // 【调参3】blob 最大像素数，大于则丢
    parameter [5:0]  MIN_FILL  = 6'd15,   // 【调参4】最小填充率%(area*100/box)
    parameter [5:0]  MIN_RATIO = 6'd25,   // 【调参5】最小长短比%(min(w,h)*100/max(w,h))
    parameter [11:0] EDGE_MG   = 12'd4,   // 【调参6】贴边剔除 margin(px)
    parameter         MAX_BLOBS = 32,
    parameter         MAX_RUNS  = 1024,
    parameter         MAX_RPR   = 32,
    parameter         MAX_LABELS= 64,
    parameter [11:0]  FBOX_W    = 12'd2
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_cv_on,
    input  wire        I_de,
    input  wire        I_vs,
    input  wire [23:0] I_data,
    output wire        O_de,
    output wire        O_vs,
    output wire [23:0] O_data,
    output wire [5:0]  O_blob_cnt,
    output wire [10:0] O_run_cnt,
    output wire        O_ccl_busy,
    output wire        O_run_overflow
);
    localparam FW = 1 + 12 + 12 + 12 + 12 + 16; // 65  feature entry 宽
    localparam PW = 6;                          // parent entry 宽
    localparam RW = 30;                         // rca entry 宽 {xs,xe,label}
    localparam OW = 49;                         // ov entry 宽 {valid,min_x,max_x,min_y,max_y}
    localparam RPW = (MAX_RPR == 32) ? 5 : 6;   // r_j 索引位宽

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
    // 亮度 + 阈值
    // ======================================================================
    wire [7:0] w_y =
        {2'b0, I_data[23:18]} + {1'b0, I_data[15:9]} + {2'b0, I_data[7:2]};
    wire       w_mask = (w_y > BIN_THR);

    // ======================================================================
    // BRAM 存储（同步读）
    // ======================================================================
    (* ram_style = "block" *) reg [33:0] run_mem   [0:MAX_RUNS-1];    // {y,xs,xe}
    (* ram_style = "block" *) reg [5:0]  label_ram [0:MAX_RUNS-1];    // provisional label/run
    reg [10:0] r_run_wr, r_run_cnt;
    reg        r_run_act, r_run_overflow, r_de_d;
    reg [11:0] r_run_xs, r_run_xe;
    wire       row_last = I_de & (r_x == IMG_W - 1);
    reg [10:0] r_run_rd;   reg [33:0] r_run_rd_d;
    reg [10:0] r_lbl_rd;   reg [5:0]  r_lbl_rd_d;

    // packed 寄存器向量（mux/逻辑，避免 RAM 异步读推断崩溃）
    reg [FW*MAX_LABELS-1:0]  feature_v;   // feature_v[l*FW +: FW] = {valid,min_x,max_x,min_y,max_y,area}
    reg [PW*MAX_LABELS-1:0]  parent_v;    // parent_v[l*PW +: PW]
    reg [RW*(2*MAX_RPR)-1:0] rca_v;       // rca_v[idx*RW +: RW]，idx={sel,j[RPW-1:0]}
    reg [OW*MAX_BLOBS-1:0]   ov_v;        // ov_v[b*OW +: OW]

    // FSM 状态
    localparam S_IDLE=4'd0, S_INIT=4'd1, S_RD=4'd2, S_SCAN=4'd3,
               S_RESOLVE=4'd4, S_ACCUM=4'd5, S_ACCUM2=4'd6,
               S_COLLECT=4'd7, S_DONE=4'd8;
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

    // ---- prev 行当前条目（rca_v 读）----
    wire [RPW-1:0] r_j_idx = r_j[RPW-1:0];
    wire [5:0]     prev_idx = {r_prev_sel, r_j_idx};
    wire [RW-1:0]  w_prev = rca_v[prev_idx*RW +: RW];
    wire [11:0]    w_pxs  = w_prev[29:18];
    wire [11:0]    w_pxe  = w_prev[17:6];
    wire [5:0]     w_plbl = w_prev[5:0];
    wire           w_ovl  = (w_rxs <= w_pxe) && (w_pxs <= w_rxe);
    wire           w_past = (w_pxs > w_rxe);
    wire [11:0]    w_ry_ext = {2'b0, w_ry};
    wire           w_row_chg = (w_ry_ext != r_cur_row_y);
    wire           w_adj     = (w_ry_ext == r_cur_row_y + 12'd1);

    // ---- ACCUM：acc_root=parent_v[acc_lbl]；feature_v[acc_root] RMW ----
    wire [5:0]  acc_lbl  = r_lbl_rd_d;
    wire [5:0]  acc_root = parent_v[acc_lbl*PW +: PW];
    wire [FW-1:0] af_entry = feature_v[acc_root*FW +: FW];
    wire        af_valid = af_entry[64];
    wire [11:0] af_min_x = af_entry[63:52];
    wire [11:0] af_max_x = af_entry[51:40];
    wire [11:0] af_min_y = af_entry[39:28];
    wire [11:0] af_max_y = af_entry[27:16];
    wire [15:0] af_area  = af_entry[15:0];
    wire [15:0] seg_len  = w_rxe - w_rxs + 12'd1;
    wire [11:0] af_n_min_x = (!af_valid) ? w_rxs : ((w_rxs < af_min_x) ? w_rxs : af_min_x);
    wire [11:0] af_n_max_x = (!af_valid) ? w_rxe : ((w_rxe > af_max_x) ? w_rxe : af_max_x);
    wire [11:0] af_n_min_y = (!af_valid) ? w_ry  : ((w_ry  < af_min_y) ? w_ry  : af_min_y);
    wire [11:0] af_n_max_y = (!af_valid) ? w_ry  : ((w_ry  > af_max_y) ? w_ry  : af_max_y);
    wire [15:0] af_n_area  = (!af_valid) ? seg_len : (af_area + seg_len);

    // ---- COLLECT：feature_v[r_lv] ----
    wire [FW-1:0] cf_feat   = feature_v[r_lv*FW +: FW];
    wire        cf_valid  = cf_feat[64];
    wire [11:0] cf_min_x  = cf_feat[63:52];
    wire [11:0] cf_max_x  = cf_feat[51:40];
    wire [11:0] cf_min_y  = cf_feat[39:28];
    wire [11:0] cf_max_y  = cf_feat[27:16];
    wire [15:0] cf_area   = cf_feat[15:0];
    wire [11:0] cf_w = cf_max_x - cf_min_x + 12'd1;
    wire [11:0] cf_h = cf_max_y - cf_min_y + 12'd1;
    wire [23:0] cf_box    = cf_w * cf_h;
    wire [29:0] fill_thr  = MIN_FILL * cf_box;
    wire [22:0] area100   = cf_area * 7'd100;
    wire [11:0] cf_mn = (cf_w < cf_h) ? cf_w : cf_h;
    wire [11:0] cf_mx = (cf_w < cf_h) ? cf_h : cf_w;
    wire [18:0] ratio_num = cf_mn * 7'd100;
    wire [17:0] ratio_den = MIN_RATIO * cf_mx;
    wire        cf_edge = (cf_min_x < EDGE_MG) || (cf_min_y < EDGE_MG) ||
                          (cf_max_x >= IMG_W - EDGE_MG) || (cf_max_y >= IMG_H - EDGE_MG);
    wire        cf_root  = (parent_v[r_lv*PW +: PW] == r_lv);
    wire        w_pass = cf_valid && cf_root &&
                         (cf_area >= MIN_AREA) && (cf_area <= MAX_AREA) &&
                         ({9'd0, area100} >= fill_thr) &&
                         (ratio_num >= ratio_den) && (!cf_edge);

    // union-find find（packed，嵌套 mux 读）
    function [5:0] f_find;
        input [5:0] a;
        reg  [5:0] t;
        integer k;
        begin
            t = a;
            for (k = 0; k < 6; k = k + 1) t = parent_v[t*PW +: PW];
            f_find = t;
        end
    endfunction

    // ======================================================================
    // run 提取（active 写 run_mem）
    // ======================================================================
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r_run_wr <= 11'd0; r_run_cnt <= 11'd0; r_run_act <= 1'b0;
            r_run_xs <= 12'd0; r_run_xe <= 12'd0; r_run_overflow <= 1'b0; r_de_d <= 1'b0;
        end else begin
            r_de_d <= I_de;
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

    // BRAM 同步读
    always @(posedge I_clk) begin
        r_run_rd_d <= run_mem[r_run_rd];
        r_lbl_rd_d <= label_ram[r_lbl_rd];
    end

    // ======================================================================
    // CCL FSM
    // ======================================================================
    integer gi;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r_st <= S_IDLE; r_i <= 11'd0; r_run_rd <= 11'd0; r_lbl_rd <= 11'd0;
            r_next_label <= 6'd0; r_prev_sel <= 1'b0;
            r_prev_len <= 6'd0; r_cur_len <= 6'd0; r_cur_row_y <= 12'h7FF;
            r_j <= 6'd0; r_cur_lbl <= 6'd0; r_found_any <= 1'b0;
            r_lv <= 6'd0; r_collect <= 6'd0;
            feature_v <= {FW*MAX_LABELS{1'b0}};
            parent_v  <= {PW*MAX_LABELS{1'b0}};
            rca_v     <= {RW*(2*MAX_RPR){1'b0}};
            ov_v      <= {OW*MAX_BLOBS{1'b0}};
        end else begin
            case (r_st)
                S_IDLE: if (vs_rise) r_st <= S_INIT;

                S_INIT: begin
                    feature_v[r_lv*FW +: FW] <= {1'b0, 12'hFFF, 12'h000, 12'hFFF, 12'h000, 16'd0};
                    parent_v[r_lv*PW +: PW]  <= r_lv;
                    if (r_lv < MAX_BLOBS) ov_v[r_lv*OW +: OW] <= {1'b0, 48'd0};
                    if (r_lv == MAX_LABELS - 1) begin
                        r_lv <= 6'd0; r_i <= 11'd0;
                        r_next_label <= 6'd0; r_prev_sel <= 1'b0;
                        r_prev_len <= 6'd0; r_cur_len <= 6'd0; r_cur_row_y <= 12'h7FF;
                        r_st <= S_RD;
                    end else r_lv <= r_lv + 6'd1;
                end

                S_RD: begin
                    if (r_i >= r_run_cnt) begin
                        r_lv <= 6'd0; r_st <= S_RESOLVE;
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
                            end else if (f_find(w_plbl) != f_find(r_cur_lbl)) begin
                                if (f_find(w_plbl) < f_find(r_cur_lbl))
                                    parent_v[f_find(r_cur_lbl)*PW +: PW] <= f_find(w_plbl);
                                else
                                    parent_v[f_find(w_plbl)*PW +: PW] <= f_find(r_cur_lbl);
                            end
                            r_j <= r_j + 6'd1;
                        end else if (w_past) begin
                            r_j <= r_prev_len;
                        end else begin
                            r_j <= r_j + 6'd1;
                        end
                    end else begin
                        if (!r_found_any) begin
                            if (r_next_label < MAX_LABELS) begin
                                r_cur_lbl <= r_next_label;
                                r_next_label <= r_next_label + 6'd1;
                            end else r_cur_lbl <= 6'd0;
                        end else begin
                            r_cur_lbl <= f_find(r_cur_lbl);
                        end
                        if (r_cur_len < MAX_RPR)
                            rca_v[{~r_prev_sel, r_cur_len[RPW-1:0]}*RW +: RW] <= {w_rxs, w_rxe, r_cur_lbl};
                        r_cur_len <= r_cur_len + 6'd1;
                        label_ram[r_i] <= r_cur_lbl;
                        r_i <= r_i + 11'd1;
                        r_st <= S_RD;
                    end
                end

                S_RESOLVE: begin
                    parent_v[r_lv*PW +: PW] <= f_find(r_lv);
                    if (r_lv == MAX_LABELS - 1) begin
                        r_lv <= 6'd0; r_i <= 11'd0; r_st <= S_ACCUM;
                    end else r_lv <= r_lv + 6'd1;
                end

                S_ACCUM: begin
                    if (r_i >= r_run_cnt) begin
                        r_lv <= 6'd0; r_collect <= 6'd0; r_st <= S_COLLECT;
                    end else begin
                        r_run_rd <= r_i;
                        r_lbl_rd <= r_i;
                        r_st <= S_ACCUM2;
                    end
                end

                S_ACCUM2: begin
                    feature_v[acc_root*FW +: FW] <= {1'b1, af_n_min_x, af_n_max_x, af_n_min_y, af_n_max_y, af_n_area};
                    r_i <= r_i + 11'd1;
                    r_st <= S_ACCUM;
                end

                S_COLLECT: begin
                    if (r_lv == MAX_LABELS) begin
                        r_st <= S_DONE;
                    end else begin
                        if (w_pass && (r_collect < MAX_BLOBS)) begin
                            ov_v[r_collect*OW +: OW] <= {1'b1, cf_min_x, cf_max_x, cf_min_y, cf_max_y};
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
    // 叠加：MAX_BLOBS 路 bbox 并行比较（ov_v 常量变址 → 并行 bit-select）
    // ======================================================================
    reg r_border;
    always @(*) begin
        r_border = 1'b0;
        for (gi = 0; gi < MAX_BLOBS; gi = gi + 1) begin
            // ov_v[gi*OW +: OW] 常量变址（gi 展开为常量）→ 每路独立 bit-select
            if (ov_v[gi*OW + 48]) begin
                if ((((r_x >= ov_v[gi*OW + 36 +: 12]) && (r_x < ov_v[gi*OW + 36 +: 12] + FBOX_W)) ||
                     ((r_x <= ov_v[gi*OW + 24 +: 12]) && (r_x > ov_v[gi*OW + 24 +: 12] - FBOX_W))) &&
                    (r_y >= ov_v[gi*OW + 12 +: 12]) && (r_y <= ov_v[gi*OW +: 12]))
                    r_border = 1'b1;
                if ((((r_y >= ov_v[gi*OW + 12 +: 12]) && (r_y < ov_v[gi*OW + 12 +: 12] + FBOX_W)) ||
                     ((r_y <= ov_v[gi*OW +: 12]) && (r_y > ov_v[gi*OW +: 12] - FBOX_W))) &&
                    (r_x >= ov_v[gi*OW + 36 +: 12]) && (r_x <= ov_v[gi*OW + 24 +: 12]))
                    r_border = 1'b1;
            end
        end
    end

    // ======================================================================
    // 输出
    // ======================================================================
    assign O_de   = I_de;
    assign O_vs   = I_vs;
    assign O_data = (I_cv_on && r_border && I_de) ? 24'hFFFFFF : I_data;

    assign O_blob_cnt     = r_collect;
    assign O_run_cnt      = r_run_cnt;
    assign O_run_overflow = r_run_overflow;

endmodule
