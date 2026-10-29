`timescale 1ns / 1ps

// buzzer_music_top 行为级自检（iverilog）
// 仿真参数把 1ms 节拍缩到 MS_DIV=200 个时钟、吐音 GAP_MS=2，便于快速跑完若干事件；
// note2half 查表仍按 50MHz（与上板一致），故方波“半周期时钟数”与真实硬件相同，
// 仿真只校验时钟数（计数），不校验绝对频率。
module tb_buzzer_music;

    reg  clk = 1'b0;
    reg  key1 = 1'b1;          // 松开
    wire buzzer;
    wire led_play;

    integer errors = 0;

    localparam integer MS_DIV = 200;
    localparam integer GAP_MS = 2;

    buzzer_music_top #(
        .CLK_HZ      ( 50_000_000 ),
        .MS_DIV      ( MS_DIV      ),
        .DEBOUNCE_MS ( 1           ),
        .GAP_MS      ( GAP_MS      ),
        .POR_CYCLES  ( 10          ),
        .SONG_DEPTH  ( 2048        ),
        .IDXW        ( 11          )
    ) dut (
        .I_sys_clk  ( clk     ),
        .I_key1     ( key1    ),
        .O_buzzer   ( buzzer  ),
        .O_led_play ( led_play )
    );

    always #5 clk = ~clk;     // 10ns 周期

    // 与 gen_song.py 同公式：freq = 440*2^((n-69)/12)，half = round(CLK_HZ/(2*freq))
    function real freq_of;
        input integer n; begin freq_of = 440.0 * (2.0 ** ((n - 69) / 12.0)); end
    endfunction
    function integer half_of;
        input integer n;
        real f;
        begin
            if (n <= 0) half_of = 0;
            else begin
                f = 440.0 * (2.0 ** ((n - 69) / 12.0));
                half_of = (50000000.0 / (2.0 * f)) + 0.5;   // real->integer 截断 = 四舍五入
            end
        end
    endfunction

    integer t_fall1, t_fall2, period, diff;

    task wait_falling;
        output integer t;
        begin
            while (buzzer !== 1'b1) @(posedge clk);   // 先回到高
            while (buzzer !== 1'b0) @(posedge clk);   // 再等下降沿
            t = $time;
        end
    endtask

    task press_key;
        begin
            // DEBOUNCE_MAX = (CLK_HZ/1000)*DEBOUNCE_MS = 50000 clks（CLK_HZ=50e6, MS=1）
            // 必须保持稳定超过该值，否则消抖不通过、playing 不翻转。
            key1 = 1'b0;
            repeat (51000) @(posedge clk);
            key1 = 1'b1;
            repeat (51000) @(posedge clk);
        end
    endtask

    integer half_g5;
    initial begin
        half_g5 = half_of(79);   // G5，song_rom[0]

        // ---- 等上电复位完成 ----
        repeat (40) @(posedge clk);

        // ---- 1) ROM 头几条数据正确（验证 song_data.vh 被正确包含）----
        // {note[7:0], dur_ms[15:0]}：song_rom[0]={79,599}=0x4F0257；
        // [1]=rest 1ms=0x000001；[2]={76,179}=0x4C00B3
        if (dut.song_rom[0] !== 24'h4F0257) begin
            $display("[ERR] song_rom[0]=%h expected 4F0257", dut.song_rom[0]); errors = errors + 1; end
        if (dut.song_rom[1] !== 24'h000001) begin
            $display("[ERR] song_rom[1]=%h expected 000001", dut.song_rom[1]); errors = errors + 1; end
        if (dut.song_rom[2] !== 24'h4C00B3) begin
            $display("[ERR] song_rom[2]=%h expected 4C00B3", dut.song_rom[2]); errors = errors + 1; end

        // ---- 2) note2half 查表与公式一致（通过 peek dut.half / dut.cur_note）----
        // 等第一音 G5 进入播放（cur_note=79）
        while (dut.cur_note !== 8'd79) @(posedge clk);
        diff = dut.half - half_g5;
        if (diff < 0) diff = -diff;
        if (diff > 1) begin
            $display("[ERR] note2half(79) half=%0d expected~%0d", dut.half, half_g5); errors = errors + 1; end
        else
            $display("[OK]  note2half(79)=%0d (formula %0d, rounding tol 1)", dut.half, half_g5);

        // ---- 3) 上电自动播放：led_play=1 ----
        if (led_play !== 1'b1) begin
            $display("[ERR] auto-play led_play=%b expected 1", led_play); errors = errors + 1; end

        // ---- 4) 第一音 G5：buzzer 方波周期 = 2*dut.half（发生器直接用查表值）----
        wait_falling(t_fall1);
        wait_falling(t_fall2);
        period = (t_fall2 - t_fall1) / 10;     // ns -> clk
        diff = period - 2*dut.half;
        if (diff < 0) diff = -diff;
        if (diff > 2) begin
            $display("[ERR] G5 period=%0d(clk) expected %0d", period, 2*dut.half); errors = errors + 1; end
        else
            $display("[OK]  G5 toggle period=%0d clk (expected %0d)", period, 2*dut.half);

        // ---- 5) 播放/暂停：按 KEY1 后 led_play=0、buzzer 静音(高) ----
        press_key();
        repeat (5) @(posedge clk);
        if (led_play !== 1'b0) begin
            $display("[ERR] pause led_play=%b expected 0", led_play); errors = errors + 1; end
        repeat (10 * MS_DIV) @(posedge clk);
        if (buzzer !== 1'b1) begin
            $display("[ERR] pause buzzer=%b expected 1 (silent)", buzzer); errors = errors + 1; end
        else
            $display("[OK]  paused: buzzer silent (high)");

        // ---- 6) 再按一次恢复播放：led_play=1，buzzer 重新翻转 ----
        press_key();
        repeat (5) @(posedge clk);
        if (led_play !== 1'b1) begin
            $display("[ERR] resume led_play=%b expected 1", led_play); errors = errors + 1; end
        wait_falling(t_fall1);
        $display("[OK]  resumed: buzzer toggling again");

        if (errors == 0)
            $display("[PASS] buzzer_music: ROM/note2half/auto-play/tone-period/pause-resume all OK");
        else
            $display("[FAIL] buzzer_music: %0d errors", errors);
        $finish;
    end

    initial begin
        #200_000_000;  // 200ms 仿真超时
        $display("[FAIL] buzzer_music: timeout");
        $finish;
    end

endmodule
