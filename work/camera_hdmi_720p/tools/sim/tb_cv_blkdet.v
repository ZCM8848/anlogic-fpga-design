`timescale 1ns / 1ps
// tb_cv_blkdet.v — cv_blkdet 5 帧背景差分 + CCL 面积累加的功能验证
//   帧 0..5：暗块静止在 x=400（背景同位置 -> 不应检出）
//   帧 6..11：暗块每帧右移 80px（与 5 帧前位置不同 -> 应各检出 1 个）
//   期望：f0..5 count=0；f7..11 count=1 且固定框 minx=552/632/712/792/872；
//         f6 与 5 帧前位置有重叠，允许 0~1 段。
module tb_cv_blkdet;
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
        .BOX_HALF(80), .MAX_BLOBS(8)
    ) dut (
        .clk(clk), .rst_n(rst_n), .de(de), .vs(vs), .rgb(rgb),
        .i_sel(i_sel), .i_wide(1'b0), .o_ready(o_ready), .o_count(o_count), .o_det_box(o_det_box),
        .o_mask_bit(o_mask_bit)
    );

    always #5 clk = ~clk;

    integer f, x, y;
    integer fx;
    integer fx_prev;
    integer counts [0:11];
    integer minxs [0:11];
    integer errors = 0;
    reg mask_center, mask_bg;
    reg mask_edge_prev, mask_edge_first, mask_edge_last;

    task automatic run_frame(input integer fnum, input integer xpos);
        begin
            @(posedge clk); #1;
            vs = 1; de = 0;
            repeat (3) @(posedge clk); #1;
            vs = 0;
            repeat (20) @(posedge clk);
            // 上一帧掩膜在 vs 上升沿后扫描；等待扫描完成再采样
            repeat (30000) @(posedge clk);
            #1;
            if (fnum > 0) begin
                counts[fnum-1] = o_count;
                minxs[fnum-1] = o_det_box[47:36];
            end
            // 掩膜视图：应显示上一帧的块掩膜；取上一帧方块中心与一个背景块
            fx_prev = (fnum <= 6) ? 400 : (480 + (fnum - 7) * 80);
            mask_center = 1'bx;
            mask_bg     = 1'bx;
            mask_edge_prev = 1'bx;
            mask_edge_first = 1'bx;
            mask_edge_last = 1'bx;
            // active 帧：亮背景 + 144x144 暗块
            for (y = 0; y < 720; y = y + 1) begin
                for (x = 0; x < 1280; x = x + 1) begin
                    de = 1;
                    rgb = (x >= xpos && x < xpos + 144 && y >= 300 && y < 444)
                          ? 24'h282828 : 24'hC8C8C8;
                    if ((fnum >= 7) && (x == (fx_prev + 72)) && (y == 372)) begin
                        #4; mask_center = o_mask_bit;
                    end else if ((fnum >= 7) && (x == 100) && (y == 100)) begin
                        #4; mask_bg = o_mask_bit;
                    end else if ((fnum == 11) && (y == 372) && (x == 799)) begin
                        #4; mask_edge_prev = o_mask_bit;
                    end else if ((fnum == 11) && (y == 372) && (x == 800)) begin
                        #4; mask_edge_first = o_mask_bit;
                    end else if ((fnum == 11) && (y == 372) && (x == 815)) begin
                        #4; mask_edge_last = o_mask_bit;
                    end
                    @(posedge clk);
                    #1;
                end
            end
            de = 0;
            repeat (3000) @(posedge clk);
        end
    endtask

    task check(input integer fidx, input integer exp_count, input integer exp_minx);
        begin
            if (counts[fidx] !== exp_count || (exp_minx >= 0 && minxs[fidx] !== exp_minx)) begin
                $display("FAIL f%0d count=%0d (exp %0d) minx=%0d (exp %0d)",
                         fidx, counts[fidx], exp_count, minxs[fidx], exp_minx);
                errors = errors + 1;
            end else begin
                $display("PASS f%0d count=%0d minx=%0d", fidx, counts[fidx], minxs[fidx]);
            end
        end
    endtask

    initial begin
        repeat (10) @(posedge clk); #1;
        rst_n = 1;
        for (f = 0; f < 12; f = f + 1) begin
            fx = (f <= 5) ? 400 : (480 + (f - 6) * 80);
            run_frame(f, fx);
        end
        // 取最后一帧的扫描结果
        @(posedge clk); #1;
        vs = 1; de = 0;
        repeat (3) @(posedge clk); #1;
        vs = 0;
        repeat (30000) @(posedge clk);
        #1;
        counts[11] = o_count;
        minxs[11] = o_det_box[47:36];

        for (f = 0; f <= 5; f = f + 1) check(f, 0, -1);
        // f6 与 5 帧前位置有 64px 重叠，严格碎片门限下允许暂时 0 个，最多 1 个
        if (counts[6] > 1) begin
            $display("FAIL f6 count=%0d (exp <=1)", counts[6]);
            errors = errors + 1;
        end else begin
            $display("PASS f6 count=%0d", counts[6]);
        end
        // 固定框 160x160：minx = 球中心 - 80 = (x+72) - 80 = x - 8
        check(7, 1, 552);
        check(8, 1, 632);
        check(9, 1, 712);
        check(10, 1, 792);
        check(11, 1, 872);

        // 掩膜视图检查（帧 7..11 显示的是帧 6..10 的掩膜）
        if (mask_center !== 1'b1) begin
            $display("FAIL mask center=%b (exp 1, last frame)", mask_center);
            errors = errors + 1;
        end else begin
            $display("PASS mask center=%b", mask_center);
        end
        if (mask_bg !== 1'b0) begin
            $display("FAIL mask bg=%b (exp 0, last frame)", mask_bg);
            errors = errors + 1;
        end else begin
            $display("PASS mask bg=%b", mask_bg);
        end
        // 块边界：x=799 为块 49 末像素(0)，x=800/815 为块 50(1)，验证首像素不偏移
        if (mask_edge_prev !== 1'b0 || mask_edge_first !== 1'b1 || mask_edge_last !== 1'b1) begin
            $display("FAIL mask edge prev=%b first=%b last=%b (exp 0/1/1)",
                     mask_edge_prev, mask_edge_first, mask_edge_last);
            errors = errors + 1;
        end else begin
            $display("PASS mask edge prev=%b first=%b last=%b",
                     mask_edge_prev, mask_edge_first, mask_edge_last);
        end

        if (errors != 0) begin
            $display("RESULT FAIL errors=%0d", errors);
            $fatal(1);
        end
        $display("RESULT PASS");
        $finish;
    end
endmodule
