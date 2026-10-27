`timescale 1ns / 1ps
// tb_cv_blkdet_group.v — 直接强制 80x45 块掩膜，验证任意数量碎片的分组与固定框。
//   绕过像素/背景流水，只测 cv_blkdet 的 CCL -> 分组 -> 输出。
module tb_cv_blkdet_group;
    reg clk = 0;
    reg rst_n = 0;
    reg de = 0;
    reg vs = 0;
    reg [23:0] rgb = 24'hC8C8C8;
    reg [2:0] i_sel = 0;

    wire o_ready;
    wire [5:0] o_count;
    wire [47:0] o_det_box;
    wire o_mask_bit;

    cv_blkdet #(
        .IMG_W(1280), .IMG_H(720),
        .DARK_THR(100), .CB_DELTA(20),
        .FRAG_MIN_BLKN(3), .MIN_BLKN(14), .MAX_BLKN(400),
        .MAX_RAWWH(36), .GROUP_MAXWH(13), .GROUP_MIN_SIDE(4),
        .GROUP_MIN_LONG(7), .SPLIT_SIDE(15), .SPLIT_MIN_SIDE(6),
        .BOX_HALF(80), .ROI_Y0(0), .MAX_BLOBS(8)
    ) dut (
        .clk(clk), .rst_n(rst_n), .de(de), .vs(vs), .rgb(rgb),
        .i_sel(i_sel), .i_wide(1'b0), .o_ready(o_ready), .o_count(o_count),
        .o_det_box(o_det_box), .o_mask_bit(o_mask_bit)
    );

    always #5 clk = ~clk;

    integer errors = 0;
    integer rn;
    integer rx0 [0:7], ry0 [0:7], rx1 [0:7], ry1 [0:7];
    integer bx, by, k, w, c, bw, bh, got_minx;

    task add_rect(input integer x0, input integer y0,
                  input integer x1, input integer y1);
        begin
            rx0[rn] = x0; ry0[rn] = y0; rx1[rn] = x1; ry1[rn] = y1;
            rn = rn + 1;
        end
    endtask

    task load_mask;
        reg v;
        begin
            for (by = 0; by < 45; by = by + 1) begin
                for (bx = 0; bx < 80; bx = bx + 1) begin
                    v = 1'b0;
                    for (k = 0; k < rn; k = k + 1)
                        if ((bx >= rx0[k]) && (bx < rx1[k]) &&
                            (by >= ry0[k]) && (by < ry1[k])) v = 1'b1;
                    dut.blk_mask[by * 80 + bx] = v;
                end
            end
        end
    endtask

    task pulse_vs;
        begin
            @(posedge clk); vs = 1;
            repeat (3) @(posedge clk);
            vs = 0;
            repeat (5) @(posedge clk);
        end
    endtask

    task wait_ready;
        begin
            w = 0;
            while ((w < 40000) && !o_ready) begin
                @(posedge clk);
                w = w + 1;
            end
            if (!o_ready) begin
                $display("FAIL timeout waiting o_ready");
                errors = errors + 1;
            end
        end
    endtask

    task check_case(input [8*24-1:0] name, input integer exp_n,
                    input integer m0, input integer m1, input integer m2);
        begin
            c = o_count;
            if (c !== exp_n) begin
                $display("FAIL %0s count=%0d exp=%0d", name, c, exp_n);
                errors = errors + 1;
            end
            for (k = 0; k < exp_n; k = k + 1) begin
                i_sel = k;
                #1;
                bw = o_det_box[35:24] - o_det_box[47:36] + 1;
                bh = o_det_box[11:0] - o_det_box[23:12] + 1;
                got_minx = o_det_box[47:36];
                if ((bw != 160) || (bh != 160)) begin
                    $display("FAIL %0s box%0d size=%0dx%0d", name, k, bw, bh);
                    errors = errors + 1;
                end
                if (((k == 0) && (m0 >= 0) && (got_minx != m0)) ||
                    ((k == 1) && (m1 >= 0) && (got_minx != m1)) ||
                    ((k == 2) && (m2 >= 0) && (got_minx != m2))) begin
                    $display("FAIL %0s box%0d minx=%0d", name, k, got_minx);
                    errors = errors + 1;
                end
            end
            i_sel = 0;
            if (c === exp_n)
                $display("PASS %0s count=%0d", name, c);
        end
    endtask

    initial begin
        repeat (10) @(posedge clk); #1; rst_n = 1;

        rn = 0; add_rect(35, 18, 44, 27);
        load_mask; pulse_vs; wait_ready;
        check_case("complete9x9", 1, 552, -1, -1);

        rn = 0; add_rect(35, 18, 44, 21); add_rect(35, 24, 44, 27);
        load_mask; pulse_vs; wait_ready;
        check_case("split2_vert", 1, 552, -1, -1);

        rn = 0; add_rect(35, 18, 38, 21); add_rect(41, 18, 44, 21);
                add_rect(35, 24, 38, 27); add_rect(41, 24, 44, 27);
        load_mask; pulse_vs; wait_ready;
        check_case("frag4_cross", 1, 552, -1, -1);

        rn = 0; add_rect(35, 18, 38, 21); add_rect(41, 18, 44, 21);
                add_rect(35, 24, 38, 27); add_rect(41, 24, 44, 27);
                add_rect(38, 22, 41, 24);
        load_mask; pulse_vs; wait_ready;
        check_case("frag5_diag", 1, 552, -1, -1);

        rn = 0; add_rect(20, 18, 38, 27);
        load_mask; pulse_vs; wait_ready;
        check_case("touch2", 2, 312, 456, -1);

        rn = 0; add_rect(20, 18, 47, 27);
        load_mask; pulse_vs; wait_ready;
        check_case("touch3", 3, 312, 456, 600);

        rn = 0; add_rect(10, 10, 13, 13);
        load_mask; pulse_vs; wait_ready;
        check_case("noise3x3", 0, -1, -1, -1);

        rn = 0; add_rect(10, 10, 15, 15);
        load_mask; pulse_vs; wait_ready;
        check_case("texture5x5", 0, -1, -1, -1);

        rn = 0; add_rect(10, 10, 19, 13);
        load_mask; pulse_vs; wait_ready;
        check_case("sliver9x3", 0, -1, -1, -1);

        rn = 0; add_rect(10, 10, 40, 15);
        load_mask; pulse_vs; wait_ready;
        check_case("line30x5", 0, -1, -1, -1);

        rn = 0; add_rect(10, 10, 22, 19);
        load_mask; pulse_vs; wait_ready;
        check_case("wide12x9", 1, 176, -1, -1);

        rn = 0; add_rect(10, 10, 24, 19);
        load_mask; pulse_vs; wait_ready;
        check_case("wide14x9", 0, -1, -1, -1);

        if (errors != 0) begin
            $display("RESULT FAIL errors=%0d", errors);
            $fatal(1);
        end
        $display("RESULT PASS");
        $finish;
    end
endmodule
