`timescale 1ns / 1ps
// tb_test_pattern.v - verify MiSans test-pattern text ROM is visible
module tb_test_pattern;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg vs = 1'b0;
    reg de = 1'b0;
    reg [11:0] x = 12'd0;
    reg [11:0] y = 12'd0;
    wire [23:0] data;
    wire de_o;
    wire vs_o;

    test_pattern dut (
        .clk   ( clk   ),
        .rst_n ( rst_n ),
        .vs    ( vs    ),
        .de    ( de    ),
        .x     ( x     ),
        .y     ( y     ),
        .data  ( data  ),
        .de_o  ( de_o  ),
        .vs_o  ( vs_o  )
    );

    always #5 clk = ~clk;

    integer ix, iy;
    integer text_pixels = 0;
    integer bg_pixels = 0;
    integer attr_pixels = 0;
    integer first_x = -1;
    integer first_y = -1;

    always @(posedge clk) begin
        if (de_o && (y >= 12'd40) && (y < 12'd60) &&
            (x >= 12'd40) && (x < 12'd330)) begin
            if (data == 24'hFFFFFF) begin
                if (first_x < 0) begin
                    first_x = x;
                    first_y = y;
                end
                text_pixels = text_pixels + 1;
            end
            else if (data == 24'h000000) begin
                bg_pixels = bg_pixels + 1;
            end
        end
        if (de_o && (y >= 12'd64) && (y < 12'd84) &&
            (x >= 12'd40) && (x < 12'd200)) begin
            if (data == 24'hC0C0C0) attr_pixels = attr_pixels + 1;
        end
    end

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        de = 1'b1;

        for (iy = 40; iy < 84; iy = iy + 1) begin
            for (ix = 40; ix < 330; ix = ix + 1) begin
                x = ix[11:0];
                y = iy[11:0];
                @(posedge clk);
            end
        end

        $display("TP text_pixels=%0d bg_pixels=%0d attr_pixels=%0d first=(%0d,%0d)",
                 text_pixels, bg_pixels, attr_pixels, first_x, first_y);
        if ((text_pixels > 100) && (bg_pixels > 1000) && (attr_pixels > 100) &&
            (first_x >= 40) && (first_x < 330) &&
            (first_y >= 40) && (first_y < 60))
            $display("TB_TEST_PATTERN PASS");
        else
            $display("TB_TEST_PATTERN FAIL");
        $finish;
    end

endmodule
