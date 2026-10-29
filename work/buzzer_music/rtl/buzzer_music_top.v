/*******************************************************************************
 * buzzer_music_top — 用板载蜂鸣器播放 MIDI 主旋律
 *
 * 硬件：HX1P35A / PH1P35MDG324-3
 *   - 蜂鸣器 BUZZER 接 C12，低电平响（经三极管驱动）；板上 SW5 串在中间，
 *     SW5 拨下=接通、拨上=断开。播放前确认 SW5 拨下。
 *   - 系统时钟 I_sys_clk 接 C4，50MHz 有源晶振，不用 PLL。
 *
 * 数据来源：rtl/song_data.vh（由 tools/gen/gen_song.py 从
 *   "@R__piano - 1000年生きてる.mid" 的 track 0 提取最高声部主旋律生成）。
 *   每条 ROM 项 = {note[7:0], dur_ms[15:0]}，note=0 表示休止。
 *   rtl/note_table.vh 给出 note2half(note)：MIDI 音符到 50MHz 方波半周期
 *   时钟数的查表（freq = 440*2^((note-69)/12)，half = CLK_HZ/(2*freq)）。
 *
 * 工作方式：
 *   - 上电后自动开始播放，循环不断。
 *   - KEY1（D5）做 20ms 消抖的播放/暂停切换；按住只切换一次。
 *   - LED1（D10）点亮表示正在播放。
 *   - 每个音符末尾留 GAP_MS 静音做吐音（articulation），节奏总时长不变。
 *   - 蜂鸣器在休止/暂停/静音段输出高电平（不响、不耗流）。
 ******************************************************************************/
