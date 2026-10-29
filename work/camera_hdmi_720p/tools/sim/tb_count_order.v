`timescale 1ns / 1ps
// tb_count_order.v — HDMI 5-digit Count 必须“左万位、右个位”
module tb_count_order;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg [23:0] I_data = 24'h112233;
    reg I_de = 1'b1;
    reg I_vs = 1'b0;
    reg I_cv_on = 1'b1;
    reg I_ui_on = 1'b1;
    reg [19:0] I_count_bcd = 20'h00001;  // count = 1
    wire [23:0] O_data;

    cv_top #(
        .IMG_W(64), .IMG_H(48),
        .MAX_RUNS(64), .MASK_VIEW(0),
        .BALL_W(16), .BALL_H(12), .BALL_SCALE(4)
    ) dut (
        .I_clk(clk), .I_rst_n(rst_n),
        .I_cv_on(I_cv_on), .I_ui_on(I_ui_on),
        .I_thr_up(1'b0), .I_thr_dn(1'b0),
        .I_de(I_de), .I_vs(I_vs), .I_data(I_data),
        .I_ball_en(1'b0), .I_ball_bg_thr(8'd0), .I_ball_min_run(8'd0),
        .I_ball_roi_y1(9'd180), .I_ball_max_run_len(10'd1023),
        .I_ball_capture(1'b0),
        .I_disp_mode(2'd0), .I_debug_view(1'b0),
        .O_ball_bg_ready(), .O_ball_capturing(),
        .I_ahb_clk(clk), .I_run_rd_addr(10'd0), .O_run_rd_data(),
        .I_overlay(512'd0), .I_count(16'd0), .I_count_bcd(I_count_bcd),
        .O_de(), .O_vs(), .O_data(O_data),
        .O_run_cnt(), .O_min_y(), .O_max_y(),
        .O_skip_roi_cnt(), .O_skip_len_cnt(),
        .O_run_overflow(), .O_bin_thr()
    );

    always #5 clk = ~clk;

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);
        // 左起第 1 位（万位）在 count=1 时应显示 '0'；
        // MiSans 30x34 的 '0' 在 local (13,3) 有像素。
        force dut.r_x = 12'd37;   // CNT_X=24 + 13
        force dut.r_y = 12'd641;  // CNT_Y=638 + 3
        #2;
        if (O_data !== 24'h00E6FF) begin
            $display("FAIL leftmost digit expected count color, got %06h", O_data);
            $display("TB_COUNT_ORDER FAIL");
        end else begin
            $display("TB_COUNT_ORDER PASS (leftmost=0, rightmost=1)");
        end
        release dut.r_x;
        release dut.r_y;
        $finish;
    end

endmodule
