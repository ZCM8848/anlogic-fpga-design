`timescale 1ns / 1ps
// tb_buzzer_song.v — 播放/暂停/复位测试
module tb_buzzer_song;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg play = 1'b0;
    wire buzzer;

    integer errors = 0;
    integer toggles = 0;
    integer i;

    buzzer_song dut (
        .I_clk    ( clk    ),
        .I_rst_n  ( rst_n  ),
        .I_play   ( play   ),
        .O_buzzer ( buzzer )
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

        // 播放后应有方波（首个音符 G5 half≈31888）
        play = 1'b1;
        repeat (70000) @(posedge clk);
        toggles = 0;
        for (i = 0; i < 40000; i = i + 1) begin
            @(posedge clk);
            if (buzzer !== 1'b1) toggles = toggles + 1;
        end
        if (toggles == 0) begin
            $display("[ERR] no buzzer toggling after play");
            errors = errors + 1;
        end

        // 暂停后应回到静音
        play = 1'b0;
        repeat (100) @(posedge clk);
        if (buzzer !== 1'b1) begin
            $display("[ERR] buzzer not silent after pause, got %b", buzzer);
            errors = errors + 1;
        end

        if (errors == 0) $display("TB_BUZZER_SONG PASS");
        else             $display("TB_BUZZER_SONG FAIL errors=%0d", errors);
        $finish;
    end

    initial begin #5000000 $display("TIMEOUT"); $finish(1); end
endmodule
