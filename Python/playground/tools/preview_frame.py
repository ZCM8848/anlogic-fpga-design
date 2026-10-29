from __future__ import annotations

import argparse
import sys
from pathlib import Path

import cv2

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from ballvision.osd import draw_osd, processed_overlay  # noqa: E402
from ballvision.params import Params  # noqa: E402
from ballvision.config import load_params  # noqa: E402
from ballvision.pipeline import Pipeline  # noqa: E402
from ballvision.background import load_clip_background  # noqa: E402
from ballvision.video import VideoReader  # noqa: E402

SAMPLE = ROOT.parent / "sample"
OUT = ROOT / "data" / "debug"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--video", required=True)
    ap.add_argument("--time", type=float, default=4.0)
    ap.add_argument("--from-time", type=float, default=None)
    ap.add_argument("--mode", default=None)
    ap.add_argument("--diameter", type=int, default=None)
    ap.add_argument("--bright-thr", type=int, default=None)
    ap.add_argument("--dark-thr", type=int, default=None)
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

    target = int(round(args.time * reader.fps))
    start = target if args.from_time is None else int(round(args.from_time * reader.fps))
    result = None
    for idx in range(start, target + 1):
        frame = reader.read(idx)
        result = pipe.process(frame, idx)

    assert result is not None
    OUT.mkdir(parents=True, exist_ok=True)
    tag = f"{path.stem}_f{target:04d}"
    cv2.imwrite(str(OUT / f"{tag}_orig.png"), frame)
    cv2.imwrite(str(OUT / f"{tag}_proc.png"), processed_overlay(frame, result))
    cv2.imwrite(str(OUT / f"{tag}_osd.png"), draw_osd(frame, result, params))
    print("frame", target, "mode", result.mode, "mean", result.frame_mean,
          "det", len(result.det.detections), "tracks", len(result.tracks),
          "count", result.count, "reset", result.reset)
    for d in result.det.detections:
        print("  det", d.cx, d.cy, d.box, d.area_small)
    print("out", OUT)


if __name__ == "__main__":
    main()
