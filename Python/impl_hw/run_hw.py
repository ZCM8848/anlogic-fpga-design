# -*- coding: utf-8 -*-
"""
run_hw.py -- 硬件可实现版入口（视频 / 摄像头 / 自测）
============================================================
用法：
  python run_hw.py --selftest                 # 内置合成视频自测（无需摄像头）
  python run_hw.py --video foo.mp4            # 离线视频
  python run_hw.py --video foo.mp4 --output out.mp4 --no-display
  python run_hw.py --camera 1                 # 摄像头
"""
import argparse
import time

import cv2
import numpy as np

import hw_osd as osd
from hw_config import HWConfig
from hw_pipeline import HWPipeline


def _synth_gen(n=180, w=1280, h=720, n_balls=3):
    """生成器：亮钢珠沿水平方向滚过（真值可数），外加一个"人手"大块干扰。"""
    balls = [{"x": -80 - i * 160, "y": 260 + i * 60, "r": 40} for i in range(n_balls)]
    grad = (np.linspace(0, 30, w)).astype(np.uint8)[None, :, None]
    base = np.full((h, w, 3), 40, np.uint8)
    base[:, :, 0] = 48
    for f in range(n):
        img = np.clip(base.astype(np.int16) + grad, 0, 255).astype(np.uint8)
        cv2.rectangle(img, (300 + (f % 40), 120), (520 + (f % 40), 360),
                      (60, 60, 70), -1)
        for b in balls:
            b["x"] += 6
            if b["x"] - b["r"] > w:
                b["x"] = -80
            cv2.circle(img, (int(b["x"]), int(b["y"])), b["r"], (220, 220, 220), -1)
        yield img


def create_self_video(path, **kw):
    if not path:
        return _synth_gen(**kw)
    gen = _synth_gen(**kw)
    first = next(gen)
    h, w = first.shape[:2]
    vw = cv2.VideoWriter(path, cv2.VideoWriter_fourcc(*"mp4v"), 60, (w, h))
    vw.write(first)
    for fr in gen:
        vw.write(fr)
    vw.release()
    return iter(())


def run(gen, cfg, show=True, output=None, max_frames=0):
    pipe = HWPipeline(cfg)
    n = 0
    t0 = time.time()
    for frame in gen:
        n += 1
        res = pipe.process(frame)
        vis = frame.copy()
        if cfg.roi:
            osd.draw_roi(vis, cfg.roi)
        for t in res["tracks"]:
            osd.draw_track(vis, t, 1, 1)          # scale=1 时 1280x720
        if pipe.line_full is not None:
            osd.draw_line(vis, pipe.line_full[0], pipe.line_full[1], cfg.direction)
        osd.draw_count(vis, res["count"])
        osd.draw_status(vis, len(res["tracks"]), len(pipe.tracker.tracks))
        if output:
            if not hasattr(run, "_vw"):
                run._vw = cv2.VideoWriter(output, cv2.VideoWriter_fourcc(*"mp4v"),
                                          60, (frame.shape[1], frame.shape[0]))
            run._vw.write(vis)
        if show:
            cv2.imshow("hw_ball", vis)
            if cv2.waitKey(1) & 0xFF in (27, ord("q")):
                break
        if max_frames and n >= max_frames:
            break
    if hasattr(run, "_vw"):
        run._vw.release()
        del run._vw
    dt = time.time() - t0
    if show:
        cv2.destroyAllWindows()
    print("[result] frames=%d  count=%d  total_ids=%d  %.1f fps"
          % (n, pipe.counter.count, pipe.tracker.next_id - 1, n / max(1e-6, dt)))


def main():
    ap = argparse.ArgumentParser(description="钢珠跟踪计数（硬件可实现版）")
    ap.add_argument("--video", type=str, default=None)
    ap.add_argument("--camera", type=int, default=None)
    ap.add_argument("--output", type=str, default=None)
    ap.add_argument("--no-display", action="store_true")
    ap.add_argument("--max-frames", type=int, default=0)
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--count-mode", choices=["line", "exit"], default=None)
    args = ap.parse_args()

    cfg = HWConfig()
    if args.count_mode:
        cfg.count_mode = args.count_mode
    show = not args.no_display

    if args.selftest:
        run(create_self_video(None, n=180), cfg, show, args.output, args.max_frames)
        return

    if args.video:
        cap = cv2.VideoCapture(args.video)
    else:
        idx = args.camera if args.camera is not None else 0
        cap = cv2.VideoCapture(idx)
    if not cap.isOpened():
        print("[error] cannot open source")
        return

    def _gen():
        while True:
            ok, fr = cap.read()
            if not ok or fr is None:
                break
            yield fr

    run(_gen(), cfg, show, args.output, args.max_frames)
    cap.release()


if __name__ == "__main__":
    main()
