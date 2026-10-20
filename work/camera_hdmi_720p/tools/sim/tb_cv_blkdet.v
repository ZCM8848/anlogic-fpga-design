`timescale 1ns / 1ps
// tb_cv_blkdet.v — cv_blkdet 5 帧背景差分 + CCL 面积累加的功能验证
//   帧 0..5：暗块静止在 x=400（背景同位置 -> 不应检出）
//   帧 6..11：暗块每帧右移 80px（与 5 帧前位置不同 -> 应各检出 1 个）
//   期望：f0..5 count=0；f7..11 count=1 且 minx=560/640/720/800/880；
//         f6 与 5 帧前位置有重叠，允许 2 段。
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

    cv_blkdet #(
        .IMG_W(1280), .IMG_H(720),
        .DARK_THR(100), .CB_DELTA(20),
        .MIN_BLKN(14), .MAX_BLKN(400),
        .MIN_FILL(40), .MIN_RATIO(50),
        .MAX_BLOBS(8)
    ) dut (
        .clk(clk), .rst_n(rst_n), .de(de), .vs(vs), .rgb(rgb),
        .i_sel(i_sel), .i_wide(1'b0), .o_ready(o_ready), .o_count(o_count), .o_det_box(o_det_box)
    );

    always #5 clk = ~clk;

    integer f, x, y;
    integer fx;
    integer counts [0:11];
    integer minxs [0:11];
    integer errors = 0;

    task automatic run_frame(input integer fnum, input integer xpos);
        begin
            @(posedge clk); #1;
            vs = 1; de = 0;
            repeat (3) @(posedge clk); #1;
            vs = 0;
            repeat (20) @(posedge clk);
            // 上一帧掩膜在 vs 上升沿后扫描；等待扫描完成再采样
            repeat (25000) @(posedge clk);
            #1;
            if (fnum > 0) begin
                counts[fnum-1] = o_count;
                minxs[fnum-1] = o_det_box[47:36];
            end
            // active 帧：亮背景 + 144x144 暗块
            for (y = 0; y < 720; y = y + 1) begin
                for (x = 0; x < 1280; x = x + 1) begin
                    de = 1;
                    rgb = (x >= xpos && x < xpos + 144 && y >= 300 && y < 444)
                          ? 24'h282828 : 24'hC8C8C8;
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
        repeat (25000) @(posedge clk);
        #1;
        counts[11] = o_count;
        minxs[11] = o_det_box[47:36];

        for (f = 0; f <= 5; f = f + 1) check(f, 0, -1);
        if (counts[6] < 1) begin
            $display("FAIL f6 count=%0d (exp >=1)", counts[6]);
            errors = errors + 1;
        end else begin
            $display("PASS f6 count=%0d", counts[6]);
        end
        check(7, 1, 560);
        check(8, 1, 640);
        check(9, 1, 720);
        check(10, 1, 800);
        check(11, 1, 880);

        if (errors != 0) begin
            $display("RESULT FAIL errors=%0d", errors);
            $fatal(1);
        end
        $display("RESULT PASS");
        $finish;
    end
endmodule
