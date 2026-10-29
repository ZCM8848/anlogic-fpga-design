from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from ballvision.detect import Detector  # noqa: E402
from ballvision.config import load_params  # noqa: E402
from ballvision.background import load_clip_background  # noqa: E402
from ballvision.video import VideoReader  # noqa: E402

SAMPLE = ROOT.parent / "sample"
OUT = ROOT / "data" / "analysis"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--video", required=True)
    ap.add_argument("--mode", default=None)
    ap.add_argument("--diameter", type=int, default=None)
    ap.add_argument("--bright-thr", type=int, default=None)
    ap.add_argument("--dark-thr", type=int, default=None)
    ap.add_argument("--top", type=int, default=30)
    args = ap.parse_args()

    path = Path(args.video)
    if not path.is_absolute():
        path = SAMPLE / path
    reader = VideoReader(path)
    params = load_params()
    if args.mode is not None:
        params.mode = args.mode
    if args.diameter is not None:
        params.ball_diameter_px = args.diameter
    if args.bright_thr is not None:
        params.bright_thr = args.bright_thr
    if args.dark_thr is not None:
        params.dark_thr = args.dark_thr
    detector = Detector(params, load_clip_background(path.stem))
    t0 = time.perf_counter()
    rows = []
    for idx in range(reader.frames):
        r = detector.detect(reader.read(idx))
        masksum = int(r.mask.sum())
        rows.append({
            "i": idx,
            "mode": r.mode,
            "mean": r.frame_mean,
            "det": len(r.detections),
            "masksum": masksum,
            "areas": [d.area_small for d in r.detections],
        })
    dt = time.perf_counter() - t0

    cand = [r for r in rows if r["det"] >= 2]
    cand.sort(key=lambda r: (r["det"], r["masksum"]), reverse=True)
    out = {
        "clip": path.name,
        "params": params.to_dict(),
        "seconds": round(dt, 2),
        "fps": round(reader.frames / dt, 2) if dt else 0,
        "top": cand[: args.top],
        "all": rows,
    }
    OUT.mkdir(parents=True, exist_ok=True)
    p = OUT / f"{path.stem}_scan.json"
    p.write_text(json.dumps(out, ensure_ascii=False), encoding="utf-8")
    print("saved", p, "frames", reader.frames, "seconds", round(dt, 2))
    print("top candidates:")
    for r in cand[: args.top]:
        print("  f%-4d det=%d masksum=%d mean=%d mode=%s"
              % (r["i"], r["det"], r["masksum"], r["mean"], r["mode"]))


if __name__ == "__main__":
    main()
