`timescale 1ns / 1ps
//=============================================================================
// cv_blkdet.v — 块域(16x16)暗块检测 + 块级连通标记 + 按直径合并碎片
//
//   1280x720 --(16x16 块均值 < DARK_THR)--> 80x45 暗块掩膜 --(块级光栅标记)--> 连通块
//   块域只有 3600 单元、blob 少而大；标记确定、简单、资源小，绕开 cv_top 的像素级 CCL。
//
//   标记：光栅扫描；块 (bx,by) 取【左邻居标签】优先，否则【上邻居标签】，都无则新标签。
//   分组：钢珠直径 151px -> 约 9 个块单元。连通块只当碎片，按"并集包围盒 <= 13x13 块"
//         合并；任意数量碎片都会进入同一分组。分组支撑面积、短边、长边达标后输出
//         固定 10x10 块（160x160 px）识别框；长边不足 7 块的阴影与 14x14 以上大团块剔除。
//   输出：像素坐标检测框（块坐标 x16），最多 MAX_BLOBS 个。
//=============================================================================
module cv_blkdet #(
    parameter IMG_W = 1280,
    parameter IMG_H = 720,
    parameter BW    = 80,
    parameter BH    = 45,
    parameter LABW  = 7,                    // 标签位宽
    parameter [10:0] DARK_THR = 11'd100,
    parameter [7:0]  CB_DELTA = 8'd20,      // 局部对比：块均值须低于大格背景这么多
    parameter [15:0] FRAG_MIN_BLKN = 16'd3, // 碎片最小面积(块)
    parameter [15:0] MIN_BLKN = 16'd14,     // 分组最小支撑面积(块)
    parameter [15:0] MAX_BLKN = 16'd400,    // 单连通块面积上限(块)
    parameter [7:0]  MAX_RAWWH = 8'd36,     // 单连通块宽/高上限(块)
    parameter [7:0]  GROUP_MAXWH = 8'd13,   // 一颗钢珠分组的最大宽/高(块)
    parameter [7:0]  GROUP_MIN_SIDE = 8'd4, // 分组短边下限(块)，剔除细长残片
    parameter [7:0]  GROUP_MIN_LONG = 8'd7, // 分组长边下限(块)，剔除 5x5/6x6 阴影与纹理小块
    parameter [7:0]  SPLIT_SIDE = 8'd15,    // 接触钢珠拆分长边门限(块)
    parameter [7:0]  SPLIT_MIN_SIDE = 8'd6, // 拆分短边下限(块)
    parameter [11:0] BOX_HALF = 12'd80,     // 固定识别框半边长(px)，10 块=160px
    parameter [11:0] ROI_Y0 = 12'd200,      // 上方纹理区不输出识别框，保留左侧入场高度
    parameter        MAX_GROUPS = 8,        // 分组表深度：一颗钢珠一条，与输出槽位一致
    parameter        MAX_BLOBS= 8
)(
    input             clk,
    input             rst_n,
    input             de,
    input             vs,
    input      [23:0] rgb,
    input      [2:0]  i_sel,                 // 选择输出第几个检测框
    input             i_wide,                // 高阈值(亮场景)：放宽块宽/高与填充率
    output reg        o_ready,               // 检测表就绪(保持到下次 vs)
    output reg [5:0]  o_count,
    output     [47:0] o_det_box,             // 第 i_sel 个框 {minx,maxx,miny,maxy} 像素坐标
    output wire       o_mask_bit             // 上一帧同块的暗块掩膜位(1=暗块)
);
    // TD 不允许数组端口/端口直访数组 -> 内部存储 + 选择线读出
    reg [47:0] box_mem [0:MAX_BLOBS-1];
    assign o_det_box = box_mem[i_sel];
    localparam FW = 1 + 4*12 + 16;          // valid + minx/maxx/miny/maxy(像素,12b) + area(块数)

    // ---------------- 灰度 + 坐标 ----------------
    wire [7:0] w_y = {2'b0,rgb[23:18]} + {1'b0,rgb[15:9]} + {2'b0,rgb[7:2]};
    reg [11:0] r_x, r_y; reg r_vs_d;
    wire vs_rise = vs & ~r_vs_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin r_x<=0; r_y<=0; r_vs_d<=0; end
        else begin
            r_vs_d<=vs;
            if (vs_rise) begin r_x<=0; r_y<=0; end
            else if (de) begin if (r_x==IMG_W-1) begin r_x<=0; r_y<=r_y+1; end else r_x<=r_x+1; end
        end
    end

    // ---------------- 16x16 块均值（两级累加）----------------
    reg [15:0] acc_row;
    reg [15:0] col_acc [0:BW-1];
    reg        col_we; reg [6:0] col_wa; reg [15:0] col_wd;
    wire        rowblk_end = de && (r_x[3:0]==4'hF);
    wire        blkrow_end = (r_y[3:0]==4'hF);
    wire [15:0] row_sum    = acc_row + {8'b0, w_y};
    wire [15:0] col_cur    = col_acc[r_x[11:4]];
    wire [15:0] blk_total  = col_cur + row_sum;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) acc_row <= 16'd0;
        else if (de) acc_row <= rowblk_end ? 16'd0 : (acc_row + {8'b0, w_y});
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) col_we <= 1'b0;
        else begin
            col_we <= rowblk_end;
            if (rowblk_end) begin col_wa <= r_x[11:4]; col_wd <= blkrow_end ? 16'd0 : (col_cur + row_sum); end
        end
    end
    always @(posedge clk) if (col_we) col_acc[col_wa] <= col_wd;

    // ---------------- 80x45 块掩膜（5 帧背景差分）----------------
    //   块均值须低于"5 帧前的同一块" CB_DELTA 才判暗：
    //   静止的桌沿/木纹/边角在 5 帧前也暗 -> 抑制；
    //   球离开旧位置后，当前位置与 5 帧前必然不同 -> 检出
    //   （避免上一帧 128x128 大格背景把快球/并排球吞掉）。
    localparam BG_FRAMES = 5;
    wire [7:0]  blk_bm   = blk_total[15:8];
    wire [12:0] cur_bm_addr = {1'b0, r_y[11:4]}*7'd80 + {8'b0, r_x[11:4]};  // 0..3599
    reg  [2:0]  r_slot;                          // 当前帧槽 0..4
    wire [14:0] bg_addr = {r_slot, cur_bm_addr[11:0]};   // 5 槽 x 4096
    reg  [7:0]  bg_rd;                           // 5 帧前的块均值(同步读)
    reg  [7:0]  bg_blk;                          // 本块背景(块内锁存，抗 BRAM 读延迟)
    (* ram_style="block" *) reg [7:0] bg_mem [0:BG_FRAMES*4096-1];
    wire        blk_end  = rowblk_end & blkrow_end;
    wire        blk_dark = ({3'b0, blk_bm} < DARK_THR) &&
                           (({1'b0, blk_bm} + {1'b0, CB_DELTA}) < {1'b0, bg_blk});

    always @(posedge clk) bg_rd <= bg_mem[bg_addr];
    always @(posedge clk) if (de && (r_x[3:0]==4'd4)) bg_blk <= bg_rd;

    (* ram_style="distributed" *) reg blk_mask [0:BW*BH-1];
    reg        bm_we; reg [12:0] bm_wa; reg bm_wd;
    reg        bg_we; reg [14:0] bg_wa; reg [7:0] bg_wd;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bm_we <= 1'b0; bg_we <= 1'b0; r_slot <= 3'd0;
        end else begin
            bm_we <= blk_end;
            bg_we <= blk_end;
            if (blk_end) begin
                bm_wa <= cur_bm_addr;
                bm_wd <= blk_dark;
                bg_wa <= bg_addr;
                bg_wd <= blk_bm;
            end
            if (vs_rise) r_slot <= (r_slot==BG_FRAMES-1) ? 3'd0 : r_slot + 3'd1;
        end
    end
    always @(posedge clk) if (bm_we) blk_mask[bm_wa] <= bm_wd;
    always @(posedge clk) if (bg_we) bg_mem[bg_wa] <= bg_wd;

    // ---------------- 扫描 FSM 声明（放在使用之前，TD 按先声明后使用解析）----------------
    localparam T_IDLE =4'd0,  T_CLR  =4'd1,  T_READ =4'd2,  T_WR   =4'd3,
               T_UPD  =4'd4,  T_GRP  =4'd5,  T_GSCAN=4'd6,  T_GUPD =4'd7,
               T_GNEXT=4'd8,  T_GMERGE=4'd9, T_GOUT =4'd10, T_SPLIT=4'd11;
    reg [3:0]  t_st;
    reg [LABW-1:0] t_bx, t_by, t_lv, t_next, t_lbl;
    reg        t_sel;
    reg        t_dark, t_new;
    reg [FW-1:0] t_frd;
    reg [3:0]  t_di;
    reg [5:0]  t_col;

    reg [3:0]  t_gscan;                     // 0..MAX_GROUPS-1
    reg [3:0]  t_best;
    reg        t_best_valid;
    reg [15:0] t_best_delta;
    reg [3:0]  t_gsel;                      // 0..MAX_GROUPS
    reg [3:0]  t_mi, t_mj;
    reg        t_mchanged;
    reg [2:0]  t_nsplit, t_si;
    reg        t_split_h;
    reg [11:0] t_start, t_cross, t_seg;

    // 特征更新（块坐标 -> 直接存像素 = 块<<4）
    wire [11:0] bx_px = {5'b0, t_bx, 4'b0};
    wire [11:0] by_px = {5'b0, t_by, 4'b0};
    wire [11:0] nf_minx = (t_frd[64] && t_frd[63:52]<bx_px) ? t_frd[63:52] : bx_px;
    wire [11:0] nf_maxx = (t_frd[64] && t_frd[51:40]>bx_px) ? t_frd[51:40] : bx_px;
    wire [11:0] nf_miny = (t_frd[64] && t_frd[39:28]<by_px) ? t_frd[39:28] : by_px;
    wire [11:0] nf_maxy = (t_frd[64] && t_frd[27:16]>by_px) ? t_frd[27:16] : by_px;
    wire [15:0] nf_area = t_frd[64] ? (t_frd[15:0] + 16'd1) : 16'd1;

    // ---------------- 特征表 + 行缓冲(ping-pong) ----------------
    // feat 字段: [FW-1]=valid [42:31]=minx [30:19]=maxx [18:7]=miny [6:0] 不够 -> 用 12b*4
    // 布局: valid(1) | minx(12) | maxx(12) | miny(12) | maxy(12) | area(16)
    // 单写口/单读口，否则 TD 不推断 RAM（会变成寄存器+大 mux -> 面积爆炸）
    (* ram_style="distributed" *) reg [FW-1:0] feat [0:(1<<LABW)-1];
    wire [LABW-1:0]  ft_ra = ((t_st==T_GRP)||(t_st==T_GSCAN)||(t_st==T_GUPD))
                             ? t_lv : t_lbl;   // 分组阶段读标签 t_lv，CCL 阶段读 t_lbl
    wire [FW-1:0]    ft_rd = feat[ft_ra];                     // 组合读
    wire             ft_we = (t_st==T_CLR) | ((t_st==T_UPD) & t_dark);
    wire [LABW-1:0]  ft_wa = (t_st==T_CLR) ? t_lv : t_lbl;
    wire [FW-1:0]    ft_wd = (t_st==T_CLR) ? {FW{1'b0}}
                           : {1'b1, nf_minx, nf_maxx, nf_miny, nf_maxy, nf_area};
    always @(posedge clk) if (ft_we) feat[ft_wa] <= ft_wd;
    reg [LABW-1:0] rbuf [0:255];            // index = {sel, bx}

    // FW=65: valid[64] minx[63:52] maxx[51:40] miny[39:28] maxy[27:16] area[15:0]

    // ---------------- 分组表（一颗钢珠一条记录，与碎片数量无关）----------------
    reg [11:0] g_minx [0:MAX_GROUPS-1];
    reg [11:0] g_maxx [0:MAX_GROUPS-1];
    reg [11:0] g_miny [0:MAX_GROUPS-1];
    reg [11:0] g_maxy [0:MAX_GROUPS-1];
    reg [15:0] g_area [0:MAX_GROUPS-1];
    reg [MAX_GROUPS-1:0] g_valid;
    reg [4:0]  g_count;

    wire [12:0]     s_bidx  = {1'b0, t_by}*7'd80 + {8'b0, t_bx};
    // blk_mask 只有一个读口：CCL 扫描期间读 s_bidx；active 期间预读下一块（上一帧值）
    wire            ccl_scan = (t_st==T_READ)||(t_st==T_WR)||(t_st==T_UPD);
    wire [12:0]     bm_nxt   = (cur_bm_addr < (BW*BH-1)) ? (cur_bm_addr + 13'd1) : 13'd0;
    wire [12:0]     bm_ra    = vs_rise ? 13'd0 : (ccl_scan ? s_bidx : bm_nxt);
    wire            bm_rd    = blk_mask[bm_ra];
    wire            s_dark   = bm_rd;

    // ---- 掩膜视图：块末预读下一块，锁存覆盖整块 16 像素；vs 预读块 0 ----
    // 当前块的 blk_mask 写发生在该块第一个像素的时钟沿；在上一块最后一个像素
    // 读取下一块地址，得到的仍是上一帧的位。显示与 track 表（也是上一帧）同步。
    reg       r_mask_disp;
    reg [1:0] r_mask_vs;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_mask_disp <= 1'b0;
            r_mask_vs   <= 2'd0;
        end else begin
            if (vs_rise) begin
                r_mask_disp <= bm_rd;
                r_mask_vs   <= (r_mask_vs==2'd2) ? 2'd2 : (r_mask_vs + 2'd1);
            end else if (de && (r_x[3:0]==4'hF)) begin
                r_mask_disp <= bm_rd;
            end
        end
    end
    assign o_mask_bit = (r_mask_vs==2'd2) ? r_mask_disp : 1'b0;

    wire [LABW-1:0] s_left  = (t_bx==0) ? {LABW{1'b0}} : rbuf[{t_sel, t_bx-1'b1}];
    wire [LABW-1:0] s_up    = (t_by==0) ? {LABW{1'b0}} : rbuf[{~t_sel, t_bx}];
    wire [LABW-1:0] s_lbl   = (s_left!=0) ? s_left : ((s_up!=0) ? s_up : t_next);
    wire            s_isnew = s_dark && (s_left==0) && (s_up==0);

    wire [FW-1:0] s_ff = ft_rd;             // 分组阶段组合读特征(ft_ra=t_lv)

    // ---- 碎片粗筛：只保留可能属于钢珠的连通块，不在这里用填充率/长宽比 ----
    wire [6:0] fn_mnx = s_ff[63:52]>>4, fn_mxx = s_ff[51:40]>>4;
    wire [6:0] fn_mny = s_ff[39:28]>>4, fn_mxy = s_ff[27:16]>>4;
    wire [7:0] fn_wb = fn_mxx - fn_mnx + 8'd1;
    wire [7:0] fn_hb = fn_mxy - fn_mny + 8'd1;
    wire [15:0] fn_ab = s_ff[15:0];
    wire [15:0] fn_box = fn_wb * fn_hb;
    wire [23:0] fn_fill = fn_ab * 8'd100;
    wire fn_lft = (fn_mnx==7'd0), fn_rgt = (fn_mxx==7'd79);
    wire fn_top = (fn_mny==7'd0), fn_bot = (fn_mxy==7'd44);
    wire fn_corner = (fn_lft&fn_top)|(fn_rgt&fn_top)|(fn_lft&fn_bot)|(fn_rgt&fn_bot);
    wire frag_edge_ok = (i_wide && (fn_wb>=8'd2) && (fn_hb>=8'd2) && (fn_ab>=16'd8));
    wire frag_left_ok = (!fn_lft) || frag_edge_ok;
    wire frag_corner_ok = (!fn_corner) || (frag_edge_ok && (fn_mnx<=7'd2));
    wire frag_size_ok = s_ff[64] && (fn_ab>=FRAG_MIN_BLKN) && (fn_ab<=MAX_BLKN)
                     && (fn_wb<=MAX_RAWWH) && (fn_hb<=MAX_RAWWH);
    wire frag_ok = frag_size_ok && frag_corner_ok && (fn_mny!=7'd0) && frag_left_ok;

    // ---- 碎片 -> 分组：并集包围盒 <= 13x13 块；任意数量碎片都走同一条件 ----
    wire [11:0] gs_minx = g_minx[t_gscan], gs_maxx = g_maxx[t_gscan];
    wire [11:0] gs_miny = g_miny[t_gscan], gs_maxy = g_maxy[t_gscan];
    wire [11:0] gu_minx = (gs_minx < s_ff[63:52]) ? gs_minx : s_ff[63:52];
    wire [11:0] gu_maxx = (gs_maxx > s_ff[51:40]) ? gs_maxx : s_ff[51:40];
    wire [11:0] gu_miny = (gs_miny < s_ff[39:28]) ? gs_miny : s_ff[39:28];
    wire [11:0] gu_maxy = (gs_maxy > s_ff[27:16]) ? gs_maxy : s_ff[27:16];
    wire [7:0]  gs_wb = ((gs_maxx - gs_minx)>>4) + 8'd1;
    wire [7:0]  gs_hb = ((gs_maxy - gs_miny)>>4) + 8'd1;
    wire [7:0]  gu_wb = ((gu_maxx - gu_minx)>>4) + 8'd1;
    wire [7:0]  gu_hb = ((gu_maxy - gu_miny)>>4) + 8'd1;
    wire [15:0] gs_box = gs_wb * gs_hb;
    wire [15:0] gu_box = gu_wb * gu_hb;
    wire [15:0] gu_delta = (gu_box >= gs_box) ? (gu_box - gs_box) : 16'd0;
    wire        g_fits = g_valid[t_gscan] && (gu_wb<=GROUP_MAXWH) && (gu_hb<=GROUP_MAXWH);

    // ---- 分组之间合并：处理碎片先后顺序造成的一颗钢珠分成多条分组 ----
    wire [11:0] mg_minx = (g_minx[t_mi[3:0]] < g_minx[t_mj[3:0]]) ? g_minx[t_mi[3:0]] : g_minx[t_mj[3:0]];
    wire [11:0] mg_maxx = (g_maxx[t_mi[3:0]] > g_maxx[t_mj[3:0]]) ? g_maxx[t_mi[3:0]] : g_maxx[t_mj[3:0]];
    wire [11:0] mg_miny = (g_miny[t_mi[3:0]] < g_miny[t_mj[3:0]]) ? g_miny[t_mi[3:0]] : g_miny[t_mj[3:0]];
    wire [11:0] mg_maxy = (g_maxy[t_mi[3:0]] > g_maxy[t_mj[3:0]]) ? g_maxy[t_mi[3:0]] : g_maxy[t_mj[3:0]];
    wire [7:0]  mg_wb = ((mg_maxx - mg_minx)>>4) + 8'd1;
    wire [7:0]  mg_hb = ((mg_maxy - mg_miny)>>4) + 8'd1;
    wire        m_fits = (t_mi < MAX_GROUPS) && (t_mj < MAX_GROUPS)
                      && g_valid[t_mi[3:0]] && g_valid[t_mj[3:0]]
                      && (mg_wb<=GROUP_MAXWH) && (mg_hb<=GROUP_MAXWH);

    // ---- 分组输出：支撑面积/短边达标，固定 13x13 块框 ----
    wire [11:0] o_minx = g_minx[t_gsel[3:0]], o_maxx = g_maxx[t_gsel[3:0]];
    wire [11:0] o_miny = g_miny[t_gsel[3:0]], o_maxy = g_maxy[t_gsel[3:0]];
    wire [15:0] o_area = g_area[t_gsel[3:0]];
    wire [7:0]  o_wb = ((o_maxx - o_minx)>>4) + 8'd1;
    wire [7:0]  o_hb = ((o_maxy - o_miny)>>4) + 8'd1;
    wire [7:0]  o_l = (o_wb>=o_hb) ? o_wb : o_hb;
    wire [7:0]  o_s = (o_wb< o_hb) ? o_wb : o_hb;
    wire [12:0] o_cx_s = {1'b0,o_minx} + {1'b0,o_maxx} + 13'd16;
    wire [12:0] o_cy_s = {1'b0,o_miny} + {1'b0,o_maxy} + 13'd16;
    wire [11:0] o_cx = o_cx_s[12:1];
    wire [11:0] o_cy = o_cy_s[12:1];
    wire [11:0] o_cy_out = o_cy;   // 跟踪/计数使用真实中心，显示偏移在 cv_top
    wire        o_edge = i_wide && (o_minx<=12'd32);   // 只放宽左侧入场
    wire [7:0]  o_min_side = o_edge ? 8'd3 : GROUP_MIN_SIDE;
    wire [7:0]  o_min_long = o_edge ? 8'd3 : GROUP_MIN_LONG;
    wire [15:0] o_min_area = o_edge ? 16'd10 : MIN_BLKN;
    wire        o_single = (o_l<=GROUP_MAXWH);
    wire        o_aspect_ok = (!o_single) ||
                              (o_edge ? (({4'b0,o_l} * 8'd5) <= ({4'b0,o_s} * 8'd11))
                                      : (({4'b0,o_l} * 8'd5) <= ({4'b0,o_s} * 8'd9)));
    wire        o_roi_ok = (o_cy_out>=ROI_Y0) ||
                           ((o_cx<=12'd240) && (o_cy_out>=12'd150));
    wire        o_basic = g_valid[t_gsel[3:0]] && (o_area>=o_min_area)
                       && (o_s>=o_min_side) && (o_l>=o_min_long)
                       && o_aspect_ok && o_roi_ok;
    wire        o_one = o_basic && (o_l<=GROUP_MAXWH);

    function [2:0] f_nsplit;
        input [7:0] l;
        begin
            if (l >= 8'd32)      f_nsplit = 3'd4;
            else if (l >= 8'd23) f_nsplit = 3'd3;
            else if (l >= 8'd14) f_nsplit = 3'd2;
            else                 f_nsplit = 3'd1;
        end
    endfunction

    wire [2:0]  o_n = f_nsplit(o_l);
    // 拆分长度按块单元计算：N=2/4 用移位，N=3 用 (L*171)>>9 近似 floor(L/3)
    wire [7:0]  o_l_b = (o_wb>=o_hb) ? o_wb : o_hb;
    wire [15:0] o_seg3_b_w = ({8'd0,o_l_b} * 16'd171) >> 9;
    wire [7:0]  o_seg_b = (o_n==3'd2) ? (o_l_b>>1) :
                          (o_n==3'd3) ? o_seg3_b_w[7:0] : (o_l_b>>2);
    wire [11:0] o_seg = {4'd0,o_seg_b} << 4;   // 块 -> 像素
    wire        o_split = o_basic && (o_l>GROUP_MAXWH) && (o_l>=SPLIT_SIDE)
                       && (o_s>=SPLIT_MIN_SIDE) && (o_s<=GROUP_MAXWH)
                       && ({16'd0,o_area} >= ({16'd0,o_n} * MIN_BLKN));

    // 固定框边界（端点包含，宽度 208 px；贴边裁剪）
    wire [12:0] o_x_hi = {1'b0,o_cx} + {1'b0,BOX_HALF} - 13'd1;
    wire [12:0] o_y_hi = {1'b0,o_cy_out} + {1'b0,BOX_HALF} - 13'd1;
    wire [11:0] o_bx0 = (o_cx > BOX_HALF) ? (o_cx - BOX_HALF) : 12'd0;
    wire [11:0] o_by0 = (o_cy_out > BOX_HALF) ? (o_cy_out - BOX_HALF) : 12'd0;
    wire [11:0] o_bx1 = (o_x_hi > (IMG_W-1)) ? (IMG_W-1) : o_x_hi[11:0];
    wire [11:0] o_by1 = (o_y_hi > (IMG_H-1)) ? (IMG_H-1) : o_y_hi[11:0];

    // 拆分框：沿长边等分，每段中心输出一个固定框
    wire [15:0] sp_off = t_seg * t_si;
    wire [11:0] sp_pos = t_start + sp_off[11:0] + (t_seg>>1);
    wire [11:0] sp_cx = t_split_h ? sp_pos : t_cross;
    wire [11:0] sp_cy = t_split_h ? t_cross : sp_pos;
    wire [12:0] sp_x_hi = {1'b0,sp_cx} + {1'b0,BOX_HALF} - 13'd1;
    wire [12:0] sp_y_hi = {1'b0,sp_cy} + {1'b0,BOX_HALF} - 13'd1;
    wire [11:0] sp_bx0 = (sp_cx > BOX_HALF) ? (sp_cx - BOX_HALF) : 12'd0;
    wire [11:0] sp_by0 = (sp_cy > BOX_HALF) ? (sp_cy - BOX_HALF) : 12'd0;
    wire [11:0] sp_bx1 = (sp_x_hi > (IMG_W-1)) ? (IMG_W-1) : sp_x_hi[11:0];
    wire [11:0] sp_by1 = (sp_y_hi > (IMG_H-1)) ? (IMG_H-1) : sp_y_hi[11:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            t_st<=T_IDLE; t_bx<=0; t_by<=0; t_lv<=0; t_next<=1; t_sel<=0;
            t_lbl<=0; t_dark<=0; t_new<=0; t_frd<=0; t_di<=0; t_col<=0; o_ready<=0; o_count<=0;
            t_gscan<=0; t_best<=0; t_best_valid<=0; t_best_delta<=0;
            t_gsel<=0; t_mi<=0; t_mj<=0; t_mchanged<=0;
            t_nsplit<=0; t_si<=0; t_split_h<=0; t_start<=0; t_cross<=0; t_seg<=0;
            g_valid<=0; g_count<=0;
        end else begin
            case (t_st)
                T_IDLE: begin
                    t_di<=0; t_col<=0;
                    if (vs_rise) begin
                        t_lv<=0; o_ready<=1'b0; g_valid<=0; g_count<=0;
                        t_st<=T_CLR;
                    end
                end
                T_CLR: begin
                    if (t_lv==(1<<LABW)-1) begin t_lv<=0; t_bx<=0; t_by<=0; t_next<=1; t_sel<=0; t_st<=T_READ; end
                    else t_lv<=t_lv+1'b1;
                end
                T_READ: begin
                    t_dark <= s_dark;
                    t_lbl  <= s_lbl;
                    t_new  <= s_isnew;
                    rbuf[{t_sel, t_bx}] <= s_dark ? s_lbl : {LABW{1'b0}};
                    t_st <= T_WR;
                end
                T_WR: begin
                    t_frd <= ft_rd;                 // 用已寄存标签读特征表
                    t_st <= T_UPD;
                end
                T_UPD: begin
                    if (t_new) t_next <= t_next + 1'b1;
                    if (t_bx==BW-1) begin
                        t_bx <= 0;
                        if (t_by==BH-1) begin
                            t_by<=0; t_lv<=0; t_col<=0; g_count<=0; g_valid<=0;
                            t_st<=T_GRP;
                        end else begin t_by<=t_by+1'b1; t_sel<=~t_sel; t_st<=T_READ; end
                    end else begin t_bx<=t_bx+1'b1; t_st<=T_READ; end
                end

                // ---- 逐碎片并入分组 ----
                T_GRP: begin
                    if (frag_ok) begin
                        t_gscan<=0; t_best<=0; t_best_valid<=0; t_best_delta<=16'hFFFF;
                        t_st<=T_GSCAN;
                    end else begin
                        t_st<=T_GNEXT;
                    end
                end
                T_GSCAN: begin
                    if (g_fits && ((!t_best_valid) || (gu_delta < t_best_delta))) begin
                        t_best<=t_gscan; t_best_valid<=1'b1; t_best_delta<=gu_delta;
                    end
                    if (t_gscan==MAX_GROUPS-1) t_st<=T_GUPD;
                    else t_gscan<=t_gscan+1'b1;
                end
                T_GUPD: begin
                    if (t_best_valid) begin
                        g_minx[t_best] <= (g_minx[t_best] < s_ff[63:52]) ? g_minx[t_best] : s_ff[63:52];
                        g_maxx[t_best] <= (g_maxx[t_best] > s_ff[51:40]) ? g_maxx[t_best] : s_ff[51:40];
                        g_miny[t_best] <= (g_miny[t_best] < s_ff[39:28]) ? g_miny[t_best] : s_ff[39:28];
                        g_maxy[t_best] <= (g_maxy[t_best] > s_ff[27:16]) ? g_maxy[t_best] : s_ff[27:16];
                        g_area[t_best] <= g_area[t_best] + s_ff[15:0];
                    end else if (g_count < MAX_GROUPS) begin
                        g_minx[g_count[3:0]] <= s_ff[63:52];
                        g_maxx[g_count[3:0]] <= s_ff[51:40];
                        g_miny[g_count[3:0]] <= s_ff[39:28];
                        g_maxy[g_count[3:0]] <= s_ff[27:16];
                        g_area[g_count[3:0]] <= s_ff[15:0];
                        g_valid[g_count[3:0]] <= 1'b1;
                        g_count <= g_count + 1'b1;
                    end
                    t_st <= T_GNEXT;
                end
                T_GNEXT: begin
                    if (t_lv==(1<<LABW)-1) begin
                        t_mi<=0; t_mj<=1; t_mchanged<=0; t_st<=T_GMERGE;
                    end else begin
                        t_lv<=t_lv+1'b1; t_st<=T_GRP;
                    end
                end

                // ---- 分组之间合并（最多 16 组，扫到不再变化）----
                T_GMERGE: begin
                    if (t_mi >= MAX_GROUPS) begin
                        if (t_mchanged) begin
                            t_mi<=0; t_mj<=1; t_mchanged<=0;
                        end else begin
                            t_gsel<=0; t_st<=T_GOUT;
                        end
                    end else if (t_mj >= MAX_GROUPS) begin
                        t_mi<=t_mi+1'b1; t_mj<=t_mi+2'd2;
                    end else begin
                        if (m_fits) begin
                            g_minx[t_mi[3:0]]<=mg_minx; g_maxx[t_mi[3:0]]<=mg_maxx;
                            g_miny[t_mi[3:0]]<=mg_miny; g_maxy[t_mi[3:0]]<=mg_maxy;
                            g_area[t_mi[3:0]]<=g_area[t_mi[3:0]]+g_area[t_mj[3:0]];
                            g_valid[t_mj[3:0]]<=1'b0;
                            t_mchanged<=1'b1;
                        end
                        t_mj<=t_mj+1'b1;
                    end
                end

                // ---- 输出固定框 / 接触钢珠拆分 ----
                T_GOUT: begin
                    if (t_gsel >= MAX_GROUPS) begin
                        o_count <= t_col; o_ready <= 1'b1; t_st<=T_IDLE;
                    end else if (o_one) begin
                        if (t_col < MAX_BLOBS) begin
                            box_mem[t_col] <= {o_bx0,o_bx1,o_by0,o_by1};
                            t_col <= t_col+1'b1;
                        end
                        t_gsel <= t_gsel+1'b1;
                    end else if (o_split) begin
                        t_nsplit<=o_n; t_si<=0; t_split_h<=(o_wb>=o_hb);
                        t_start <= (o_wb>=o_hb) ? o_minx : o_miny;
                        t_cross <= (o_wb>=o_hb) ? o_cy_out : o_cx;
                        t_seg   <= o_seg;
                        t_st<=T_SPLIT;
                    end else begin
                        t_gsel<=t_gsel+1'b1;
                    end
                end
                T_SPLIT: begin
                    if (t_si < t_nsplit) begin
                        if (t_col < MAX_BLOBS) begin
                            box_mem[t_col] <= {sp_bx0,sp_bx1,sp_by0,sp_by1};
                            t_col <= t_col+1'b1;
                        end
                        t_si <= t_si+1'b1;
                    end else begin
                        t_gsel<=t_gsel+1'b1; t_st<=T_GOUT;
                    end
                end
                default: t_st<=T_IDLE;
            endcase
        end
    end
endmodule
