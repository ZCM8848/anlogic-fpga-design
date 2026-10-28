`timescale 1ns / 1ps
// tb_ui_overlay.v — 识别态 UI：Logo / STEEL BALL / Anlogic HX1P35A / FRAME 文字位置
module tb_ui_overlay;

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
    integer label_hits = 0;
    integer text_hits = 0;
    integer frame_hits = 0;
    integer label_first_x = -1;
    integer text_first_x = -1;
    integer frame_first_x = -1;
    integer logo_first_x = -1;
    integer logo_first_y = -1;

    always @(posedge clk) begin
        if (hdmi_de) begin
            if ((out_y >= 612) && (out_y < 630) && (hdmi_data == 24'h8be9fd)) begin
                if (label_hits == 0) label_first_x = out_x;
                label_hits = label_hits + 1;
            end
            if ((out_y >= 172) && (out_y < 196) && (hdmi_data == 24'hfff200)) begin
                if (text_hits == 0) text_first_x = out_x;
                text_hits = text_hits + 1;
            end
            if ((out_y >= 680) && (out_y < 700) && (hdmi_data == 24'h9aa7bd)) begin
                if (frame_hits == 0) frame_first_x = out_x;
                frame_hits = frame_hits + 1;
            end
            if ((logo_first_x < 0) && (hdmi_data == 24'hd3d4d8)) begin
                logo_first_x = out_x;
                logo_first_y = out_y;
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

        user = 1'b1;
        @(posedge clk);
        user = 1'b0;

        for (y = 0; y < 700; y = y + 1) begin
            for (x = 0; x < 1280; x = x + 1) begin
                de   = 1'b1;
                last = (x == 1279);
                @(posedge clk);
            end
            de   = 1'b0;
            last = 1'b0;
            repeat (4) @(posedge clk);
        end

        $display("LOGO  first=(%0d,%0d)", logo_first_x, logo_first_y);
        $display("LABEL hits=%0d first_x=%0d (y=612)", label_hits, label_first_x);
        $display("TEXT  hits=%0d first_x=%0d (y=172)", text_hits, text_first_x);
        $display("FRAME hits=%0d first_x=%0d (y=680)", frame_hits, frame_first_x);

        if ((logo_first_x == 78) && (logo_first_y == 58) &&
            (label_hits > 0) && (text_hits > 0) && (frame_hits > 0))
            $display("TB_UI_OVERLAY PASS");
        else
            $display("TB_UI_OVERLAY FAIL");
        $finish;
    end

endmodule
