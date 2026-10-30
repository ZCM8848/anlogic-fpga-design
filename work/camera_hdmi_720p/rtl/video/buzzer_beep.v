// buzzer_beep.v — 钢珠过门线短鸣驱动
// 时钟：I_sys_clk 50MHz
// 触发：I_trig_toggle 每翻转一次产生一次短鸣
// 参数：I_half_clks = 50MHz/(2*freq)，I_beep_ms = 鸣叫时长
// 硬件：C12 低电平响，静音时输出高电平
`timescale 1ns / 1ps

module buzzer_beep #(
    parameter integer CLK_HZ = 50_000_000
) (
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_en,            // 0=强制静音并复位鸣叫状态（模式切换用）
    input  wire        I_trig_toggle,   // 翻转触发，AHB 写 0/1
    input  wire [23:0] I_half_clks,     // 方波半周期时钟数
    input  wire [15:0] I_beep_ms,       // 鸣叫时长 ms
    output reg         O_buzzer
);

    localparam [15:0] MS_DIV = CLK_HZ / 1000;  // 50000

    // 触发位 2FF 同步 + 边沿检测
    reg [1:0] trig_sync;
    reg       trig_d;
    always @(posedge I_clk) begin
        if (!I_rst_n) begin
            trig_sync <= 2'b0;
            trig_d    <= 1'b0;
        end else begin
            trig_sync <= {trig_sync[0], I_trig_toggle};
            trig_d    <= trig_sync[1];
        end
    end
    wire trig_event = trig_sync[1] ^ trig_d;

    // 配置 2FF 同步（写入后稳定）
    reg [23:0] half_s1, half_s2;
    reg [15:0] beep_ms_s1, beep_ms_s2;
    always @(posedge I_clk) begin
        half_s1   <= I_half_clks;
        half_s2   <= half_s1;
        beep_ms_s1 <= I_beep_ms;
        beep_ms_s2 <= beep_ms_s1;
    end

    // 1ms 节拍
    reg [15:0] ms_cnt;
    wire ms_tick = (ms_cnt == MS_DIV - 16'd1);
    always @(posedge I_clk) begin
        if (!I_rst_n || ms_tick) ms_cnt <= 16'd0;
        else                    ms_cnt <= ms_cnt + 16'd1;
    end

    // 鸣叫状态
    reg        beeping;
    reg [15:0] ms_left;
    always @(posedge I_clk) begin
        if (!I_rst_n || !I_en) begin
            beeping <= 1'b0;
            ms_left <= 16'd0;
        end else if (trig_event) begin
            beeping <= 1'b1;
            ms_left <= beep_ms_s2;
        end else if (ms_tick && beeping) begin
            if (ms_left <= 16'd1) begin
                beeping <= 1'b0;
                ms_left <= 16'd0;
            end else begin
                ms_left <= ms_left - 16'd1;
            end
        end
    end

    // 方波发生
    reg [23:0] half_cnt;
    always @(posedge I_clk) begin
        if (!I_rst_n) begin
            O_buzzer  <= 1'b1;       // 静音
            half_cnt  <= 24'd0;
        end else if (!I_en || !beeping || (half_s2 == 24'd0)) begin
            O_buzzer <= 1'b1;
            half_cnt <= half_s2;
        end else begin
            if (half_cnt <= 24'd1) begin
                O_buzzer  <= ~O_buzzer;
                half_cnt  <= half_s2;
            end else begin
                half_cnt <= half_cnt - 24'd1;
            end
        end
    end

endmodule
