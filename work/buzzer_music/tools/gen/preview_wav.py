# preview_wav.py — 把 FPGA 蜂鸣器要播放的旋律渲染成 WAV 预览
# 与上板行为一致：
#   - 事件序列与 song_data.vh 完全一致（复用 gen_song 的提取管线）；
#   - 每个音符的频率用 note2half 的 FPGA 实际值 half = round(CLK_HZ/(2*freq))，
#     再反算 fpga_freq = CLK_HZ/(2*half)（含量化误差，和上板听到的音高一致）；
#   - 每个音符末尾留 GAP_MS 静音做吐音，节奏总时长不变；休止为静音；
#   - 方波（蜂鸣器经三极管开关，本质是 50% 方波激励）。
import os, sys, argparse, wave
import numpy as np

# 复用 gen_song：保证事件序列与 song_data.vh 完全相同
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_song

SR       = 44100
CLK_HZ   = 50_000_000
GAP_MS   = 20
AMP      = 0.40   # 方波幅度（满刻度 1.0），避免预览过响

def build_events(midi_path):
    mid = gen_song.mido.MidiFile(midi_path)
    seg, _, _ = gen_song.extract_melody(mid)
    seg = gen_song.merge_rests(seg)
    seg = gen_song.split_long(seg)
    seg = gen_song.quantize(seg)
    seg.append((0, 800))            # 与 gen_song.main() 一致的曲尾休止
    seg = gen_song.merge_rests(seg)
    return seg

def render(events, loops=1):
    chunks = []
    total_ms = sum(d for _, d in events)
    print(f"render: {len(events)} events, {total_ms} ms = {total_ms/1000:.1f} s, loops={loops}")
    for lp in range(loops):
        for (note, dur_ms) in events:
            n_samp = int(round(dur_ms * SR / 1000))
            if note == 0 or n_samp <= 0:
                chunks.append(np.zeros(n_samp, dtype=np.float32))
                continue
            half = gen_song.half_period_of(note)        # 与 note_table.vh 完全一致
            if half <= 0:
                chunks.append(np.zeros(n_samp, dtype=np.float32)); continue
            f_fpga = CLK_HZ / (2.0 * half)              # FPGA 实际播放频率
            # 吐音：发声 (dur-GAP)，静音 GAP
            tone_ms = dur_ms - GAP_MS if dur_ms > GAP_MS else dur_ms
            tone_n  = int(round(tone_ms * SR / 1000))
            gap_n   = max(0, n_samp - tone_n)
            t = np.arange(tone_n, dtype=np.float32) / SR
            phase = (t * f_fpga) % 1.0
            sq = np.where(phase < 0.5, AMP, -AMP).astype(np.float32)
            chunks.append(sq)
            if gap_n > 0:
                chunks.append(np.zeros(gap_n, dtype=np.float32))
        if lp == 0:
            print(f"  loop {lp+1} done")
    return np.concatenate(chunks)

def write_wav(path, samples):
    data = np.clip(samples, -1.0, 1.0)
    pcm = (data * 32767.0).astype('<i2')
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--midi", default=r"C:\Users\Z___C\Downloads\@R__piano - 1000年生きてる.mid")
    ap.add_argument("--out", default=None)
    ap.add_argument("--loops", type=int, default=1)
    args = ap.parse_args()

    if not os.path.isfile(args.midi):
        print(f"[ERR] MIDI 文件不存在: {args.midi}", file=sys.stderr); sys.exit(1)

    if args.out is None:
        # 默认放工程下 preview/（*.wav 已被 .gitignore 排除）
        proj = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
        outdir = os.path.join(proj, "preview")
        os.makedirs(outdir, exist_ok=True)
        args.out = os.path.join(outdir, "buzzer_music_preview.wav")

    events = build_events(args.midi)
    samples = render(events, loops=args.loops)
    write_wav(args.out, samples)
    dur_s = len(samples) / SR
    print(f"wrote {args.out}")
    print(f"  {len(samples)} samples, {dur_s:.1f} s, {os.path.getsize(args.out)//1024} KB")

if __name__ == "__main__":
    main()
