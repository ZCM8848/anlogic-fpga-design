// buzzer_song.v — MiSans 测试曲播放器（电平控制）
// 复用 buzzer_music 工程的 note_table.vh 与 song_data.vh。
// I_play=1 播放并循环；I_play=0 暂停并复位到曲首。
// 静音时 O_buzzer=1（高电平，不响）。
`timescale 1ns / 1ps

module buzzer_song #(
    parameter integer CLK_HZ     = 50_000_000,
    parameter integer MS_DIV     = 50_000,
    parameter integer GAP_MS     = 20,
    parameter integer SONG_DEPTH = 2048,
    parameter integer IDXW       = 11
) (
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_play,
    output reg         O_buzzer
);

    `include "note_table.vh"

    localparam S_LOAD = 1'b0;
    localparam S_PLAY = 1'b1;

    reg [15:0] ms_cnt;
    wire ms_tick = (ms_cnt == MS_DIV[15:0] - 16'd1);
    always @(posedge I_clk) begin
        if (!I_rst_n || ms_tick) ms_cnt <= 16'd0;
        else                    ms_cnt <= ms_cnt + 16'd1;
    end

    reg [23:0] song_rom [0:SONG_DEPTH-1];
    initial begin
        `include "song_data.vh"
    end

    reg [IDXW-1:0] rd_addr;
    reg [23:0]     rd_data;
    reg             state;
    reg [IDXW-1:0]  idx;
    reg [7:0]       cur_note;
    reg [15:0]      cur_dur;
    reg [15:0]      dur_left;
    reg [15:0]      tone_left;

    always @(posedge I_clk) rd_data <= song_rom[rd_addr];

    wire [7:0]  rd_note = rd_data[23:16];
    wire [15:0] rd_dur  = rd_data[15:0];
    wire [IDXW-1:0] next_idx = idx + 1'b1;

    always @(posedge I_clk) begin
        if (!I_rst_n || !I_play) begin
            state    <= S_LOAD;
            idx      <= {IDXW{1'b0}};
            rd_addr  <= {IDXW{1'b0}};
            cur_note <= 8'd0;
            cur_dur  <= 16'd0;
            dur_left <= 16'd0;
            tone_left<= 16'd0;
        end else begin
            if (state == S_LOAD) begin
                if (rd_dur == 16'd0) begin
                    idx     <= {IDXW{1'b0}};
                    rd_addr <= {IDXW{1'b0}};
                end else begin
                    cur_note <= rd_note;
                    cur_dur  <= rd_dur;
                    dur_left <= rd_dur;
                    tone_left<= (rd_note != 8'd0 && rd_dur > GAP_MS[15:0])
                                ? (rd_dur - GAP_MS[15:0]) : rd_dur;
                    idx     <= next_idx;
                    rd_addr <= next_idx;
                    state   <= S_PLAY;
                end
            end else if (ms_tick) begin
                if (dur_left <= 16'd1) begin
                    state <= S_LOAD;
                end else begin
                    dur_left <= dur_left - 16'd1;
                    if (tone_left != 16'd0)
                        tone_left <= tone_left - 16'd1;
                end
            end
        end
    end

    wire [23:0] half = note2half(cur_note);
    reg  [23:0] half_cnt;
    wire silent = !I_play || (cur_note == 8'd0) || (tone_left == 16'd0);

    always @(posedge I_clk) begin
        if (!I_rst_n) begin
            half_cnt <= 24'd0;
            O_buzzer <= 1'b1;
        end else if (silent) begin
            half_cnt <= 24'd0;
            O_buzzer <= 1'b1;
        end else if (half_cnt >= half - 24'd1) begin
            half_cnt <= 24'd0;
            O_buzzer <= ~O_buzzer;
        end else begin
            half_cnt <= half_cnt + 24'd1;
        end
    end

endmodule
