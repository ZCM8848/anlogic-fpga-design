`timescale 1ns / 1ps
// tb_buzzer_beep.v — 蜂鸣短鸣触发与静音测试
module tb_buzzer_beep;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg trig_toggle = 1'b0;
    reg [23:0] half_clks = 24'd2;
    reg [15:0] beep_ms = 16'd1;
    wire buzzer;

    integer errors = 0;
    integer toggles = 0;
    integer i;

    buzzer_beep dut (
        .I_clk         ( clk         ),
        .I_rst_n       ( rst_n       ),
        .I_trig_toggle ( trig_toggle ),
        .I_half_clks   ( half_clks   ),
        .I_beep_ms     ( beep_ms     ),
        .O_buzzer      ( buzzer      )
    );

    always #10 clk = ~clk;  // 50 MHz

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        if (buzzer !== 1'b1) begin
            $display("[ERR] reset buzzer=%b expected 1", buzzer);
            errors = errors + 1;
        end

        // 触发短鸣
        trig_toggle = 1'b1;
        repeat (200) @(posedge clk);

        // 1ms = 50000 cycles，200 拍后方波应已翻转
        toggles = 0;
        for (i = 0; i < 100; i = i + 1) begin
            @(posedge clk);
            if (buzzer !== 1'b1) toggles = toggles + 1;
        end
        if (toggles == 0) begin
            $display("[ERR] no buzzer toggling after trigger");
            errors = errors + 1;
        end

        // 等待 1ms + 余量后应回到静音
        repeat (70000) @(posedge clk);
        if (buzzer !== 1'b1) begin
            $display("[ERR] buzzer not silent after beep, got %b", buzzer);
            errors = errors + 1;
        end

        // half=0 时静音
        half_clks = 24'd0;
        trig_toggle = 1'b0;
        repeat (10) @(posedge clk);
        trig_toggle = 1'b1;
        repeat (1000) @(posedge clk);
        if (buzzer !== 1'b1) begin
            $display("[ERR] buzzer should be silent when half=0");
            errors = errors + 1;
        end

        if (errors == 0) $display("TB_BUZZER_BEEP PASS");
        else             $display("TB_BUZZER_BEEP FAIL errors=%0d", errors);
        $finish;
    end

    initial begin #5000000 $display("TIMEOUT"); $finish(1); end
endmodule
