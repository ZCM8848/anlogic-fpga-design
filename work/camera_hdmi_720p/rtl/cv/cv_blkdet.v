`timescale 1ns / 1ps
//=============================================================================
// cv_blkdet.v — 块域(16x16)暗块检测 + 块级连通标记（深色实心目标，如钢珠）
//
//   1280x720 --(16x16 块均值 < DARK_THR)--> 80x45 暗块掩膜 --(块级光栅标记)--> 连通块
//   块域只有 3600 单元、blob 少而大；标记确定、简单、资源小，绕开 cv_top 的像素级 CCL。
//
//   标记：光栅扫描；块 (bx,by) 取【左邻居标签】优先，否则【上邻居标签】，都无则新标签。
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
    parameter [15:0] MIN_BLKN = 16'd8,      // 块数下限
    parameter [15:0] MAX_BLKN = 16'd400,    // 块数上限
    parameter [5:0]  MIN_FILL = 6'd40,      // 填充率下限 %
    parameter [5:0]  MIN_RATIO= 6'd50,      // 长短边比下限 %
    parameter [7:0]  PAIR_ASPECT = 8'd150,  // 长/短边比 >= 150% 判为"两颗贴在一起"
    parameter [15:0] PAIR_MINAREA= 16'd24,  // 且面积 >= 这么多块(滤噪声)
    parameter        MAX_BLOBS= 8
)(
    input             clk,
    input             rst_n,
    input             de,
    input             vs,
    input      [23:0] rgb,
    input      [2:0]  i_sel,                 // 选择输出第几个检测框
    output reg        o_ready,               // 检测表就绪(保持到下次 vs)
    output reg [5:0]  o_count,
    output     [47:0] o_det_box              // 第 i_sel 个框 {minx,maxx,miny,maxy} 像素坐标
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

    // ---------------- 80x45 块掩膜（局部对比阈值）----------------
    //   块均值须低于"上一帧大格(8x8 块 -> 10x6 格)均值" CB_DELTA 才判暗：
    //   静态的桌沿/木纹/边角在"上一帧"里也暗 -> 不构成对比 -> 抑制；
    //   运动中的球在其大格背景里明显偏暗 -> 检出。
    wire [7:0]  blk_bm   = blk_total[15:8];
    wire [4:0]  cell_row = r_y[11:7];
    wire [4:0]  cell_col = r_x[11:7];
    wire [6:0]  cell_idx = {2'b0,cell_row}*7'd10 + {2'b0,cell_col};   // 0..59
    reg  [7:0]  cell_prev [0:59];
    reg  [7:0]  cell_cur  [0:59];
    reg  [15:0] cell_acc  [0:59];
    wire [15:0] cell_sum  = cell_acc[cell_idx] + {8'b0, blk_bm};
    wire        cell_end  = (r_x[6:4]==3'd7) && (r_y[6:4]==3'd7);     // 每 8x8 块
    wire        blk_dark  = (blk_bm < DARK_THR) && ((blk_bm + CB_DELTA) < cell_prev[cell_idx]);

    (* ram_style="distributed" *) reg blk_mask [0:BW*BH-1];
    reg        bm_we; reg [12:0] bm_wa; reg bm_wd;
    wire [12:0] cur_bm_addr = {1'b0, r_y[11:4]}*7'd80 + {8'b0, r_x[11:4]};
    integer ci;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bm_we <= 1'b0;
            for (ci=0; ci<60; ci=ci+1) begin cell_prev[ci]<=8'd0; cell_cur[ci]<=8'd0; cell_acc[ci]<=16'd0; end
        end else begin
            bm_we <= rowblk_end & blkrow_end;
            if (rowblk_end & blkrow_end) begin
                bm_wa <= cur_bm_addr;
                bm_wd <= blk_dark;
                cell_acc[cell_idx] <= cell_end ? 16'd0 : cell_sum;
                if (cell_end) cell_cur[cell_idx] <= cell_sum[13:6];   // 64 块均值
            end
            if (vs_rise) for (ci=0; ci<60; ci=ci+1) cell_prev[ci] <= cell_cur[ci];
        end
    end
    always @(posedge clk) if (bm_we) blk_mask[bm_wa] <= bm_wd;

    // ---------------- 特征表 + 行缓冲(ping-pong) ----------------
    // feat 字段: [FW-1]=valid [42:31]=minx [30:19]=maxx [18:7]=miny [6:0] 不够 -> 用 12b*4
    // 布局: valid(1) | minx(12) | maxx(12) | miny(12) | maxy(12) | area(16)
    // 单写口/单读口，否则 TD 不推断 RAM（会变成寄存器+大 mux -> 面积爆炸）
    (* ram_style="distributed" *) reg [FW-1:0] feat [0:(1<<LABW)-1];
    wire [LABW-1:0]  ft_ra = (t_st==T_FILT) ? t_lv : t_lbl;   // 读地址
    wire [FW-1:0]    ft_rd = feat[ft_ra];                     // 组合读
    wire             ft_we = (t_st==T_CLR) | ((t_st==T_WR) & t_dark);
    wire [LABW-1:0]  ft_wa = (t_st==T_CLR) ? t_lv : t_lbl;
    wire [FW-1:0]    ft_wd = (t_st==T_CLR) ? {FW{1'b0}}
                           : {1'b1, nf_minx, nf_maxx, nf_miny, nf_maxy, nf_area};
    always @(posedge clk) if (ft_we) feat[ft_wa] <= ft_wd;
    reg [LABW-1:0] rbuf [0:255];            // index = {sel, bx}

    // FW=65: valid[64] minx[63:52] maxx[51:40] miny[39:28] maxy[27:16] area[15:0]

    // ---------------- 扫描 FSM ----------------
    localparam T_IDLE=3'd0, T_CLR=3'd1, T_READ=3'd2, T_WR=3'd3, T_FILT=3'd4;
    reg [2:0]  t_st;
    reg [LABW-1:0] t_bx, t_by, t_lv, t_next, t_lbl;
    reg        t_sel;
    reg        t_dark, t_new;
    reg [FW-1:0] t_frd;
    reg [3:0]  t_di;
    reg [5:0]  t_col;

    wire [12:0]     s_bidx  = {1'b0, t_by}*7'd80 + {8'b0, t_bx};
    wire            s_dark  = blk_mask[s_bidx];
    wire [LABW-1:0] s_left  = (t_bx==0) ? {LABW{1'b0}} : rbuf[{t_sel, t_bx-1'b1}];
    wire [LABW-1:0] s_up    = (t_by==0) ? {LABW{1'b0}} : rbuf[{~t_sel, t_bx}];
    wire [LABW-1:0] s_lbl   = (s_left!=0) ? s_left : ((s_up!=0) ? s_up : t_next);
    wire            s_isnew = s_dark && (s_left==0) && (s_up==0);
    wire [FW-1:0]   s_fval  = ft_rd;

    // 特征更新（块坐标 -> 直接存像素 = 块<<4）
    wire [11:0] bx_px = {5'b0, t_bx, 4'b0};
    wire [11:0] by_px = {5'b0, t_by, 4'b0};
    wire [11:0] nf_minx = (t_frd[64] && t_frd[63:52]<bx_px) ? t_frd[63:52] : bx_px;
    wire [11:0] nf_maxx = (t_frd[64] && t_frd[51:40]>bx_px) ? t_frd[51:40] : bx_px;
    wire [11:0] nf_miny = (t_frd[64] && t_frd[39:28]<by_px) ? t_frd[39:28] : by_px;
    wire [11:0] nf_maxy = (t_frd[64] && t_frd[27:16]>by_px) ? t_frd[27:16] : by_px;
    wire [15:0] nf_area = t_frd[64] ? (t_frd[15:0] + 16'd1) : 16'd1;

    wire [FW-1:0] s_ff = ft_rd;             // T_FILT 组合读特征(ft_ra 选通为 t_lv)
    // ---- T_FILT 形状筛选（块单位）----
    wire [6:0] fn_mnx = s_ff[63:52]>>4, fn_mxx = s_ff[51:40]>>4;
    wire [6:0] fn_mny = s_ff[39:28]>>4, fn_mxy = s_ff[27:16]>>4;
    wire [7:0] fn_wb = fn_mxx - fn_mnx + 8'd1;
    wire [7:0] fn_hb = fn_mxy - fn_mny + 8'd1;
    wire [15:0] fn_ab = s_ff[15:0];
    wire [15:0] fn_box = fn_wb * fn_hb;
    wire [23:0] fn_fill = fn_ab * 8'd100;
    wire [7:0]  fn_mn = (fn_wb<fn_hb)? fn_wb : fn_hb;
    wire [7:0]  fn_mx = (fn_wb<fn_hb)? fn_hb : fn_wb;
    // 贴角剔除：假块多出现在"角"上(x、y 同时贴边)；靠边滚过的球只贴一个边 -> 保住
    wire fn_lft = (fn_mnx==7'd0), fn_rgt = (fn_mxx==7'd79);
    wire fn_top = (fn_mny==7'd0), fn_bot = (fn_mxy==7'd44);
    wire fn_corner = (fn_lft&fn_top)|(fn_rgt&fn_top)|(fn_lft&fn_bot)|(fn_rgt&fn_bot);
    wire f_pass = s_ff[64] && (fn_ab>=MIN_BLKN) && (fn_ab<=MAX_BLKN)
               && (fn_fill >= MIN_FILL*fn_box)
               && ({fn_mn,7'b0} >= MIN_RATIO*fn_mx)
               && (fn_mnx!=0) && (fn_mny!=0)     // 不贴左/上边（剔除底面长条）
               && (fn_wb<=8'd16) && (fn_hb<=8'd16)  // 剔除过宽/过高块(球~7块; 桌沿长条几十块)
               && !fn_corner;                    // 不贴角（剔除角上的假块）
    // 贴球对：细长团块(长边/短边 >= PAIR_ASPECT%) = 两颗球贴在一起 -> 拆成两个检测
    wire [15:0] fn_asp   = fn_mx * 8'd100;
    wire [15:0] fn_asp_t = PAIR_ASPECT * fn_mn;
    wire        fn_pair  = (fn_ab >= PAIR_MINAREA) && (fn_asp >= fn_asp_t);
    wire [11:0] fn_mdx   = (s_ff[63:52] + s_ff[51:40]) >> 1;   // bbox 横向中点(px)
    wire [11:0] fn_mdy   = (s_ff[39:28] + s_ff[27:16]) >> 1;   // bbox 纵向中点(px)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            t_st<=T_IDLE; t_bx<=0; t_by<=0; t_lv<=0; t_next<=1; t_sel<=0;
            t_lbl<=0; t_dark<=0; t_new<=0; t_frd<=0; t_di<=0; t_col<=0; o_ready<=0; o_count<=0;
        end else begin
            case (t_st)
                T_IDLE: begin
                    t_di<=0; t_col<=0;
                    if (vs_rise) begin t_lv<=0; o_ready<=1'b0; t_st<=T_CLR; end
                end
                T_CLR: begin
                    if (t_lv==(1<<LABW)-1) begin t_lv<=0; t_bx<=0; t_by<=0; t_next<=1; t_sel<=0; t_st<=T_READ; end
                    else t_lv<=t_lv+1'b1;
                end
                T_READ: begin
                    t_dark <= s_dark;
                    t_lbl  <= s_lbl;
                    t_new  <= s_isnew;
                    t_frd  <= s_fval;
                    rbuf[{t_sel, t_bx}] <= s_dark ? s_lbl : {LABW{1'b0}};
                    t_st <= T_WR;
                end
                T_WR: begin
                    if (t_new) t_next <= t_next + 1'b1;
                    if (t_bx==BW-1) begin
                        t_bx <= 0;
                        if (t_by==BH-1) begin t_by<=0; t_lv<=0; t_col<=0; t_st<=T_FILT; end
                        else begin t_by<=t_by+1'b1; t_sel<=~t_sel; t_st<=T_READ; end
                    end else begin t_bx<=t_bx+1'b1; t_st<=T_READ; end
                end
                T_FILT: begin
                    if (f_pass && fn_pair && ((t_col+6'd1)<MAX_BLOBS)) begin
                        // 两颗贴在一起 -> 沿长边拆成上/下(或左/右)两个框, 计 2
                        if (fn_hb >= fn_wb) begin
                            box_mem[t_col]        <= {s_ff[63:52], s_ff[51:40], s_ff[39:28], fn_mdy};
                            box_mem[t_col+6'd1]   <= {s_ff[63:52], s_ff[51:40], fn_mdy, s_ff[27:16]};
                        end else begin
                            box_mem[t_col]        <= {s_ff[63:52], fn_mdx, s_ff[39:28], s_ff[27:16]};
                            box_mem[t_col+6'd1]   <= {fn_mdx, s_ff[51:40], s_ff[39:28], s_ff[27:16]};
                        end
                        t_col <= t_col + 6'd2;
                    end else if (f_pass && (t_col<MAX_BLOBS)) begin
                        box_mem[t_col] <= {s_ff[63:52], s_ff[51:40], s_ff[39:28], s_ff[27:16]};
                        t_col <= t_col + 6'd1;
                    end
                    if (t_lv==(1<<LABW)-1) begin
                        o_count <= t_col + ((f_pass && (t_col<MAX_BLOBS))
                                            ? ((fn_pair && ((t_col+6'd1)<MAX_BLOBS)) ? 6'd2 : 6'd1) : 6'd0);
                        o_ready <= 1'b1; t_st <= T_IDLE;
                    end else t_lv <= t_lv + 1'b1;
                end
                default: t_st<=T_IDLE;
            endcase
        end
    end
endmodule
