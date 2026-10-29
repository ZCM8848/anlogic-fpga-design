from __future__ import annotations

import argparse
import sys
from pathlib import Path

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from ballvision.imageops import downscale4, green_channel  # noqa: E402
from ballvision.video import VideoReader  # noqa: E402

SAMPLE = ROOT.parent / "sample"
OUT = ROOT / "data" / "backgrounds"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--video", required=True)
    ap.add_argument("--samples", type=int, default=80)
    args = ap.parse_args()
    path = Path(args.video)
    if not path.is_absolute():
        path = SAMPLE / path
    reader = VideoReader(path)
    step = max(1, reader.frames // args.samples)
    stack = []
    for idx in range(0, reader.frames, step):
        frame = reader.read(idx)
        stack.append(downscale4(green_channel(frame)))
    med = np.median(np.stack(stack, axis=0), axis=0).astype(np.uint8)
    OUT.mkdir(parents=True, exist_ok=True)
    out = OUT / f"{path.stem}_bg.png"
    cv2.imwrite(str(out), med)
    print("saved", out, "samples", len(stack), "frames", reader.frames)


if __name__ == "__main__":
    main()
