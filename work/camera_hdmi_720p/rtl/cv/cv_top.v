`timescale 1ns / 1ps
//=============================================================================
// cv_top.v — 钢珠检测像素级前端 + OSD 叠加（MCU 负责 CCL/跟踪/计数）
// ============================================================
// 数据流（pixel 75MHz）：
//   G = I_data[15:8]
//   -> 4x4 盒式平均（精确 (sum+8)>>4）
//   -> 320x180
//   -> |G - BG| >= I_ball_bg_thr -> 1bit mask
//   -> run 提取 -> run_mem 双口 BRAM
//      A 口 pixel 写；B 口 I_ahb_clk 读（MCU 经 RUN_IDX/RUN_DAT 间接读）
//   -> 叠加 MCU 写的 overlay（绿框 + ID）和 count（4 位 hex）
//
// 背景：I_ball_capture 上升沿后的下一帧写入 bg_mem（320x180x8bit）。
// 所有阈值/几何/跟踪参数都在 mcu_fw/main.c 的 VISION_PARAMS，本模块不含业务阈值。
// 旧参数 BIN_THR/EDGE_THR/MASK_SRC/MASK_VIEW/BALL_SCALE 仅为兼容例化保留，未使用。
// run_mem 项（32bit）：{row_y[9:0], xs[10:0], xe[10:0]}
// overlay 项（64bit）：{valid, id[3:0], x0[11:0], y0[11:0], x1[11:0], y1[11:0], pad}
//=============================================================================
module cv_top #(
    parameter IMG_W            = 1280,
    parameter IMG_H            = 720,
    parameter [7:0]  BIN_THR   = 8'd91,
    parameter [10:0] EDGE_THR  = 11'd80,
    parameter         MASK_SRC = 1,        // legacy Sobel/bright (unused in ball mode)
    parameter         MAX_RUNS = 1024,
    parameter         MASK_VIEW= 0,
    parameter [11:0] FBOX_W   = 12'd2,
    parameter         MAX_OV   = 8,
    parameter         BALL_W   = 320,
    parameter         BALL_H   = 180,
    parameter         BALL_SCALE = 4
)(
    input  wire        I_clk,          // pixel 75MHz
    input  wire        I_rst_n,
    input  wire        I_cv_on,
    input  wire        I_thr_up,
    input  wire        I_thr_dn,
    input  wire        I_de,
    input  wire        I_vs,
    input  wire [23:0] I_data,

    // MCU-controlled ball front-end; RTL contains no business thresholds
    input  wire        I_ball_en,
    input  wire [7:0]  I_ball_bg_thr,
    input  wire [7:0]  I_ball_min_run,
    input  wire        I_ball_capture,
    output wire        O_ball_bg_ready,
    output wire        O_ball_capturing,

    // run_mem B 口（ahb_clk 域读，给 MCU）
    input  wire        I_ahb_clk,
    input  wire [9:0]  I_run_rd_addr,
    output reg  [31:0] O_run_rd_data,

    // overlay + count（来自 ahb_status_slave）
    input  wire [511:0] I_overlay,
    input  wire [15:0]  I_count,

    // meta（给 ahb_status_slave）
    output wire [10:0] O_run_cnt,
    output wire [7:0]  O_min_y,
    output wire [7:0]  O_max_y,

    // 视频输出
    output wire        O_de,
    output wire        O_vs,
    output wire [23:0] O_data,

    // 调试
    output wire        O_run_overflow,
    output wire [7:0]  O_bin_thr
);

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

    // ============================================================ ball front-end
    // MCU C owns every tunable threshold; RTL only applies registers.
    // G = I_data[15:8]; exact 4x4 box average -> BALL_W x BALL_H.
    wire [7:0] w_g   = I_data[15:8];
    wire [8:0] w_sx  = r_x[11:2];      // 0..319
    wire [7:0] w_sy  = r_y[10:2];      // 0..179
    wire       w_hsum_end  = I_de && (r_x[1:0] == 2'd3);
    wire       w_small_end = w_hsum_end && (r_y[1:0] == 2'd3);
    reg  [11:0] r_hsum;
    wire [11:0] w_hsum = r_hsum + {4'b0, w_g};

    // 3 previous full rows' 4-pixel horizontal sums -> exact 4x4 average
    (*ram_style = "dram"*) reg [11:0] hs0 [0:BALL_W-1];
    (*ram_style = "dram"*) reg [11:0] hs1 [0:BALL_W-1];
    (*ram_style = "dram"*) reg [11:0] hs2 [0:BALL_W-1];
    wire [13:0] w_vsum = {2'b0, hs0[w_sx]} + {2'b0, hs1[w_sx]} +
                         {2'b0, hs2[w_sx]} + {2'b0, w_hsum};
    wire [7:0]  w_small = (w_vsum + 14'd8) >> 4;

    // slow MCU registers -> pixel domain (2FF)
    reg [2:0] r_ball_en_s, r_cap_s;
    reg [7:0] r_bg_thr_a, r_bg_thr;
    reg [7:0] r_min_run_a, r_min_run;
    reg       r_cap_d;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r_ball_en_s <= 3'd0; r_cap_s <= 3'd0;
            r_bg_thr_a  <= 8'd0; r_bg_thr <= 8'd0; r_cap_d <= 1'b0;
            r_min_run_a <= 8'd0; r_min_run <= 8'd0;
        end else begin
            r_ball_en_s <= {r_ball_en_s[1:0], I_ball_en};
            r_cap_s     <= {r_cap_s[1:0], I_ball_capture};
            r_bg_thr_a  <= I_ball_bg_thr;
            r_bg_thr    <= r_bg_thr_a;
            r_min_run_a <= I_ball_min_run;
            r_min_run   <= r_min_run_a;
            r_cap_d     <= r_cap_s[2];
        end
    end
    wire w_ball_en  = r_ball_en_s[2];
    wire w_cap_rise = r_cap_s[2] & ~r_cap_d;

    // background frame (320x180 x 8bit = 57.6 KB)
    localparam integer BALL_PIX = BALL_W * BALL_H;
    (*ram_style = "bram"*) reg [7:0] bg_mem [0:BALL_PIX-1];
    reg [7:0] bg_q;
    reg [16:0] r_bg_addr;
    wire [16:0] w_bg_addr = w_sy * BALL_W + w_sx;

    // one-shot capture: MCU sets I_ball_capture, next vsync captures one frame
    reg r_cap_pending, r_cap_active, r_bg_ready;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r_cap_pending <= 1'b0; r_cap_active <= 1'b0; r_bg_ready <= 1'b0;
        end else begin
            if (w_cap_rise) r_cap_pending <= 1'b1;
            if (vs_rise) begin
                if (r_cap_pending) begin
                    r_cap_pending <= 1'b0; r_cap_active <= 1'b1; r_bg_ready <= 1'b0;
                end else if (r_cap_active) begin
                    r_cap_active <= 1'b0; r_bg_ready <= 1'b1;
                end
            end
        end
    end

    always @(posedge I_clk) begin
        if (w_small_end && r_cap_active)
            bg_mem[w_bg_addr] <= w_small;
        r_bg_addr <= w_bg_addr;
    end
    always @(posedge I_clk) begin
        bg_q <= bg_mem[r_bg_addr];
    end

    // run_mem：A 口 pixel 写，B 口 ahb_clk 读（给 MCU）
    (*ram_style = "bram"*) reg [31:0] run_mem [0:MAX_RUNS-1];

    // pipeline the 4x4 result one cycle so bg_q is valid
    reg [7:0] r_small_d, r_sy_d;
    reg [8:0] r_sx_d;
    reg       r_small_valid, r_small_valid_d;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r_small_d <= 8'd0; r_sx_d <= 9'd0; r_sy_d <= 8'd0;
            r_small_valid <= 1'b0; r_small_valid_d <= 1'b0;
        end else begin
            r_small_valid <= w_small_end;
            r_small_valid_d <= r_small_valid;
            if (w_small_end) begin
                r_small_d <= w_small; r_sx_d <= w_sx; r_sy_d <= w_sy;
            end
        end
    end

    // 4-pixel horizontal sum; each of the first 3 rows writes hs0/1/2.
    // At y%4==3 the current row (not stored) completes the 4x4 block.
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) r_hsum <= 12'd0;
        else if (vs_rise) r_hsum <= 12'd0;
        else if (I_de) r_hsum <= w_hsum_end ? 12'd0 : w_hsum;
    end

    always @(posedge I_clk) begin
        if (w_hsum_end) begin
            case (r_y[1:0])
                2'd0: hs0[w_sx] <= w_hsum;
                2'd1: hs1[w_sx] <= w_hsum;
                2'd2: hs2[w_sx] <= w_hsum;
                default: ;
            endcase
        end
    end

    // run extraction at 320x180 (same run_mem format as before)
    reg        r_run_act;
    reg [8:0]  r_run_xs, r_run_xe;
    reg [10:0] r_run_wr, r_run_cnt;
    reg        r_run_ovf, r_run_ovf_frame;
    wire [7:0] w_diff = (r_small_d >= bg_q) ? (r_small_d - bg_q)
                                            : (bg_q - r_small_d);
    wire w_ball_mask = r_small_valid_d && r_bg_ready && !r_cap_active &&
                       w_ball_en && I_cv_on && (w_diff >= r_bg_thr);
    // MCU-tunable minimum run length: drop isolated 1..N-1 pixel noise
    wire [8:0] w_run_xs_now = r_run_act ? r_run_xs : r_sx_d;
    wire [8:0] w_run_len     = r_run_xe - r_run_xs + 9'd1;
    wire [8:0] w_run_len_end = r_sx_d - w_run_xs_now + 9'd1;
    wire w_run_keep     = (r_min_run == 8'd0) || (w_run_len     >= {1'b0, r_min_run});
    wire w_run_keep_end = (r_min_run == 8'd0) || (w_run_len_end >= {1'b0, r_min_run});

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r_run_act <= 1'b0; r_run_xs <= 9'd0; r_run_xe <= 9'd0;
            r_run_wr <= 11'd0; r_run_cnt <= 11'd0;
            r_run_ovf <= 1'b0; r_run_ovf_frame <= 1'b0;
        end else if (vs_rise) begin
            if (r_run_act) begin
                if (w_run_keep) begin
                    if (r_run_wr < MAX_RUNS) begin
                        run_mem[r_run_wr[9:0]] <= {2'b0, r_sy_d, 2'b0, r_run_xs,
                                                   2'b0, r_run_xe};
                        r_run_wr <= r_run_wr + 1'b1;
                    end else r_run_ovf <= 1'b1;
                    r_run_cnt <= r_run_wr + 1'b1;
                end else begin
                    r_run_cnt <= r_run_wr;
                end
            end else begin
                r_run_cnt <= r_run_wr;
            end
            r_run_wr  <= 11'd0;
            r_run_act <= 1'b0;
            r_run_ovf_frame <= r_run_ovf | (r_run_act && w_run_keep && (r_run_wr >= MAX_RUNS));
            r_run_ovf <= 1'b0;
        end else if (r_small_valid_d) begin
            if (w_ball_mask) begin
                if (!r_run_act) begin
                    r_run_act <= 1'b1;
                    r_run_xs  <= r_sx_d;
                end
                r_run_xe <= r_sx_d;
                if (r_sx_d == BALL_W-1) begin
                    if (w_run_keep_end) begin
                        if (r_run_wr < MAX_RUNS) begin
                            run_mem[r_run_wr[9:0]] <= {2'b0, r_sy_d, 2'b0, w_run_xs_now,
                                                       2'b0, r_sx_d};
                            r_run_wr <= r_run_wr + 1'b1;
                        end else r_run_ovf <= 1'b1;
                    end
                    r_run_act <= 1'b0;
                end
            end else if (r_run_act) begin
                if (w_run_keep) begin
                    if (r_run_wr < MAX_RUNS) begin
                        run_mem[r_run_wr[9:0]] <= {2'b0, r_sy_d, 2'b0, r_run_xs,
                                                   2'b0, r_run_xe};
                        r_run_wr <= r_run_wr + 1'b1;
                    end else r_run_ovf <= 1'b1;
                end
                r_run_act <= 1'b0;
            end
        end
    end

    // B 口读（ahb_clk 域，给 MCU 间接读）
    reg [9:0] r_run_rd_addr;
    always @(posedge I_ahb_clk) begin
        r_run_rd_addr <= I_run_rd_addr;
        O_run_rd_data <= run_mem[r_run_rd_addr];
    end

    assign O_run_cnt      = r_run_cnt;
    assign O_min_y        = 8'h00;
    assign O_max_y        = 8'h00;
    assign O_run_overflow = r_run_ovf_frame;
    assign O_bin_thr      = r_bg_thr;
    assign O_ball_bg_ready  = r_bg_ready;
    assign O_ball_capturing = r_cap_active;

    //=============================================================================
    // OSD 叠加：绿框 + ID 字模（来自 I_overlay）；Count（来自 I_count，4 位 hex）
    //=============================================================================

    // 0-F 字模（5x7），复用原 f_digit
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

    // overlay 项解析（8 项，每项 64bit）
    // 字段：[63]valid [62:59]id [58:47]x0 [46:35]y0 [31:20]x1 [19:8]y1
    wire [63:0] ov0 = I_overlay[63:0];
    wire [63:0] ov1 = I_overlay[127:64];
    wire [63:0] ov2 = I_overlay[191:128];
    wire [63:0] ov3 = I_overlay[255:192];
    wire [63:0] ov4 = I_overlay[319:256];
    wire [63:0] ov5 = I_overlay[383:320];
    wire [63:0] ov6 = I_overlay[447:384];
    wire [63:0] ov7 = I_overlay[511:448];

    // Count 显示：左上 (24,56)，4 位 hex，每位 8px（5 字模 + 3 间隙），共 32px
    localparam [11:0] CNT_X = 12'd24;
    localparam [11:0] CNT_Y = 12'd56;
    localparam [11:0] CNT_W = 12'd32;

    integer oi;
    reg r_border, r_id_digit, r_cnt_digit;
    reg [4:0] dg_bits;
    reg [11:0] dg_row, dg_col;
    reg [3:0]  cnt_nib;
    reg [1:0]  cnt_idx;
    always @(*) begin
        r_border=1'b0; r_id_digit=1'b0; r_cnt_digit=1'b0;
        // ---- overlay 绿框 + ID ----
        // 8 项展开（避免循环内数组变址导致的组合复杂度）
        if (ov0[63]) begin
            if ((((r_x>=ov0[58:47])&&(r_x<ov0[58:47]+FBOX_W)) || ((r_x<=ov0[31:20])&&(r_x>ov0[31:20]-FBOX_W))) &&
                (r_y>=ov0[46:35])&&(r_y<=ov0[19:8])) r_border=1;
            if ((((r_y>=ov0[46:35])&&(r_y<ov0[46:35]+FBOX_W)) || ((r_y<=ov0[19:8])&&(r_y>ov0[19:8]-FBOX_W))) &&
                (r_x>=ov0[58:47])&&(r_x<=ov0[31:20])) r_border=1;
            if (r_x>=ov0[58:47] && r_x<ov0[58:47]+5 && r_y>=ov0[46:35] && r_y<ov0[46:35]+7) begin
                dg_row=r_y-ov0[46:35]; dg_col=r_x-ov0[58:47];
                dg_bits=f_digit(ov0[62:59], dg_row[2:0]);
                if (dg_bits[4-dg_col[2:0]]) r_id_digit=1;
            end
        end
        if (ov1[63]) begin
            if ((((r_x>=ov1[58:47])&&(r_x<ov1[58:47]+FBOX_W)) || ((r_x<=ov1[31:20])&&(r_x>ov1[31:20]-FBOX_W))) &&
                (r_y>=ov1[46:35])&&(r_y<=ov1[19:8])) r_border=1;
            if ((((r_y>=ov1[46:35])&&(r_y<ov1[46:35]+FBOX_W)) || ((r_y<=ov1[19:8])&&(r_y>ov1[19:8]-FBOX_W))) &&
                (r_x>=ov1[58:47])&&(r_x<=ov1[31:20])) r_border=1;
            if (r_x>=ov1[58:47] && r_x<ov1[58:47]+5 && r_y>=ov1[46:35] && r_y<ov1[46:35]+7) begin
                dg_row=r_y-ov1[46:35]; dg_col=r_x-ov1[58:47];
                dg_bits=f_digit(ov1[62:59], dg_row[2:0]);
                if (dg_bits[4-dg_col[2:0]]) r_id_digit=1;
            end
        end
        if (ov2[63]) begin
            if ((((r_x>=ov2[58:47])&&(r_x<ov2[58:47]+FBOX_W)) || ((r_x<=ov2[31:20])&&(r_x>ov2[31:20]-FBOX_W))) &&
                (r_y>=ov2[46:35])&&(r_y<=ov2[19:8])) r_border=1;
            if ((((r_y>=ov2[46:35])&&(r_y<ov2[46:35]+FBOX_W)) || ((r_y<=ov2[19:8])&&(r_y>ov2[19:8]-FBOX_W))) &&
                (r_x>=ov2[58:47])&&(r_x<=ov2[31:20])) r_border=1;
            if (r_x>=ov2[58:47] && r_x<ov2[58:47]+5 && r_y>=ov2[46:35] && r_y<ov2[46:35]+7) begin
                dg_row=r_y-ov2[46:35]; dg_col=r_x-ov2[58:47];
                dg_bits=f_digit(ov2[62:59], dg_row[2:0]);
                if (dg_bits[4-dg_col[2:0]]) r_id_digit=1;
            end
        end
        if (ov3[63]) begin
            if ((((r_x>=ov3[58:47])&&(r_x<ov3[58:47]+FBOX_W)) || ((r_x<=ov3[31:20])&&(r_x>ov3[31:20]-FBOX_W))) &&
                (r_y>=ov3[46:35])&&(r_y<=ov3[19:8])) r_border=1;
            if ((((r_y>=ov3[46:35])&&(r_y<ov3[46:35]+FBOX_W)) || ((r_y<=ov3[19:8])&&(r_y>ov3[19:8]-FBOX_W))) &&
                (r_x>=ov3[58:47])&&(r_x<=ov3[31:20])) r_border=1;
            if (r_x>=ov3[58:47] && r_x<ov3[58:47]+5 && r_y>=ov3[46:35] && r_y<ov3[46:35]+7) begin
                dg_row=r_y-ov3[46:35]; dg_col=r_x-ov3[58:47];
                dg_bits=f_digit(ov3[62:59], dg_row[2:0]);
                if (dg_bits[4-dg_col[2:0]]) r_id_digit=1;
            end
        end
        if (ov4[63]) begin
            if ((((r_x>=ov4[58:47])&&(r_x<ov4[58:47]+FBOX_W)) || ((r_x<=ov4[31:20])&&(r_x>ov4[31:20]-FBOX_W))) &&
                (r_y>=ov4[46:35])&&(r_y<=ov4[19:8])) r_border=1;
            if ((((r_y>=ov4[46:35])&&(r_y<ov4[46:35]+FBOX_W)) || ((r_y<=ov4[19:8])&&(r_y>ov4[19:8]-FBOX_W))) &&
                (r_x>=ov4[58:47])&&(r_x<=ov4[31:20])) r_border=1;
            if (r_x>=ov4[58:47] && r_x<ov4[58:47]+5 && r_y>=ov4[46:35] && r_y<ov4[46:35]+7) begin
                dg_row=r_y-ov4[46:35]; dg_col=r_x-ov4[58:47];
                dg_bits=f_digit(ov4[62:59], dg_row[2:0]);
                if (dg_bits[4-dg_col[2:0]]) r_id_digit=1;
            end
        end
        if (ov5[63]) begin
            if ((((r_x>=ov5[58:47])&&(r_x<ov5[58:47]+FBOX_W)) || ((r_x<=ov5[31:20])&&(r_x>ov5[31:20]-FBOX_W))) &&
                (r_y>=ov5[46:35])&&(r_y<=ov5[19:8])) r_border=1;
            if ((((r_y>=ov5[46:35])&&(r_y<ov5[46:35]+FBOX_W)) || ((r_y<=ov5[19:8])&&(r_y>ov5[19:8]-FBOX_W))) &&
                (r_x>=ov5[58:47])&&(r_x<=ov5[31:20])) r_border=1;
            if (r_x>=ov5[58:47] && r_x<ov5[58:47]+5 && r_y>=ov5[46:35] && r_y<ov5[46:35]+7) begin
                dg_row=r_y-ov5[46:35]; dg_col=r_x-ov5[58:47];
                dg_bits=f_digit(ov5[62:59], dg_row[2:0]);
                if (dg_bits[4-dg_col[2:0]]) r_id_digit=1;
            end
        end
        if (ov6[63]) begin
            if ((((r_x>=ov6[58:47])&&(r_x<ov6[58:47]+FBOX_W)) || ((r_x<=ov6[31:20])&&(r_x>ov6[31:20]-FBOX_W))) &&
                (r_y>=ov6[46:35])&&(r_y<=ov6[19:8])) r_border=1;
            if ((((r_y>=ov6[46:35])&&(r_y<ov6[46:35]+FBOX_W)) || ((r_y<=ov6[19:8])&&(r_y>ov6[19:8]-FBOX_W))) &&
                (r_x>=ov6[58:47])&&(r_x<=ov6[31:20])) r_border=1;
            if (r_x>=ov6[58:47] && r_x<ov6[58:47]+5 && r_y>=ov6[46:35] && r_y<ov6[46:35]+7) begin
                dg_row=r_y-ov6[46:35]; dg_col=r_x-ov6[58:47];
                dg_bits=f_digit(ov6[62:59], dg_row[2:0]);
                if (dg_bits[4-dg_col[2:0]]) r_id_digit=1;
            end
        end
        if (ov7[63]) begin
            if ((((r_x>=ov7[58:47])&&(r_x<ov7[58:47]+FBOX_W)) || ((r_x<=ov7[31:20])&&(r_x>ov7[31:20]-FBOX_W))) &&
                (r_y>=ov7[46:35])&&(r_y<=ov7[19:8])) r_border=1;
            if ((((r_y>=ov7[46:35])&&(r_y<ov7[46:35]+FBOX_W)) || ((r_y<=ov7[19:8])&&(r_y>ov7[19:8]-FBOX_W))) &&
                (r_x>=ov7[58:47])&&(r_x<=ov7[31:20])) r_border=1;
            if (r_x>=ov7[58:47] && r_x<ov7[58:47]+5 && r_y>=ov7[46:35] && r_y<ov7[46:35]+7) begin
                dg_row=r_y-ov7[46:35]; dg_col=r_x-ov7[58:47];
                dg_bits=f_digit(ov7[62:59], dg_row[2:0]);
                if (dg_bits[4-dg_col[2:0]]) r_id_digit=1;
            end
        end
        // ---- Count（4 位 hex，每位 8px）----
        if (r_x>=CNT_X && r_x<CNT_X+CNT_W && r_y>=CNT_Y && r_y<CNT_Y+7) begin
            dg_row = r_y - CNT_Y;
            dg_col = r_x - CNT_X;          // 0..31
            cnt_idx = dg_col[4:3];         // 0..3（每 8px 一位）
            case (cnt_idx)
                2'd0: cnt_nib = I_count[15:12];
                2'd1: cnt_nib = I_count[11:8];
                2'd2: cnt_nib = I_count[7:4];
                2'd3: cnt_nib = I_count[3:0];
                default: cnt_nib = 4'h0;
            endcase
            if (dg_col[2:0] < 5) begin     // 位内 col 0-4 画字模，5-7 间隙
                dg_bits = f_digit(cnt_nib, dg_row[2:0]);
                if (dg_bits[4 - dg_col[2:0]]) r_cnt_digit=1;
            end
        end
    end

    wire [23:0] cv_base = I_data;   // ball mode: camera + green boxes (mask view is in the PC tool)
    assign O_de=I_de; assign O_vs=I_vs;
    // 优先级：Count 字模 > ID 字模 > 绿框边 > 机器视角/原画
    assign O_data = (I_cv_on && I_de) ? (r_cnt_digit ? 24'hFFFFFF :
                                         (r_id_digit ? 24'hFFFFFF :
                                          (r_border ? 24'h00FF00 : cv_base))) : I_data;

endmodule
