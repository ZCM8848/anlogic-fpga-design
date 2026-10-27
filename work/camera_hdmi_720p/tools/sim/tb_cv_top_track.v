`timescale 1ns / 1ps
// tb_cv_top_track.v — 强制块域检测框，验证 cv_top 的固定识别框与轨迹去重。
module tb_cv_top_track;
    reg clk = 0;
    reg rst_n = 0;
    reg cv_on = 1;
    reg de = 0;
    reg vs = 0;
    reg [23:0] data = 24'd0;

    wire o_de, o_vs, o_ccl_busy, o_run_overflow, o_mask_bit;
    wire [23:0] o_data;
    wire [5:0] o_blob_cnt;
    wire [10:0] o_run_cnt;
    wire [7:0] o_bin_thr;
    wire [15:0] o_count, o_count_bcd;

    cv_top #(
        .IMG_W(1280), .IMG_H(720), .MASK_SRC(3), .DARK_THR(100),
        .MIN_BLKN(14), .MAX_BLOBS(8)
    ) dut (
        .I_clk(clk), .I_rst_n(rst_n), .I_cv_on(cv_on), .I_mask_view(1'b0),
        .I_thr_up(1'b0), .I_thr_dn(1'b0), .I_de(de), .I_vs(vs),
        .I_data(data), .I_det_data(data),
        .O_de(o_de), .O_vs(o_vs), .O_data(o_data),
        .O_blob_cnt(o_blob_cnt), .O_run_cnt(o_run_cnt),
        .O_ccl_busy(o_ccl_busy), .O_run_overflow(o_run_overflow),
        .O_bin_thr(o_bin_thr), .O_count(o_count), .O_count_bcd(o_count_bcd)
    );

    always #5 clk = ~clk;

    integer errors = 0;

    task run_frame;
        begin
            @(posedge clk); vs = 1;
            repeat (3) @(posedge clk); vs = 0;
            repeat (2000) @(posedge clk);
        end
    endtask

    task check_track0(input [8*24-1:0] name);
        begin
            if (dut.track[0][106] !== 1'b1) begin
                $display("FAIL %0s track0 invalid", name);
                errors = errors + 1;
            end
            if (dut.track[1][106] !== 1'b0) begin
                $display("FAIL %0s track1 should be suppressed", name);
                errors = errors + 1;
            end
            if ((dut.track[0][35:24] - dut.track[0][47:36] + 1) != 160) begin
                $display("FAIL %0s track0 box width=%0d", name,
                         dut.track[0][35:24] - dut.track[0][47:36] + 1);
                errors = errors + 1;
            end
            if ((dut.track[0][11:0] - dut.track[0][23:12] + 1) != 160) begin
                $display("FAIL %0s track0 box height=%0d", name,
                         dut.track[0][11:0] - dut.track[0][23:12] + 1);
                errors = errors + 1;
            end
            if (dut.track[0][47:36] != 552) begin
                $display("FAIL %0s track0 minx=%0d", name, dut.track[0][47:36]);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        // 强制块域检测：两个框中心相距 68 px，第二框应作为同一颗钢珠的碎片丢弃
        force dut.blk_ready = 1'b1;
        force dut.blk_count = 6'd2;
        force dut.blk_det_box = (dut.blk_det_sel == 3'd0)
              ? {12'd528, 12'd735, 12'd256, 12'd463}
              : {12'd596, 12'd803, 12'd256, 12'd463};

        repeat (10) @(posedge clk); #1; rst_n = 1;
        repeat (10) @(posedge clk);

        run_frame;
        check_track0("new");

        run_frame;
        check_track0("matched");

        force dut.blk_count = 6'd0;
        run_frame;
        check_track0("coast");

        if (errors != 0) begin
            $display("RESULT FAIL errors=%0d", errors);
            $fatal(1);
        end
        $display("RESULT PASS");
        $finish;
    end
endmodule