`timescale 1ns / 1ps

module buzzer_music_top #(
    parameter integer CLK_HZ      = 50_000_000, // 输入时钟
    parameter integer MS_DIV      = 50_000,     // 1ms 节拍分频 = CLK_HZ/1000
    parameter integer DEBOUNCE_MS = 20,         // KEY1 消抖时间
    parameter integer GAP_MS      = 20,         // 每音符末尾吐音静音
    parameter integer POR_CYCLES  = 65_535,     // 上电复位等待周期
    parameter integer SONG_DEPTH  = 2048,       // ROM 深度（2 的幂）
    parameter integer IDXW        = 11          // log2(SONG_DEPTH)
) (
    input  wire I_sys_clk,    // C4，50MHz
    input  wire I_key1,       // D5，按下=0（播放/暂停）
    output reg  O_buzzer,     // C12，低电平响
    output wire O_led_play    // D10，点亮=正在播放
);

    // ------------------------------------------------------------------ 参数
    localparam [31:0] POR_MAX      = POR_CYCLES;
    localparam [31:0] DEBOUNCE_MAX = (CLK_HZ / 1000) * DEBOUNCE_MS;

    // 音符 -> 半周期时钟数（含 note<=0 返回 0 表示休止）
`include "note_table.vh"

    // ------------------------------------------------------------------ 上电复位
    reg [31:0] por_cnt;
    reg        rst_n;

    initial begin
        por_cnt = 32'd0;
        rst_n   = 1'b0;
    end

    always @(posedge I_sys_clk) begin
        if (por_cnt < POR_MAX) begin
            por_cnt <= por_cnt + 32'd1;
            rst_n   <= 1'b0;
        end else begin
            rst_n   <= 1'b1;
        end
    end

    // ------------------------------------------------------------------ 输入同步
    reg [2:0] key_sync;
    always @(posedge I_sys_clk) begin
        if (!rst_n) key_sync <= 3'b111;
        else        key_sync <= {key_sync[1:0], I_key1};
    end
    wire key_raw = key_sync[2];

    // ------------------------------------------------------------------ KEY1 消抖
    reg [31:0] db_cnt;
    reg        key_stable;
    reg        key_stable_d;
    always @(posedge I_sys_clk) begin
        if (!rst_n) begin
            db_cnt       <= 32'd0;
            key_stable   <= 1'b1;
            key_stable_d <= 1'b1;
        end else begin
            key_stable_d <= key_stable;
            if (key_raw != key_stable) begin
                if (db_cnt >= DEBOUNCE_MAX - 1) begin
                    db_cnt     <= 32'd0;
                    key_stable <= key_raw;
                end else begin
                    db_cnt <= db_cnt + 32'd1;
                end
            end else begin
                db_cnt <= 32'd0;
            end
        end
    end
    wire key_press = key_stable_d & ~key_stable;  // 下降沿，单拍

    // ------------------------------------------------------------------ 播放/暂停
    reg playing;
    always @(posedge I_sys_clk) begin
        if (!rst_n) playing <= 1'b1;        // 上电自动播放
        else if (key_press) playing <= ~playing;
    end
    assign O_led_play = playing & rst_n;

    // ------------------------------------------------------------------ 1ms 节拍
    reg [15:0] ms_cnt;
    wire ms_tick = (ms_cnt == MS_DIV[15:0] - 16'd1);
    always @(posedge I_sys_clk) begin
        if (!rst_n || ms_tick) ms_cnt <= 16'd0;
        else                   ms_cnt <= ms_cnt + 16'd1;
    end

    // ------------------------------------------------------------------ 歌曲 ROM（同步读）
    // 初始值由 song_data.vh 写入：song_rom[i] = {note[7:0], dur_ms[15:0]}
    reg [23:0] song_rom [0:SONG_DEPTH-1];
    initial begin
`include "song_data.vh"
    end

    reg [IDXW-1:0] rd_addr;
    reg [23:0]     rd_data;
    always @(posedge I_sys_clk) rd_data <= song_rom[rd_addr];

    // ------------------------------------------------------------------ 序列机
    // S_LOAD：rd_data 已有效（上一拍预取），锁存新事件并预取下一地址；
    //         若读到 dur==0（padding/曲终），直接跳回地址 0 循环。
    // S_PLAY：按 1ms 节拍递减 dur_left；dur 到期回到 S_LOAD（rd_data 已是下一事件）。
    localparam S_LOAD = 1'b0;
    localparam S_PLAY = 1'b1;

    reg             state;
    reg [IDXW-1:0]  idx;          // 当前播放事件的下标
    reg [7:0]       cur_note;     // 当前音符（0=休止）
    reg [15:0]      cur_dur;      // 当前事件总时长（ms）
    reg [15:0]      dur_left;     // 当前事件剩余时长（ms）
    reg [15:0]      tone_left;    // 当前事件剩余发声时长（ms）= dur - GAP

    wire [7:0]  rd_note = rd_data[23:16];
    wire [15:0] rd_dur  = rd_data[15:0];
    wire [IDXW-1:0] next_idx = idx + 1'b1;   // 11 位自然回绕 2047->0

    always @(posedge I_sys_clk) begin
        if (!rst_n) begin
            state    <= S_LOAD;
            idx      <= {IDXW{1'b0}};
            rd_addr  <= {IDXW{1'b0}};
            cur_note <= 8'd0;
            cur_dur  <= 16'd0;
            dur_left <= 16'd0;
            tone_left<= 16'd0;
        end else if (playing) begin
            if (state == S_LOAD) begin
                // rd_data = song_rom[idx]，上一拍已预取
                if (rd_dur == 16'd0) begin
                    // padding/曲终：回到起点循环
                    idx     <= {IDXW{1'b0}};
                    rd_addr <= {IDXW{1'b0}};
                    // 仍在 S_LOAD，下一拍读 song_rom[0]
                end else begin
                    cur_note <= rd_note;
                    cur_dur  <= rd_dur;
                    dur_left <= rd_dur;
                    tone_left<= (rd_note != 8'd0 && rd_dur > GAP_MS[15:0])
                                ? (rd_dur - GAP_MS[15:0]) : rd_dur;
                    // 预取下一事件
                    idx     <= next_idx;
                    rd_addr <= next_idx;
                    state   <= S_PLAY;
                end
            end else begin
                // S_PLAY：按 1ms 节拍递减
                if (ms_tick) begin
                    if (dur_left <= 16'd1) begin
                        // 本事件结束：rd_data 已是下一事件（预取过），转 S_LOAD
                        state <= S_LOAD;
                    end else begin
                        dur_left  <= dur_left - 16'd1;
                        if (tone_left != 16'd0)
                            tone_left <= tone_left - 16'd1;
                    end
                end
            end
        end
        // !playing：暂停，全部保持
    end

    // ------------------------------------------------------------------ 方波发生
    // 半周期计数器：每 half 个时钟翻转一次 buz_phase；half=0（休止）或静音段不翻转。
    wire [23:0] half = note2half(cur_note);
    reg  [23:0] half_cnt;

    // 静音条件：暂停、休止（cur_note==0）、或吐音段（tone_left==0）
    wire silent = !playing || (cur_note == 8'd0) || (tone_left == 16'd0);

    always @(posedge I_sys_clk) begin
        if (!rst_n) begin
            half_cnt <= 24'd0;
            O_buzzer <= 1'b1;          // 静音=高电平（不响）
        end else if (silent) begin
            half_cnt <= 24'd0;
            O_buzzer <= 1'b1;          // 静音保持高
        end else if (half_cnt >= half - 24'd1) begin
            half_cnt <= 24'd0;
            O_buzzer <= ~O_buzzer;     // 翻转产生方波（低电平响）
        end else begin
            half_cnt <= half_cnt + 24'd1;
        end
    end

endmodule
