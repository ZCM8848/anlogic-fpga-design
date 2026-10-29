# gen_song.py — 从 MIDI 提取主旋律（track 0 最高声部），生成 song_data.vh 与 note_table.vh
# 依赖：mido（第三方 MIDI 解析库）
# 输入：MIDI 文件（默认指向用户 Downloads 下的目标文件）
# 输出：rtl/song_data.vh（song_rom 初始化）、rtl/note_table.vh（note2half 函数）
#
# 设计说明：
#   - 蜂鸣器单声道，只能发一个音高。取 track 0（右手旋律）在每个时刻正在发声的最高音
#     （top-voice）作为旋律线；无音发声时为休止。
#   - 时间量化到 1ms；tempo 由 MIDI 的 set_tempo 事件按段换算（本曲全程 100BPM）。
#   - 每个事件 = {note[7:0], dur_ms[15:0]}，note=0 表示休止。
#   - 音符的「吐音间隙」(articulation gap) 由硬件在播放时统一扣除，本脚本只产出
#     音符的完整持续时长，保持节奏总时长不变。
import mido
import argparse
import os
import sys

CLK_HZ = 50_000_000
NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

def note_name(n):
    return f"{NAMES[n % 12]}{n // 12 - 1}"

def freq_of(midi_note):
    return 440.0 * (2.0 ** ((midi_note - 69) / 12.0))

def half_period_of(midi_note):
    # 50MHz 方波：每半周期需要的时钟数 = CLK_HZ / (2*freq)；休止(note<=0)记 0
    if midi_note <= 0:
        return 0
    return round(CLK_HZ / (2.0 * freq_of(midi_note)))

def tick_to_ms_map(tempo_map, tpb):
    # tempo_map: [(abs_tick, tempo_mpqn), ...] 已按 tick 升序
    # 返回函数 tick->ms（按 tempo 分段累加）
    def conv(tick):
        ms = 0.0
        prev_tick = 0
        cur_tempo = tempo_map[0][1] if tempo_map else 500000
        for (t, tempo) in tempo_map:
            if t > tick:
                break
            seg = t - prev_tick
            ms += seg * cur_tempo / (tpb * 1000.0)
            prev_tick = t
            cur_tempo = tempo
        ms += (tick - prev_tick) * cur_tempo / (tpb * 1000.0)
        return ms
    return conv

def extract_melody(mid):
    # 取第 0 个 track（右手旋律），按绝对 tick 收集 note on/off 与 tempo
    tr = mid.tracks[0]
    tempo_map = []
    abs_tick = 0
    note_starts = {}   # pitch -> start_tick
    events = []        # (tick, kind, pitch)  kind: 1=on, -1=off
    for msg in tr:
        abs_tick += msg.time
        if msg.type == "set_tempo":
            tempo_map.append((abs_tick, msg.tempo))
        elif msg.type == "note_on" and msg.velocity > 0:
            events.append((abs_tick, 1, msg.note))
        elif msg.type == "note_off" or (msg.type == "note_on" and msg.velocity == 0):
            events.append((abs_tick, -1, msg.note))
    if not tempo_map:
        tempo_map = [(0, 500000)]
    # 合并同 tick 的 tempo（取最后一个生效）
    seen = {}
    for t, tp in tempo_map:
        seen[t] = tp
    tempo_map = sorted(seen.items())
    conv = tick_to_ms_map(tempo_map, mid.ticks_per_beat)

    # 排序：同 tick 时 off(-1) 排在 on(1) 前，避免瞬间重叠造成旋律跳到将结束的音
    events.sort(key=lambda e: (e[0], e[1]))

    # 扫描时间线，维护当前发声集合，top = max(pitch)
    segments = []   # (pitch_or_0, ms_dur)
    active = {}     # pitch -> count
    cur_top = 0     # 0 = 休止
    seg_start_ms = 0.0
    prev_ms = 0.0
    for (tick, kind, pitch) in events:
        ms = conv(tick)
        if kind == 1:
            active[pitch] = active.get(pitch, 0) + 1
        else:
            if pitch in active:
                active[pitch] -= 1
                if active[pitch] <= 0:
                    del active[pitch]
        new_top = max(active) if active else 0
        if new_top != cur_top:
            dur = ms - seg_start_ms
            if dur > 0:
                segments.append((cur_top, dur))
            cur_top = new_top
            seg_start_ms = ms
        prev_ms = ms
    # 收尾
    total_ms = conv(mid.length) if hasattr(mid, "length") else prev_ms
    # mido.MidiFile.length 单位是秒；这里用 conv(最后一个tick) 更准
    last_tick = events[-1][0] if events else 0
    final_ms = conv(last_tick)
    dur = final_ms - seg_start_ms
    if dur > 0:
        segments.append((cur_top, dur))
    return segments, conv(last_tick), tempo_map

def merge_rests(segments):
    out = []
    for (pitch, dur) in segments:
        if pitch == 0 and out and out[-1][0] == 0:
            out[-1] = (0, out[-1][1] + dur)
        else:
            out.append((pitch, dur))
    return out

