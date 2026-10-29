`timescale 1ns / 1ps
// tb_ae_set.v - MCU-controlled exposure/gain setpoint
module tb_ae_set;

    reg         clk = 1'b0;
    reg         rst = 1'b1;
    reg  [15:0] ae_set = 16'd700;
    reg  [15:0] ag_set = 16'd144;
    reg         cam_cfg_done = 1'b0;
    reg         ae_cfg_done = 1'b0;
    wire        ae_req;
    wire [15:0] ae;
    wire [15:0] ag;

    ae_set dut (
        .I_clk         ( clk          ),
        .I_rst         ( rst          ),
        .I_ae_set      ( ae_set       ),
        .I_ag_set      ( ag_set       ),
        .I_ae_cfg_done ( ae_cfg_done  ),
        .I_cam_cfg_done( cam_cfg_done ),
        .O_ae_req      ( ae_req       ),
        .O_ae          ( ae           ),
        .O_ag          ( ag           )
    );

    always #20.833 clk = ~clk;  // ~24 MHz

    integer errors = 0;
    integer guard;

    task wait_req;
        begin
            guard = 0;
            while (!ae_req && guard < 1000) begin
                @(posedge clk);
                guard = guard + 1;
            end
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (4) @(posedge clk);

        // 配置未完成时不应写 sensor
        if (ae_req !== 1'b0) begin
            $display("[ERR] request before config done");
            errors = errors + 1;
        end

        cam_cfg_done = 1'b1;
        ae_cfg_done  = 1'b1;
        wait_req;
        #1;
        if (ae !== 16'd700 || ag !== 16'd144) begin
            $display("[ERR] first write ae=%0d ag=%0d", ae, ag);
            errors = errors + 1;
        end

        @(posedge clk);
        ae_set = 16'd500;
        wait_req;
        #1;
        if (ae !== 16'd500) begin
            $display("[ERR] second write ae=%0d", ae);
            errors = errors + 1;
        end

        @(posedge clk);
        ae_set = 16'd0;       // clamp to 2
        wait_req;
        #1;
        if (ae !== 16'd2) begin
            $display("[ERR] ae clamp got %0d", ae);
            errors = errors + 1;
        end

        if (errors == 0) $display("TB_AE_SET PASS");
        else             $display("TB_AE_SET FAIL errors=%0d", errors);
        $finish;
    end

    initial begin #200000 $display("TIMEOUT"); $finish(1); end
endmodule
