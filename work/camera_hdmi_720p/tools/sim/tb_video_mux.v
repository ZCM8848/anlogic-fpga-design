`timescale 1ns / 1ps
// tb_video_mux.v — video_mux 帧边界切换单元测试
// 覆盖：
//   1) camera_sel=0 → 测试图案
//   2) camera_sel=1 → 摄像头
//   3) 切换只在下一帧 cam_vs 上升沿生效（不在半帧立即切）
module tb_video_mux;

    reg clk = 0;
    reg rst_n = 0;
    reg I_camera_sel = 0;

    reg [23:0] pat_data = 24'hAAAAAA;
    reg        pat_de   = 1'b1;
    reg        pat_vs   = 1'b0;

    reg [23:0] cam_data = 24'h555555;
    reg        cam_de   = 1'b1;
    reg        cam_vs   = 1'b0;

    wire [23:0] O_data;
    wire        O_de;
    wire        O_vs;
    wire        O_sel;

    integer errors = 0;
    integer cyc = 0;

    video_mux dut (
        .clk          ( clk          ),
        .rst_n        ( rst_n        ),
        .I_camera_sel ( I_camera_sel ),
        .I_pat_data   ( pat_data     ),
        .I_pat_de     ( pat_de       ),
        .I_pat_vs     ( pat_vs       ),
        .I_cam_data   ( cam_data     ),
        .I_cam_de     ( cam_de       ),
        .I_cam_vs     ( cam_vs       ),
        .O_data       ( O_data       ),
        .O_de         ( O_de         ),
        .O_vs         ( O_vs         ),
        .O_sel        ( O_sel        )
    );

    always #5 clk = ~clk;

    // cam_vs 每 10 拍一个单拍脉冲；pat_vs 错开 5 拍
    always @(posedge clk) begin
        cyc     <= cyc + 1;
        cam_vs  <= (cyc % 10 == 0);
        pat_vs  <= (cyc % 10 == 5);
    end

    task check_sel;
        input        exp_sel;
        input [23:0] exp_data;
        begin
            if (O_sel !== exp_sel) begin
                $display("FAIL: O_sel=%b expected %b @%0t", O_sel, exp_sel, $time);
                errors = errors + 1;
            end
            if (O_data !== exp_data) begin
                $display("FAIL: O_data=%h expected %h @%0t", O_data, exp_data, $time);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // 1) camera_sel=0 -> 测试图案
        I_camera_sel = 0;
        repeat (12) @(posedge clk);
        check_sel(1'b0, pat_data);

        // 2) camera_sel=1 -> 摄像头（下一帧 cam_vs 后生效）
        I_camera_sel = 1;
        repeat (12) @(posedge clk);
        check_sel(1'b1, cam_data);

        // 3) 半帧内保持摄像头，直到下一帧 cam_vs
        I_camera_sel = 0;
        repeat (2) @(posedge clk);
        if (O_sel !== 1'b1) begin
            $display("FAIL: half-frame switch, O_sel=%b @%0t", O_sel, $time);
            errors = errors + 1;
        end
        @(posedge cam_vs);
        repeat (3) @(posedge clk);
        check_sel(1'b0, pat_data);

        if (errors == 0) $display("tb_video_mux: ALL PASS");
        else             $display("tb_video_mux: %0d FAILURE(S)", errors);
        $finish;
    end

endmodule