def split_long(segments, max_ms=65535):
    out = []
    for (pitch, dur) in segments:
        while dur > max_ms:
            out.append((pitch, max_ms))
            dur -= max_ms
        if dur > 0:
            out.append((pitch, dur))
    return out

def quantize(segments):
    # 量化到 1ms；至少 1ms
    return [(p, max(1, round(d))) for (p, d) in segments]

def next_pow2(n):
    p = 1
    while p < n:
        p *= 2
    return p

def write_song_vh(path, segments, depth):
    with open(path, "w", encoding="utf-8") as f:
        f.write("// song_data.vh — 自动生成，请勿手工编辑\n")
        f.write(f"// 来源 MIDI: @R__piano - 1000年生きてる.mid (track 0, top-voice 主旋律)\n")
        f.write(f"// 共 {len(segments)} 个事件，ROM 深度 {depth}（向上取整到 2 的幂）\n")
        f.write(f"// 每条 = song_rom[i] = {{note[7:0], dur_ms[15:0]}}；note=0 表示休止\n")
        f.write(f"// dur_ms 单位 1ms；节奏总长由各事件 dur_ms 之和决定\n\n")
        for i, (pitch, dur) in enumerate(segments):
            word = ((pitch & 0xFF) << 16) | (dur & 0xFFFF)
            f.write(f"song_rom[{i}] = 24'h{word:06X};")
            if pitch == 0:
                f.write(f"  // rest {dur}ms\n")
            else:
                f.write(f"  // {note_name(pitch)}({pitch}) {dur}ms\n")
        # 填充剩余为休止，便于循环回到起点（硬件循环时遇到 dur=0 直接跳过）
        for i in range(len(segments), depth):
            f.write(f"song_rom[{i}] = 24'h000000;  // padding\n")

def write_note_table_vh(path, lo=0, hi=127):
    with open(path, "w", encoding="utf-8") as f:
        f.write("// note_table.vh — 自动生成，请勿手工编辑\n")
        f.write(f"// note2half(note)：MIDI 音符 -> 50MHz 方波半周期时钟数 = CLK_HZ/(2*freq)\n")
        f.write(f"// freq = 440 * 2^((note-69)/12)；note<=0 返回 0（休止，硬件输出静音）\n\n")
        f.write("function [23:0] note2half;\n")
        f.write("    input [7:0] note;\n")
        f.write("    begin\n")
        f.write("        case (note)\n")
        for n in range(lo, hi + 1):
            hp = half_period_of(n)
            f.write(f"            8'd{n}: note2half = 24'd{hp};")
            if n % 4 == 0:
                f.write(f"  // {note_name(n)}")
            f.write("\n")
        f.write("            default: note2half = 24'd0;\n")
        f.write("        endcase\n")
        f.write("    end\n")
        f.write("endfunction\n")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--midi", default=r"C:\Users\Z___C\Downloads\@R__piano - 1000年生きてる.mid")
    ap.add_argument("--outdir", default=None, help="rtl 输出目录，默认为本脚本上级 rtl/")
    args = ap.parse_args()

    if not os.path.isfile(args.midi):
        print(f"[ERR] MIDI 文件不存在: {args.midi}", file=sys.stderr)
        sys.exit(1)

    if args.outdir is None:
        args.outdir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "rtl")
    outdir = os.path.abspath(args.outdir)
    os.makedirs(outdir, exist_ok=True)

    mid = mido.MidiFile(args.midi)
    print(f"MIDI: type={mid.type} tpb={mid.ticks_per_beat} tracks={len(mid.tracks)}")
    segments, total_ms, tempo_map = extract_melody(mid)
    print(f"raw segments: {len(segments)}, total_ms={total_ms:.1f} ({total_ms/1000:.2f}s)")
    print(f"tempo_map: {tempo_map}")
    segments = merge_rests(segments)
    segments = split_long(segments)
    segments = quantize(segments)
    # 旋律结束后的短休止，让循环重启时有一个自然的呼吸，避免末音与首音相接过紧
    segments.append((0, 800))
    segments = merge_rests(segments)
    total_play_ms = sum(d for (p, d) in segments)
    n_notes = sum(1 for (p, d) in segments if p != 0)
    n_rests = sum(1 for (p, d) in segments if p == 0)
    pitches = [p for (p, d) in segments if p != 0]
    print(f"final events: {len(segments)} (notes={n_notes} rests={n_rests})")
    print(f"play duration: {total_play_ms} ms = {total_play_ms/1000:.2f} s")
    if pitches:
        print(f"pitch range: {min(pitches)}..{max(pitches)} "
              f"({note_name(min(pitches))} ~ {note_name(max(pitches))})")
    depth = next_pow2(max(1, len(segments)))
    print(f"ROM depth (next pow2): {depth}")

    write_song_vh(os.path.join(outdir, "song_data.vh"), segments, depth)
    write_note_table_vh(os.path.join(outdir, "note_table.vh"))
    print(f"wrote: {os.path.join(outdir, 'song_data.vh')}")
    print(f"wrote: {os.path.join(outdir, 'note_table.vh')}")

if __name__ == "__main__":
    main()
