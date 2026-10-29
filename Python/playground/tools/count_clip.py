from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from ballvision.params import Params  # noqa: E402
from ballvision.config import load_params  # noqa: E402
from ballvision.pipeline import Pipeline  # noqa: E402
from ballvision.background import load_clip_background  # noqa: E402
from ballvision.video import VideoReader  # noqa: E402

SAMPLE = ROOT.parent / "sample"
OUT = ROOT / "data" / "analysis"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--video", required=True)
    ap.add_argument("--start", type=float, default=0.0)
    ap.add_argument("--end", type=float, default=None)
    ap.add_argument("--mode", default=None)
    ap.add_argument("--diameter", type=int, default=None)
    ap.add_argument("--bright-thr", type=int, default=None)
    ap.add_argument("--dark-thr", type=int, default=None)
    ap.add_argument("--no-save", action="store_true")
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
    pipe = Pipeline(params, reader.width, reader.height,
                    bg=load_clip_background(path.stem))
    f0 = int(round(args.start * reader.fps))
    f1 = reader.frames - 1 if args.end is None else int(round(args.end * reader.fps))
    f1 = min(f1, reader.frames - 1)

    t0 = time.perf_counter()
    per_frame = []
    last_count = 0
    for idx in range(f0, f1 + 1):
        result = pipe.process(reader.read(idx), idx)
        per_frame.append({
            "i": idx,
            "mode": result.mode,
            "mean": result.frame_mean,
            "det": len(result.det.detections),
            "tracks": len(result.tracks),
            "count": result.count,
        })
        if result.count != last_count:
            last_count = result.count
    dt = time.perf_counter() - t0

    events = [
        {"frame": e.frame, "track_id": e.track_id, "cx": e.cx, "cy": e.cy,
         "count_after": e.count_after}
        for e in pipe.counter.events
    ]
    summary = {
        "clip": path.name,
        "params": params.to_dict(),
        "frames": [f0, f1],
        "count": pipe.counter.count,
        "events": events,
        "seconds": round(dt, 3),
        "fps": round((f1 - f0 + 1) / dt, 2) if dt else 0,
    }
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    if not args.no_save:
        OUT.mkdir(parents=True, exist_ok=True)
        p = OUT / f"{path.stem}_count.json"
        p.write_text(json.dumps({"summary": summary, "per_frame": per_frame},
                                ensure_ascii=False), encoding="utf-8")
        print("saved", p)


if __name__ == "__main__":
    main()
