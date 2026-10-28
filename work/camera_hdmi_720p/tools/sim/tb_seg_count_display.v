`timescale 1ns / 1ps
// tb_seg_count_display.v — 5 位右对齐 BCD 显示 + 左 3 位熄灭
module tb_seg_count_display;

    reg        clk = 1'b0;
    reg        rst_n = 1'b0;
    reg [19:0] bcd = 20'h12345;   // 万=1 千=2 百=3 十=4 个=5
    wire [7:0] seg;
    wire [7:0] sel;

    integer errors = 0;
    integer i;

    seg_count_display #(
        .CLK_HZ  ( 1_000_000 ),
        .SCAN_HZ ( 100_000   )
    ) dut (
        .I_clk   ( clk   ),
        .I_rst_n ( rst_n ),
        .I_bcd   ( bcd   ),
        .O_seg   ( seg   ),
        .O_sel   ( sel   )
    );

    always #500 clk = ~clk;

    function [7:0] seg_decode;
        input [3:0] val;
        begin
            case (val)
                4'h0: seg_decode = 8'hC0;
                4'h1: seg_decode = 8'hF9;
                4'h2: seg_decode = 8'hA4;
                4'h3: seg_decode = 8'hB0;
                4'h4: seg_decode = 8'h99;
                4'h5: seg_decode = 8'h92;
                4'h6: seg_decode = 8'h82;
                4'h7: seg_decode = 8'hF8;
                4'h8: seg_decode = 8'h80;
                4'h9: seg_decode = 8'h90;
                default: seg_decode = 8'hFF;
            endcase
        end
    endfunction

    task check_digit;
        input [2:0] idx;
        input [3:0] exp;
        begin
            while (sel !== ~(8'h01 << idx))
                @(posedge clk);
            #1;
            if (seg !== seg_decode(exp)) begin
                $display("[ERR] digit %0d: seg=%02h expected=%02h", idx, seg, seg_decode(exp));
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (20) @(posedge clk);

        // O_sel[0] 最右=个位 5，O_sel[4] 最左=万位 1
        check_digit(3'd0, 4'h5);
        check_digit(3'd1, 4'h4);
        check_digit(3'd2, 4'h3);
        check_digit(3'd3, 4'h2);
        check_digit(3'd4, 4'h1);

        // 左 3 位应全灭
        check_digit(3'd5, 4'hF);
        check_digit(3'd6, 4'hF);
        check_digit(3'd7, 4'hF);

        if (errors == 0) $display("TB_SEG_COUNT PASS");
        else             $display("TB_SEG_COUNT FAIL errors=%0d", errors);
        $finish;
    end

endmodule
