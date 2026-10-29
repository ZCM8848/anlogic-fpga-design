`timescale 1ns / 1ps

// seg_led_test_top 的行为级自检（iverilog）
// 仿真时把分频参数缩小，时钟用 1MHz，便于快速跑完消抖/按键步进/扫描。
module tb_seg_led_test;

    reg        clk = 1'b0;
    reg        sw1 = 1'b0;
    reg        key1 = 1'b1;
    wire [7:0] seg;
    wire [7:0] sel;

    integer errors = 0;
    integer i;

    // 1MHz 仿真时钟；分频参数与 CLK_HZ 一致
    seg_led_test_top #(
        .CLK_HZ      ( 1_000_000 ),
        .SCAN_HZ     ( 100_000   ),  // 10 个时钟一位
        .DEBOUNCE_MS ( 1         ),  // 1000 个时钟
        .POR_CYCLES  ( 20        )
    ) dut (
        .I_sys_clk ( clk  ),
        .I_sw1     ( sw1  ),
        .I_key1    ( key1 ),
        .O_seg     ( seg  ),
        .O_sel     ( sel  )
    );

    always #500 clk = ~clk;

    // 与 RTL 相同的段码
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

    task wait_digit;
        input [2:0] idx;
        begin
            while (sel !== ~(8'h01 << idx))
                @(posedge clk);
            #1;
        end
    endtask

    task check_static_pattern;
        begin
            for (i = 0; i < 8; i = i + 1) begin
                wait_digit(i[2:0]);
                // O_sel[0] 是最右位，显示 7；O_sel[7] 是最左位，显示 0
                if (seg !== seg_decode(4'd7 - i[3:0])) begin
                    $display("[ERR] static digit %0d: seg=%02h expected=%02h",
                             i, seg, seg_decode(4'd7 - i[3:0]));
                    errors = errors + 1;
                end
            end
        end
    endtask

    task check_all_digits;
        input [3:0] val;
        begin
            for (i = 0; i < 8; i = i + 1) begin
                wait_digit(i[2:0]);
                if (seg !== seg_decode(val)) begin
                    $display("[ERR] count digit %0d: seg=%02h expected=%02h",
                             i, seg, seg_decode(val));
                    errors = errors + 1;
                end
            end
        end
    endtask

    task press_key;
        begin
            key1 = 1'b0;
            repeat (1200) @(posedge clk);  // > 1ms 消抖
            key1 = 1'b1;
            repeat (1200) @(posedge clk);
        end
    endtask

    initial begin
        // 等上电复位 + 扫描进入稳态
        repeat (100) @(posedge clk);

        // ---- SW1=0：静态 01234567 ----
        check_static_pattern();

        // ---- 切到 SW1=1：应显示 00000000 ----
        sw1 = 1'b1;
        repeat (20) @(posedge clk);
        check_all_digits(4'd0);

        // ---- 每按一次 K1 只前进一步 ----
        press_key();
        check_all_digits(4'd1);

        press_key();
        check_all_digits(4'd2);

        // ---- 继续按到 9，再按一次回到 0 ----
        repeat (7) press_key();
        check_all_digits(4'd9);
        press_key();
        check_all_digits(4'd0);

        // ---- 快速抖动不应改变计数（消抖检查）----
        repeat (5) begin
            key1 = 1'b0;
            repeat (100) @(posedge clk);
            key1 = 1'b1;
            repeat (100) @(posedge clk);
        end
        repeat (1200) @(posedge clk);
        check_all_digits(4'd0);

        // ---- 切回 SW1=0 应恢复静态图形 ----
        sw1 = 1'b0;
        repeat (20) @(posedge clk);
        check_static_pattern();

        if (errors == 0)
            $display("[PASS] seg_led_test: static pattern / step count / debounce / SW1 reset all OK");
        else
            $display("[FAIL] seg_led_test: %0d errors", errors);

        $finish;
    end

    initial begin
        #100_000_000;  // 100ms 仿真超时
        $display("[FAIL] seg_led_test: timeout");
        $finish;
    end

endmodule
