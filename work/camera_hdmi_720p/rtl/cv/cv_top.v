`timescale 1ns / 1ps
//=============================================================================
// cv_top.v — 钢珠亮斑检测 + 多目标跟踪(a-b+贪心NN) + 绿框/ID 叠加（M7 Phase B）
//
// 串在 hdmi_mixer -> video_mux 间，组合直通保相位。CV 开时显示机器视角
// （二值掩膜 + 绿色 tracked 框 + ID 数字）。
//
// 流水（75MHz；vblank ~49500 周期）：
//   active: Y->阈值(上帧 Otsu+用户偏置)->mask->run 提取写 run_mem；同步累加 32-bin 直方图
//   vblank: Otsu(下帧阈值) -> CCL(简化) -> det 表 -> a-b 预测+贪心NN配对 -> 更新/老化/新建 -> track 表
//   下帧 active: 叠加 track 表（绿框+ID）
//
// 存储：run_mem=BRAM 同步读；feature/rca/det/track/hist=dram（异步读 1 级不嵌套；写同步单口）。
// 跟踪 FSM 用读->latch->写两段式避免跨拍错乱。
//
// 调参：parameter 段（a/b/gate/missed 需上板调）。
//=============================================================================
module cv_top #(
    parameter IMG_W            = 1280,
    parameter IMG_H            = 720,
    parameter [7:0]  BIN_THR   = 8'd91,   // 亮阈值回退值（MASK_SRC=0 时用）
    parameter [15:0] MIN_AREA  = 16'd20,  // 圆环面积(周长)下限
    parameter [15:0] MAX_AREA  = 16'd500,  // 圆环面积上限
    parameter [5:0]  MIN_FILL  = 6'd5,    // 圆环空心→低填充率
    parameter [5:0]  MIN_RATIO = 6'd60,   // 圆球 bbox 近正方形→高长短比
    parameter [11:0] EDGE_MG   = 12'd4,
    parameter         MAX_BLOBS = 8,
    parameter         MAX_RUNS  = 1024,
    parameter         MAX_RPR   = 32,
    parameter         MAX_LABELS= 32,
    parameter [11:0]  FBOX_W    = 12'd2,
    parameter         MASK_VIEW = 1,
    parameter         MASK_SRC  = 1,       // 1=Sobel 边缘圆环(默认); 0=亮阈值(回退对比)
    parameter [10:0]  EDGE_THR  = 11'd80,  // Sobel 幅值阈值(同 edge_detect_96)；K3/K4 调偏置
    parameter [7:0]  ALPHA_Q   = 8'd160,  // a*256 ~=0.625（位置增益）
    parameter [7:0]  BETA_Q    = 8'd48,   // b*256 ~=0.1875（速度增益）
    parameter [11:0] GATE      = 12'd80,  // 配对最大 Manhattan 距离
    parameter [3:0]  MISS_K    = 4'd8,    // 丢失几帧删轨迹
    parameter         OTSU_EN   = 1
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_cv_on,
    input  wire        I_thr_up,
    input  wire        I_thr_dn,
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
    output wire [7:0]  O_bin_thr
);
    localparam FW  = 65;
    localparam RPW = (MAX_RPR==32)?5:6;
    localparam DW  = 73;   // det: valid[72] cx[71:60] cy[59:48] minx[47:36] maxx[35:24] miny[23:12] maxy[11:0]
    localparam TW  = 105;  // track: valid[104] id[103:100] cx[99:88] cy[87:76] vx[75:64] vy[63:52]
                           //       missed[51:48] minx[47:36] maxx[35:24] miny[23:12] maxy[11:0]
    localparam NONE_ASG = 6'h3F;

    // ---------- x/y ----------
    reg [11:0] r_x, r_y; reg r_vs_d;
    wire vs_rise = I_vs & ~r_vs_d;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin r_x<=0; r_y<=0; r_vs_d<=0; end
        else begin
            r_vs_d<=I_vs;
            if (vs_rise) begin r_x<=0; r_y<=0; end
            else if (I_de) begin
                if (r_x==IMG_W-1) begin r_x<=0; r_y<=r_y+1; end else r_x<=r_x+1;
            end
        end
    end

    // ---------- 亮度 + 阈值 ----------
    wire [7:0] w_y = {2'b0,I_data[23:18]} + {1'b0,I_data[15:9]} + {2'b0,I_data[7:2]};
    reg  [7:0] r_otsu_thr, r_user_off, r_bin_thr;
    // 当前生效阈值：MASK_SRC=1(边缘)用 EDGE_THR+偏置；=0(亮阈值)用 midpoint+偏置
    wire [7:0] base_thr = MASK_SRC ? EDGE_THR[7:0] : r_otsu_thr;
    wire [8:0] thr_plus = {1'b0,base_thr} + {1'b0,r_user_off};
    wire [7:0] eff_thr  = (thr_plus>9'd255) ? 8'd255 : (thr_plus[8] ? 8'd0 : thr_plus[7:0]);

    // ---------- Sobel 边缘检测（3x3，2 行缓存，async-read BRAM，仿 edge_detect_96）----------
    //  输出 w_sobel_mag 为像素 (r_x-1, r_y-1) 的幅值（1 列+1 行延迟，整体偏移 1px 不可见）。
    (* ram_style="block" *) reg [7:0] sob_l1 [0:IMG_W-1];  // row y-1
    (* ram_style="block" *) reg [7:0] sob_l2 [0:IMG_W-1];  // row y-2
    wire [7:0] mid_word = sob_l1[r_x];   // row y-1 @ r_x（async read，旧值）
    wire [7:0] top_word = sob_l2[r_x];   // row y-2 @ r_x
    reg [7:0] top_p2, top_p1, mid_p2, mid_p1, bot_p2, bot_p1;
    // Sobel Gx/Gy @ center (r_x-1, r_y-1)
    //  窗口: top={top_p2,top_p1,top_word} mid={mid_p2,mid_p1,mid_word} bot={bot_p2,bot_p1,w_y}
    wire signed [13:0] gx = $signed({5'b0,top_p2}) + ($signed({5'b0,top_p1})<<<1) + $signed({5'b0,top_word})
                         - $signed({5'b0,bot_p2}) - ($signed({5'b0,bot_p1})<<<1) - $signed({5'b0,w_y});
    wire signed [13:0] gy = $signed({5'b0,top_p2}) + ($signed({5'b0,mid_p2})<<<1) + $signed({5'b0,bot_p2})
                         - $signed({5'b0,top_word}) - ($signed({5'b0,mid_word})<<<1) - $signed({5'b0,w_y});
    wire [13:0] abs_gx = gx[13] ? (~gx + 1) : gx;
    wire [13:0] abs_gy = gy[13] ? (~gy + 1) : gy;
    wire [14:0] w_sobel_mag = {1'b0,abs_gx} + {1'b0,abs_gy};
    wire        w_edge_mask = (r_y >= 12'd2) && (r_x >= 12'd2) && (w_sobel_mag > {4'b0, eff_thr});
    // 行缓存写+列延迟（clocked）
    always @(posedge I_clk) begin
        if (I_de) begin
            sob_l1[r_x] <= w_y;            // 当前行写 l1（下帧作 row y-1）
            sob_l2[r_x] <= mid_word;       // l1 旧值写 l2（作 row y-2）
            top_p2 <= top_p1; top_p1 <= top_word;
            mid_p2 <= mid_p1; mid_p1 <= mid_word;
            bot_p2 <= bot_p1; bot_p1 <= w_y;
        end
    end

    // ---------- 检测掩膜：MASK_SRC=1 边缘圆环；=0 亮阈值 ----------
    wire w_mask = MASK_SRC ? w_edge_mask : (w_y > eff_thr);

    // ---------- 存储 ----------
    (* ram_style="block" *) reg [33:0]  run_mem [0:MAX_RUNS-1];
    (* ram_style="dram" *)  reg [FW-1:0] feature [0:MAX_LABELS-1];
    (* ram_style="dram" *)  reg [29:0]  rca [0:2*MAX_RPR-1];
    (* ram_style="dram" *)  reg [DW-1:0] det [0:MAX_BLOBS-1];
    (* ram_style="dram" *)  reg [TW-1:0] track [0:MAX_BLOBS-1];
    // 自适应阈值：全帧 min/max Y 跟踪 -> thr=(min+max)/2（双峰场景分离 bg 与反光，适应光照；
    //   比 Otsu 省去直方图+大位宽乘除，HW 极简。Otsu 为日后升级项。）
    reg [7:0] r_min_y, r_max_y;

    reg [10:0] r_run_wr, r_run_cnt, r_run_rd; reg [33:0] r_run_rd_d;
    reg r_run_act, r_run_overflow, r_de_d; reg [11:0] r_run_xs, r_run_xe;
    wire row_last = I_de & (r_x==IMG_W-1);

    // ---------- FSM 状态 ----------
    localparam S_IDLE=4'd0, S_ADAPTIVE=4'd1, S_CLR=4'd2, S_RD=4'd3, S_SCAN=4'd4,
               S_DCOLLECT=4'd5, S_TK_START=4'd6, S_TK_SCAN=4'd7, S_TK_ASSIGN=4'd8,
               S_TU_START=4'd9, S_TU_W=4'd10, S_TU_NEW=4'd11, S_DONE=4'd12;
    reg [3:0] r_st;
    reg [10:0] r_i;
    reg [5:0]  r_next_label, r_j, r_cur_lbl, r_lv, r_collect, r_ti, r_dj, r_free;
    reg        r_found_any;
    reg        r_prev_sel; reg [5:0] r_prev_len, r_cur_len; reg [11:0] r_cur_row_y;
    // 跟踪工作寄存器
    reg [TW-1:0] r_trk_i;        // latched track[i]
    reg [DW-1:0] r_det_j;        // latched det[j] (for new-track)
    reg [5:0]  r_asg;            // assign[i] cached
    reg [11:0] r_min_cost; reg [5:0] r_min_j; reg r_min_valid;
    reg [5:0]  r_ndet;           // 检测数
    reg        r_det_taken [0:MAX_BLOBS-1];
    reg [5:0]  r_assign [0:MAX_BLOBS-1];
    reg [3:0]  r_next_id;

    assign O_ccl_busy = (r_st != S_IDLE);

    // ---------- run / CCL 字段 ----------
    wire [33:0] w_run=r_run_rd_d;
    wire [9:0]  w_ry=w_run[33:24]; wire [11:0] w_rxs=w_run[23:12], w_rxe=w_run[11:0];
    wire [11:0] w_ry_ext={2'b0,w_ry};
    wire w_row_chg=(w_ry_ext!=r_cur_row_y), w_adj=(w_ry_ext==r_cur_row_y+12'd1);
    wire [5:0] final_lbl=!r_found_any?r_next_label:r_cur_lbl;
    wire [RPW-1:0] r_j_idx=r_j[RPW-1:0];
    wire [29:0] w_prev=rca[{r_prev_sel,r_j_idx}];
    wire [11:0] w_pxs=w_prev[29:18], w_pxe=w_prev[17:6]; wire [5:0] w_plbl=w_prev[5:0];
    wire w_ovl=(w_rxs<=w_pxe)&&(w_pxs<=w_rxe), w_past=(w_pxs>w_rxe);
    // feature 读口
    wire [5:0] feat_rd=(r_st==S_DCOLLECT)?r_lv:final_lbl;
    wire [FW-1:0] feat_d=feature[feat_rd];
    wire f_valid=feat_d[64];
    wire [11:0] f_min_x=feat_d[63:52], f_max_x=feat_d[51:40], f_min_y=feat_d[39:28], f_max_y=feat_d[27:16];
    wire [15:0] f_area=feat_d[15:0];
    wire [15:0] seg_len=w_rxe-w_rxs+12'd1;
    wire [11:0] nf_min_x=!f_valid?w_rxs:((w_rxs<f_min_x)?w_rxs:f_min_x);
    wire [11:0] nf_max_x=!f_valid?w_rxe:((w_rxe>f_max_x)?w_rxe:f_max_x);
    wire [11:0] nf_min_y=!f_valid?w_ry :((w_ry <f_min_y)?w_ry :f_min_y);
    wire [11:0] nf_max_y=!f_valid?w_ry :((w_ry >f_max_y)?w_ry :f_max_y);
    wire [15:0] nf_area =!f_valid?seg_len:(f_area+seg_len);
    wire [11:0] d_cx=(f_min_x+f_max_x)>>1, d_cy=(f_min_y+f_max_y)>>1;
    wire [11:0] cf_w=f_max_x-f_min_x+1, cf_h=f_max_y-f_min_y+1;
    wire [23:0] cf_box=cf_w*cf_h;
    wire [29:0] fill_thr=MIN_FILL*cf_box;
    wire [22:0] area100=f_area*7'd100;
    wire [11:0] cf_mn=(cf_w<cf_h)?cf_w:cf_h, cf_mx=(cf_w<cf_h)?cf_h:cf_w;
    wire [18:0] ratio_num=cf_mn*7'd100; wire [17:0] ratio_den=MIN_RATIO*cf_mx;
    wire cf_edge=(f_min_x<EDGE_MG)||(f_min_y<EDGE_MG)||(f_max_x>=IMG_W-EDGE_MG)||(f_max_y>=IMG_H-EDGE_MG);
    wire w_pass=f_valid&&(f_area>=MIN_AREA)&&(f_area<=MAX_AREA)&&({9'd0,area100}>=fill_thr)&&(ratio_num>=ratio_den)&&(!cf_edge);

    // ---------- 跟踪算术（基于 latched r_trk_i / det[r_dj] async）----------
    wire        t_valid=r_trk_i[104]; wire [3:0] t_id=r_trk_i[103:100];
    wire [11:0] t_cx=r_trk_i[99:88], t_cy=r_trk_i[87:76];
    wire signed [11:0] t_vx=r_trk_i[75:64], t_vy=r_trk_i[63:52];
    wire [3:0]  t_miss=r_trk_i[51:48];
    wire [11:0] t_min_x=r_trk_i[47:36], t_max_x=r_trk_i[35:24], t_min_y=r_trk_i[23:12], t_max_y=r_trk_i[11:0];
    // 预测
    wire signed [12:0] px_s = $signed({1'b0,t_cx}) + t_vx;
    wire signed [12:0] py_s = $signed({1'b0,t_cy}) + t_vy;
    wire [11:0] px = px_s[11:0];
    wire [11:0] py = py_s[11:0];
    // det[r_dj] async 读（扫描用）
    wire [DW-1:0] det_dj_w = det[r_dj];
    wire        d_j_valid=det_dj_w[72];
    wire [11:0] d_jcx=det_dj_w[71:60], d_jcy=det_dj_w[59:48];
    // 代价（predicted track vs det j）
    wire signed [12:0] cdx = $signed({1'b0,d_jcx}) - $signed({1'b0,px});
    wire signed [12:0] cdy = $signed({1'b0,d_jcy}) - $signed({1'b0,py});
    wire signed [13:0] manh = (cdx[12]?-cdx:cdx) + (cdy[12]?-cdy:cdy);
    wire [11:0] cost = manh[13] ? 12'hFFF : (manh > GATE ? 12'hFFF : {1'b0,manh[11:1]});
    wire cost_ok = d_j_valid && !manh[13] && (manh <= GATE);
    // 更新（matched，det[r_asg] async）
    wire [DW-1:0] det_asg_w = det[r_asg];
    wire [11:0] a_jcx=det_asg_w[71:60], a_jcy=det_asg_w[59:48];
    wire [11:0] a_min_x=det_asg_w[47:36], a_max_x=det_asg_w[35:24], a_min_y=det_asg_w[23:12], a_max_y=det_asg_w[11:0];
    wire signed [12:0] rx = $signed({1'b0,a_jcx}) - $signed({1'b0,px});
    wire signed [12:0] ry = $signed({1'b0,a_jcy}) - $signed({1'b0,py});
    wire signed [21:0] ax=$signed({1'b0,ALPHA_Q})*rx, ay=$signed({1'b0,ALPHA_Q})*ry;
    wire signed [21:0] bx=$signed({1'b0,BETA_Q})*rx,  by=$signed({1'b0,BETA_Q})*ry;
    wire signed [12:0] n_cx_s=$signed({1'b0,px})+(ax>>>8);
    wire signed [12:0] n_cy_s=$signed({1'b0,py})+(ay>>>8);
    wire signed [12:0] n_vx_s=t_vx+(bx>>>8), n_vy_s=t_vy+(by>>>8);
    // 越界回绕（取低 12 位）：快运动时 cx/cy 偶发越界会回绕，画面边角偶有瑕疵，可接受。
    //   原 ternary clamp（n_cx_s[12]?0:...）TD 词法对 signed 位选+'d 字面量错乱，故简化。
    wire [11:0] n_cx=n_cx_s[11:0];
    wire [11:0] n_cy=n_cy_s[11:0];
    wire [11:0] n_vx=n_vx_s[11:0], n_vy=n_vy_s[11:0];
    wire [3:0] n_miss = t_miss + 4'd1;
    wire       t_alive = t_valid && (n_miss <= MISS_K);

    // ======================================================================
    // run 提取 + 直方图（active）
    // ======================================================================
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r_run_wr<=0; r_run_cnt<=0; r_run_act<=0; r_run_xs<=0; r_run_xe<=0;
            r_run_overflow<=0; r_de_d<=0; r_user_off<=0;
            r_min_y<=8'hFF; r_max_y<=8'h00;   // min/max 归 run extractor 管（含 reset/vs_rise/active）
        end else begin
            r_de_d<=I_de;
            if (I_thr_up && r_user_off!=8'h7F) r_user_off<=r_user_off+8'd1;
            else if (I_thr_dn && r_user_off!=8'h80) r_user_off<=r_user_off-8'd1;
            if (vs_rise) begin
                if (r_run_act && r_run_wr<MAX_RUNS) begin
                    run_mem[r_run_wr]<={r_y[9:0],r_run_xs,r_run_xe}; r_run_wr<=r_run_wr+1;
                end
                r_run_cnt<=r_run_wr; r_run_wr<=0; r_run_act<=0; r_run_overflow<=0;
                r_min_y<=8'hFF; r_max_y<=8'h00;   // min/max 复位，下帧重测
            end else if (I_cv_on && I_de) begin
                if (w_y < r_min_y) r_min_y <= w_y;
                if (w_y > r_max_y) r_max_y <= w_y;
                if (row_last && r_run_act) begin
                    r_run_xe<=r_x;
                    if (r_run_wr<MAX_RUNS) begin run_mem[r_run_wr]<={r_y[9:0],r_run_xs,r_run_xe}; r_run_wr<=r_run_wr+1; end else r_run_overflow<=1;
                    r_run_act<=0;
                end else begin
                    if (w_mask) begin
                        if (!r_run_act) begin r_run_act<=1; r_run_xs<=r_x; r_run_xe<=r_x; end else r_run_xe<=r_x;
                    end else if (r_run_act) begin
                        if (r_run_wr<MAX_RUNS) begin run_mem[r_run_wr]<={r_y[9:0],r_run_xs,r_run_xe}; r_run_wr<=r_run_wr+1; end else r_run_overflow<=1;
                        r_run_act<=0;
                    end
                end
            end
        end
    end
    always @(posedge I_clk) begin r_run_rd_d <= run_mem[r_run_rd]; end

    // ======================================================================
    // 主 FSM
    // ======================================================================
    integer k;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r_st<=S_IDLE; r_i<=0; r_run_rd<=0; r_next_label<=0; r_prev_sel<=0;
            r_prev_len<=0; r_cur_len<=0; r_cur_row_y<=12'h7FF; r_j<=0; r_cur_lbl<=0;
            r_found_any<=0; r_lv<=0; r_collect<=0; r_ti<=0; r_dj<=0; r_free<=0;
            r_otsu_thr<=BIN_THR; r_bin_thr<=BIN_THR;   // 阈值归主 FSM 管（S_ADAPTIVE + reset）
            r_trk_i<=0; r_det_j<=0; r_asg<=NONE_ASG; r_min_cost<=0; r_min_j<=0; r_min_valid<=0;
            r_ndet<=0; r_next_id<=0;
            for (k=0;k<MAX_BLOBS;k=k+1) begin r_det_taken[k]<=0; r_assign[k]<=NONE_ASG; end
        end else begin
            case (r_st)
                S_IDLE: if (vs_rise) r_st<=S_ADAPTIVE;

                // 自适应阈值：midpoint = (min+max)/2（用上帧 min/max，下帧用）
                S_ADAPTIVE: begin
                    r_otsu_thr <= (r_min_y + r_max_y) >> 1;
                    r_bin_thr  <= OTSU_EN ? ((r_min_y + r_max_y) >> 1) : BIN_THR;
                    r_lv<=0; r_st<=S_CLR;
                end

                // ---- 清 feature / det_taken / assign / det 表 ----
                S_CLR: begin
                    feature[r_lv]<={1'b0,12'hFFF,12'h000,12'hFFF,12'h000,16'd0};
                    if (r_lv<MAX_BLOBS) begin r_det_taken[r_lv]<=0; r_assign[r_lv]<=NONE_ASG; det[r_lv]<={1'b0,72'd0}; end
                    if (r_lv==MAX_LABELS-1) begin
                        r_lv<=0; r_i<=0; r_next_label<=0; r_prev_sel<=0;
                        r_prev_len<=0; r_cur_len<=0; r_cur_row_y<=12'h7FF; r_collect<=0; r_ndet<=0;
                        r_st<=S_RD;
                    end else r_lv<=r_lv+1;
                end

                S_RD: if (r_i>=r_run_cnt) begin r_lv<=0; r_collect<=0; r_st<=S_DCOLLECT; end
                      else begin r_run_rd<=r_i; r_j<=0; r_found_any<=0; r_cur_lbl<=0; r_st<=S_SCAN; end

                S_SCAN: begin
                    if (w_row_chg) begin
                        r_prev_sel<=~r_prev_sel; r_prev_len<=w_adj?r_cur_len:0;
                        r_cur_len<=0; r_cur_row_y<=w_ry_ext; r_j<=0;
                    end else if (r_j<r_prev_len) begin
                        if (w_ovl) begin if(!r_found_any) begin r_cur_lbl<=w_plbl; r_found_any<=1; end r_j<=r_j+1; end
                        else if (w_past) r_j<=r_prev_len;
                        else r_j<=r_j+1;
                    end else begin
                        feature[final_lbl]<={1'b1,nf_min_x,nf_max_x,nf_min_y,nf_max_y,nf_area};
                        if (r_cur_len<MAX_RPR) rca[{~r_prev_sel,r_cur_len[RPW-1:0]}]<={w_rxs,w_rxe,final_lbl};
                        r_cur_len<=r_cur_len+1;
                        if (!r_found_any && r_next_label<MAX_LABELS) r_next_label<=r_next_label+1;
                        r_i<=r_i+1; r_st<=S_RD;
                    end
                end

                S_DCOLLECT: if (r_lv==MAX_LABELS) begin r_lv<=0; r_ti<=0; r_dj<=0; r_free<=0; r_st<=S_TK_START; end
                    else begin
                        if (w_pass && r_collect<MAX_BLOBS) begin
                            det[r_collect]<={1'b1,d_cx,d_cy,f_min_x,f_max_x,f_min_y,f_max_y};
                            r_collect<=r_collect+1; r_ndet<=r_ndet+1;
                        end
                        r_lv<=r_lv+1;
                    end

                // ---- 跟踪：每 track 读->latch，扫描 det 找最近 ----
                S_TK_START: begin
                    r_trk_i <= track[r_ti];
                    r_min_cost<=12'hFFF; r_min_j<=0; r_min_valid<=0; r_dj<=0;
                    r_st<=S_TK_SCAN;
                end
                S_TK_SCAN: if (r_dj<MAX_BLOBS) begin
                    if (cost_ok && cost<r_min_cost) begin
                        r_min_cost<=cost; r_min_j<=r_dj; r_min_valid<=1;
                    end
                    r_dj<=r_dj+1;
                end else begin
                    if (r_min_valid && !r_det_taken[r_min_j]) begin
                        r_assign[r_ti]<=r_min_j; r_det_taken[r_min_j]<=1'b1;
                    end else r_assign[r_ti]<=NONE_ASG;
                    if (r_ti==MAX_BLOBS-1) begin r_ti<=0; r_st<=S_TU_START; end
                    else begin r_ti<=r_ti+1; r_st<=S_TK_START; end
                end

                // ---- 更新：每 track 读->latch，按 assign 写回 ----
                S_TU_START: begin
                    r_trk_i<=track[r_ti]; r_asg<=r_assign[r_ti]; r_st<=S_TU_W;
                end
                S_TU_W: begin
                    if (t_valid) begin
                        if (r_asg!=NONE_ASG) begin
                            // matched：a-b 更新 + 新 bbox
                            track[r_ti]<={1'b1,t_id,n_cx,n_cy,n_vx,n_vy,4'd0,a_min_x,a_max_x,a_min_y,a_max_y};
                        end else begin
                            // coast：预测推进 + 老化
                            track[r_ti]<={t_alive, t_id, px, py, t_vx[11:0], t_vy[11:0], n_miss,
                                          t_min_x,t_max_x,t_min_y,t_max_y};
                        end
                    end
                    if (r_ti==MAX_BLOBS-1) begin r_ti<=0; r_dj<=0; r_free<=0; r_st<=S_TU_NEW; end
                    else begin r_ti<=r_ti+1; r_st<=S_TU_START; end
                end

                // ---- 新建：未占 det 找空 track 槽写入 ----
                S_TU_NEW: begin
                    if (r_dj>=MAX_BLOBS || r_free>=MAX_BLOBS) begin
                        r_st<=S_DONE;
                    end else begin
                        // 取 det[r_dj]（async），若有效且未占 -> 找 free 槽
                        if (det[r_dj][72] && !r_det_taken[r_dj]) begin
                            if (!track[r_free][104]) begin
                                // 写新轨迹
                                track[r_free]<={1'b1, r_next_id, det[r_dj][71:60], det[r_dj][59:48],
                                                12'd0, 12'd0, 4'd0,
                                                det[r_dj][47:36], det[r_dj][35:24], det[r_dj][23:12], det[r_dj][11:0]};
                                r_next_id<=r_next_id+1;
                                r_dj<=r_dj+1; r_free<=r_free+1;
                            end else r_free<=r_free+1;
                        end else r_dj<=r_dj+1;
                    end
                end

                S_DONE: r_st<=S_IDLE;

                default: r_st<=S_IDLE;
            endcase
        end
    end

    // 注：O_blob_cnt 上报 r_collect（本帧检测数，非轨迹数）——轨迹数需扫 track 表，
    //     当前简化用检测数；跟踪效果看绿框 ID 连续性（视觉）而非 NB。

    // ======================================================================
    // 叠加：track 表（绿框 + ID 数字）
    // ======================================================================
    function [4:0] f_digit;
        input [3:0] id; input [2:0] row;
        begin
            case(id)
                4'd0: case(row) 0:f_digit=5'b01110;1:f_digit=5'b10001;2:f_digit=5'b10011;3:f_digit=5'b10101;4:f_digit=5'b11001;5:f_digit=5'b10001;6:f_digit=5'b01110;default:f_digit=0;endcase
                4'd1: case(row) 0:f_digit=5'b00100;1:f_digit=5'b01100;2:f_digit=5'b00100;3:f_digit=5'b00100;4:f_digit=5'b00100;5:f_digit=5'b00100;6:f_digit=5'b01110;default:f_digit=0;endcase
                4'd2: case(row) 0:f_digit=5'b01110;1:f_digit=5'b10001;2:f_digit=5'b00001;3:f_digit=5'b00010;4:f_digit=5'b00100;5:f_digit=5'b01000;6:f_digit=5'b11111;default:f_digit=0;endcase
                4'd3: case(row) 0:f_digit=5'b11110;1:f_digit=5'b00001;2:f_digit=5'b00001;3:f_digit=5'b01110;4:f_digit=5'b00001;5:f_digit=5'b00001;6:f_digit=5'b11110;default:f_digit=0;endcase
                4'd4: case(row) 0:f_digit=5'b00010;1:f_digit=5'b00110;2:f_digit=5'b01010;3:f_digit=5'b10010;4:f_digit=5'b11111;5:f_digit=5'b00010;6:f_digit=5'b00010;default:f_digit=0;endcase
                4'd5: case(row) 0:f_digit=5'b11111;1:f_digit=5'b10000;2:f_digit=5'b11110;3:f_digit=5'b00001;4:f_digit=5'b00001;5:f_digit=5'b10001;6:f_digit=5'b01110;default:f_digit=0;endcase
                4'd6: case(row) 0:f_digit=5'b00110;1:f_digit=5'b01000;2:f_digit=5'b10000;3:f_digit=5'b11110;4:f_digit=5'b10001;5:f_digit=5'b10001;6:f_digit=5'b01110;default:f_digit=0;endcase
                4'd7: case(row) 0:f_digit=5'b11111;1:f_digit=5'b00001;2:f_digit=5'b00010;3:f_digit=5'b00100;4:f_digit=5'b01000;5:f_digit=5'b01000;6:f_digit=5'b01000;default:f_digit=0;endcase
                4'd8: case(row) 0:f_digit=5'b01110;1:f_digit=5'b10001;2:f_digit=5'b10001;3:f_digit=5'b01110;4:f_digit=5'b10001;5:f_digit=5'b10001;6:f_digit=5'b01110;default:f_digit=0;endcase
                4'd9: case(row) 0:f_digit=5'b01110;1:f_digit=5'b10001;2:f_digit=5'b10001;3:f_digit=5'b01111;4:f_digit=5'b00001;5:f_digit=5'b00010;6:f_digit=5'b11100;default:f_digit=0;endcase
                4'ha: case(row) 0:f_digit=5'b01110;1:f_digit=5'b10001;2:f_digit=5'b10001;3:f_digit=5'b11111;4:f_digit=5'b10001;5:f_digit=5'b10001;6:f_digit=5'b10001;default:f_digit=0;endcase
                4'hb: case(row) 0:f_digit=5'b11110;1:f_digit=5'b10001;2:f_digit=5'b10001;3:f_digit=5'b11110;4:f_digit=5'b10001;5:f_digit=5'b10001;6:f_digit=5'b11110;default:f_digit=0;endcase
                4'hc: case(row) 0:f_digit=5'b01110;1:f_digit=5'b10001;2:f_digit=5'b10000;3:f_digit=5'b10000;4:f_digit=5'b10000;5:f_digit=5'b10001;6:f_digit=5'b01110;default:f_digit=0;endcase
                4'hd: case(row) 0:f_digit=5'b11110;1:f_digit=5'b10001;2:f_digit=5'b10001;3:f_digit=5'b10001;4:f_digit=5'b10001;5:f_digit=5'b10001;6:f_digit=5'b11110;default:f_digit=0;endcase
                4'he: case(row) 0:f_digit=5'b11111;1:f_digit=5'b10000;2:f_digit=5'b10000;3:f_digit=5'b11110;4:f_digit=5'b10000;5:f_digit=5'b10000;6:f_digit=5'b11111;default:f_digit=0;endcase
                4'hf: case(row) 0:f_digit=5'b11111;1:f_digit=5'b10000;2:f_digit=5'b10000;3:f_digit=5'b11110;4:f_digit=5'b10000;5:f_digit=5'b10000;6:f_digit=5'b10000;default:f_digit=0;endcase
                default: f_digit=0;
            endcase
        end
    endfunction

    integer oi;
    reg r_border, r_digit;
    reg [4:0] dg_bits;
    reg [11:0] dg_row, dg_col;
    always @(*) begin
        r_border=1'b0; r_digit=1'b0;
        for (oi=0; oi<MAX_BLOBS; oi=oi+1) begin
            if (track[oi][104]) begin
                if ((((r_x>=track[oi][47:36])&&(r_x<track[oi][47:36]+FBOX_W)) ||
                     ((r_x<=track[oi][35:24])&&(r_x>track[oi][35:24]-FBOX_W))) &&
                    (r_y>=track[oi][23:12])&&(r_y<=track[oi][11:0])) r_border=1;
                if ((((r_y>=track[oi][23:12])&&(r_y<track[oi][23:12]+FBOX_W)) ||
                     ((r_y<=track[oi][11:0])&&(r_y>track[oi][11:0]-FBOX_W))) &&
                    (r_x>=track[oi][47:36])&&(r_x<=track[oi][35:24])) r_border=1;
                // ID 数字（左上角 5x7）：用临时 reg 存函数结果再 bit-select（TD 不允许函数调用直接索引）
                if (r_x>=track[oi][47:36] && r_x<track[oi][47:36]+5 &&
                    r_y>=track[oi][23:12] && r_y<track[oi][23:12]+7) begin
                    dg_row  = r_y - track[oi][23:12];
                    dg_col  = r_x - track[oi][47:36];
                    dg_bits = f_digit(track[oi][103:100], dg_row[2:0]);
                    if (dg_bits[4 - dg_col[2:0]]) r_digit=1;
                end
            end
        end
    end

    wire [23:0] cv_base = (MASK_VIEW!=0) ? (w_mask ? 24'hFFFFFF : 24'h000000) : I_data;
    assign O_de=I_de; assign O_vs=I_vs;
    assign O_data = (I_cv_on && I_de) ? (r_digit ? 24'hFFFFFF : (r_border ? 24'h00FF00 : cv_base)) : I_data;
    assign O_blob_cnt = r_collect;
    assign O_run_cnt = r_run_cnt;
    assign O_run_overflow = r_run_overflow;
    assign O_bin_thr = OTSU_EN ? eff_thr : r_bin_thr;

endmodule
