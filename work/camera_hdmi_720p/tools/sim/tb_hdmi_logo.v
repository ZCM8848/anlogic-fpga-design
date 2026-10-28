`timescale 1ns / 1ps
// tb_hdmi_logo.v — 验证 Logo 2 级流水与 I_data 延迟对齐
module tb_hdmi_logo;

    reg         clk = 1'b0;
    reg         rst_n = 1'b0;
    reg         vsync = 1'b0;
    reg         hsync = 1'b0;
    reg         de = 1'b0;
    reg         user = 1'b0;
    reg         last = 1'b0;
    reg         osd_on = 1'b0;
    reg         ui_on = 1'b1;
    reg  [3:0]  debug_status = 4'd0;
    reg  [23:0] rd_data = 24'h112233;

    wire        rd_en;
    wire        hdmi_vs;
    wire        hdmi_hs;
    wire        hdmi_de;
    wire [23:0] hdmi_data;

    hdmi_mixer dut (
        .I_clk           ( clk           ),
        .I_rst_n         ( rst_n         ),
        .I_video_vsync   ( vsync         ),
        .I_video_hsync   ( hsync         ),
        .I_video_de      ( de            ),
        .I_video_user    ( user          ),
        .I_video_last    ( last          ),
        .I_osd_on        ( osd_on        ),
        .I_ui_on         ( ui_on         ),
        .I_debug_status  ( debug_status  ),
        .O_video_rd_en   ( rd_en         ),
        .I_video_rd_data ( rd_data       ),
        .O_hdmi_vsync    ( hdmi_vs       ),
        .O_hdmi_hsync    ( hdmi_hs       ),
        .O_hdmi_de       ( hdmi_de       ),
        .O_hdmi_data     ( hdmi_data     )
    );

    always #5 clk = ~clk;

    integer x, y;
    integer out_x = 0;
    integer out_y = 0;
    integer hits = 0;
    integer first_x = -1;
    integer first_y = -1;
    reg [23:0] first_color = 24'h0;

    always @(posedge clk) begin
        if (hdmi_de) begin
            if ((hdmi_data != 24'h112233) && (hits < 8)) begin
                $display("HIT out=(%0d,%0d) data=%06h", out_x, out_y, hdmi_data);
                if (hits == 0) begin
                    first_x = out_x;
                    first_y = out_y;
                    first_color = hdmi_data;
                end
                hits = hits + 1;
            end
            if (out_x == 1279) begin
                out_x <= 0;
                out_y <= out_y + 1;
            end
            else begin
                out_x <= out_x + 1;
            end
        end
    end

    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // 帧起始
        user = 1'b1;
        @(posedge clk);
        user = 1'b0;

        // 只跑 60 行，覆盖 Logo 的 y=58
        for (y = 0; y < 60; y = y + 1) begin
            for (x = 0; x < 1280; x = x + 1) begin
                de   = 1'b1;
                last = (x == 1279);
                @(posedge clk);
            end
            de   = 1'b0;
            last = 1'b0;
            repeat (4) @(posedge clk);
        end

        $display("FIRST hit=(%0d,%0d) color=%06h hits=%0d", first_x, first_y, first_color, hits);
        if (first_x == 78 && first_y == 58 && first_color == 24'hd3d4d8)
            $display("TB_HDMI_LOGO PASS");
        else
            $display("TB_HDMI_LOGO FAIL");
        $finish;
    end

endmodule
