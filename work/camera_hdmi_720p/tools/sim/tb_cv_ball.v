`timescale 1ns/1ps
// tb_cv_ball.v — cv_top ball front-end: 4x4 bin, background capture, diff run
module tb_cv_ball;
    localparam IMG_W  = 64;
    localparam IMG_H  = 48;
    localparam BALL_W = 16;
    localparam BALL_H = 12;

    reg clk = 0;
    reg rst_n = 0;
    reg I_cv_on = 1;
    reg I_thr_up = 0, I_thr_dn = 0;
    reg I_de = 0;
    reg I_vs = 0;
    reg [23:0] I_data = 0;
    reg I_ball_en = 1;
    reg [7:0] I_ball_bg_thr = 8'd30;
    reg [7:0] I_ball_min_run = 8'd1;
    reg I_ball_capture = 0;
    wire O_ball_bg_ready, O_ball_capturing;
    reg I_ahb_clk = 0;
    reg [9:0] I_run_rd_addr = 0;
    wire [31:0] O_run_rd_data;
    reg [511:0] I_overlay = 0;
    reg [15:0] I_count = 0;
    wire O_de, O_vs;
    wire [23:0] O_data;
    wire [10:0] O_run_cnt;
    wire [7:0] O_min_y, O_max_y;
    wire O_run_overflow;
    wire [7:0] O_bin_thr;

    cv_top #(
        .IMG_W(IMG_W), .IMG_H(IMG_H),
        .MAX_RUNS(64), .MASK_VIEW(0),
        .BALL_W(BALL_W), .BALL_H(BALL_H), .BALL_SCALE(4)
    ) dut (
        .I_clk(clk), .I_rst_n(rst_n), .I_cv_on(I_cv_on),
        .I_thr_up(I_thr_up), .I_thr_dn(I_thr_dn),
        .I_de(I_de), .I_vs(I_vs), .I_data(I_data),
        .I_ball_en(I_ball_en), .I_ball_bg_thr(I_ball_bg_thr),
        .I_ball_min_run(I_ball_min_run),
        .I_ball_capture(I_ball_capture),
        .I_disp_mode(2'd0),
        .O_ball_bg_ready(O_ball_bg_ready), .O_ball_capturing(O_ball_capturing),
        .I_ahb_clk(I_ahb_clk), .I_run_rd_addr(I_run_rd_addr),
        .O_run_rd_data(O_run_rd_data),
        .I_overlay(I_overlay), .I_count(I_count),
        .O_de(O_de), .O_vs(O_vs), .O_data(O_data),
        .O_run_cnt(O_run_cnt), .O_min_y(O_min_y), .O_max_y(O_max_y),
        .O_run_overflow(O_run_overflow), .O_bin_thr(O_bin_thr)
    );

    always #5 clk = ~clk;
    always #5 I_ahb_clk = ~I_ahb_clk;

    task frame(input integer g, input integer obj, input integer ox, input integer oy);
        integer x, y;
        begin
            @(negedge clk); I_vs = 1;
            @(negedge clk); I_vs = 0;
            for (y = 0; y < IMG_H; y = y + 1) begin
                for (x = 0; x < IMG_W; x = x + 1) begin
                    I_de = 1;
                    I_data = {8'h00,
                              ((obj != 0 && x >= ox && x < ox+4 &&
                                y >= oy && y < oy+4) ? 8'd200 : g[7:0]),
                              8'h00};
                    @(negedge clk);
                end
                I_de = 0;
                for (x = 0; x < 8; x = x + 1) @(negedge clk);
            end
        end
    endtask

    integer errors = 0;
    reg [31:0] rdat;

    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1;
        repeat (4) @(negedge clk);

        I_ball_capture = 1;
        repeat (4) @(negedge clk);
        frame(100, 0, 0, 0);          // background frame
        I_ball_capture = 0;
        repeat (2) @(negedge clk);

        frame(100, 1, 16, 12);        // one 4x4 full-res block -> one small pixel
        repeat (2) @(negedge clk);
        frame(100, 0, 0, 0);          // next vsync latches run count

        repeat (10) @(negedge clk);
        $display("bg_ready=%b capturing=%b run_cnt=%0d ovf=%b thr=%0d",
                 O_ball_bg_ready, O_ball_capturing, O_run_cnt, O_run_overflow, O_bin_thr);
        if (O_ball_bg_ready !== 1'b1) begin $display("FAIL bg_ready"); errors=errors+1; end
        if (O_run_cnt !== 11'd1) begin $display("FAIL run_cnt=%0d", O_run_cnt); errors=errors+1; end

        I_run_rd_addr = 10'd0;
        repeat (3) @(negedge clk);
        rdat = O_run_rd_data;
        $display("run0=%08x y=%0d xs=%0d xe=%0d",
                 rdat, (rdat>>22)&10'h3ff, (rdat>>11)&11'h7ff, rdat&11'h7ff);
        if (((rdat>>22)&10'h3ff) !== 10'd3) begin $display("FAIL run y"); errors=errors+1; end
        if (((rdat>>11)&11'h7ff) !== 11'd4) begin $display("FAIL run xs"); errors=errors+1; end
        if ((rdat&11'h7ff) !== 11'd4) begin $display("FAIL run xe"); errors=errors+1; end

        if (errors == 0) $display("TB_CV_BALL PASS");
        else             $display("TB_CV_BALL FAIL errors=%0d", errors);
        $finish;
    end
endmodule
