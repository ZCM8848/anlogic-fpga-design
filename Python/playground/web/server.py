from __future__ import annotations

import hashlib
import json
import sys
import threading
from collections import OrderedDict
from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse, Response
from fastapi.staticfiles import StaticFiles

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from ballvision import annotations  # noqa: E402
from ballvision.background import load_clip_background  # noqa: E402
from ballvision.config import load_params as load_config_params  # noqa: E402
from ballvision.osd import draw_osd, mask_full, processed_overlay, score_full  # noqa: E402
from ballvision.params import Params  # noqa: E402
from ballvision.pipeline import FrameResult, Pipeline  # noqa: E402
from ballvision.video import VideoReader  # noqa: E402

SAMPLE_DIR = ROOT.parent / "sample"
STATIC_DIR = Path(__file__).resolve().parent / "static"
CONFIG_DIR = ROOT / "configs"
DEFAULT_CONFIG = CONFIG_DIR / "default.json"
ANALYSIS_DIR = ROOT / "data" / "analysis"

app = FastAPI(title="Ball Vision Playground")


def _params_hash(p: Params) -> str:
    raw = json.dumps(p.to_dict(), sort_keys=True).encode()
    return hashlib.md5(raw).hexdigest()[:10]


def _encode(img: np.ndarray, quality: int = 85) -> bytes:
    ok, buf = cv2.imencode(".jpg", img, [int(cv2.IMWRITE_JPEG_QUALITY), quality])
    if not ok:
        raise RuntimeError("jpeg encode failed")
    return buf.tobytes()


@dataclass
class CachedFrame:
    meta: dict
    images: dict[str, bytes]


class Service:
    def __init__(self) -> None:
        self.params = load_config_params()
        self.readers: dict[str, VideoReader] = {}
        self.pipelines: dict[str, Pipeline] = {}
        self.cache: OrderedDict[tuple[str, int, str], CachedFrame] = OrderedDict()
        self.cache_max = 12
        self.lock = threading.RLock()

    # -- clips ---------------------------------------------------------
    def clip_path(self, name: str) -> Path:
        name = Path(name).name
        p = SAMPLE_DIR / name
        if not p.exists() and p.suffix == "":
            p = SAMPLE_DIR / (name + ".mp4")
        if not p.exists():
            raise HTTPException(404, f"clip not found: {name}")
        return p

    def clip_list(self) -> list[dict]:
        out = []
        for p in sorted(SAMPLE_DIR.glob("*.mp4")):
            try:
                r = VideoReader(p)
                info = r.info()
                r.release()
            except Exception:
                info = {"name": p.name, "frames": 0, "fps": 0.0}
            info["stem"] = p.stem
            out.append(info)
        return out

    def reader(self, name: str) -> VideoReader:
        p = self.clip_path(name)
        stem = p.stem
        if stem not in self.readers:
            self.readers[stem] = VideoReader(p)
        return self.readers[stem]

    def pipeline(self, name: str) -> Pipeline:
        stem = self.clip_path(name).stem
        if stem not in self.pipelines:
            r = self.reader(name)
            self.pipelines[stem] = Pipeline(
                self.params, r.width, r.height,
                bg=load_clip_background(stem),
            )
        return self.pipelines[stem]

    def reset(self) -> None:
        with self.lock:
            self.pipelines.clear()
            self.cache.clear()

    # -- processing ----------------------------------------------------
    def frame(self, name: str, index: int) -> CachedFrame:
        with self.lock:
            return self._frame_locked(name, index)

    def _frame_locked(self, name: str, index: int) -> CachedFrame:
        stem = self.clip_path(name).stem
        key = (stem, int(index), _params_hash(self.params))
        if key in self.cache:
            self.cache.move_to_end(key)
            return self.cache[key]

        reader = self.reader(name)
        idx = max(0, min(reader.frames - 1, int(index)))
        pipe = self.pipeline(name)
        # Motion-gated OSD needs a few frames of history.  When the user seeks,
        # warm the tracker up on the previous ~0.2 s so real balls become
        # visible immediately and static scratches are already rejected.
        if pipe.last_idx is None or idx != pipe.last_idx + 1:
            start = max(0, idx - 12)
            for j in range(start, idx):
                pipe.process(reader.read(j), j)
            pipe.counter.reset()
        frame = reader.read(idx)
        result = pipe.process(frame, idx)

        images = {
            "orig": _encode(frame),
            "proc": _encode(processed_overlay(frame, result)),
            "score": _encode(score_full(result, (reader.width, reader.height))),
            "mask": _encode(mask_full(result, (reader.width, reader.height))),
            "osd": _encode(draw_osd(frame, result, self.params)),
        }
        meta = self._meta(stem, idx, reader, result)
        item = CachedFrame(meta, images)
        self.cache[key] = item
        while len(self.cache) > self.cache_max:
            self.cache.popitem(last=False)
        return item

    def _meta(self, stem: str, idx: int, reader: VideoReader, r: FrameResult) -> dict:
        return {
            "clip": stem,
            "index": idx,
            "total": reader.frames,
            "fps": reader.fps,
            "width": reader.width,
            "height": reader.height,
            "mode": r.mode,
            "frame_mean": r.frame_mean,
            "mask_pixels": int(r.mask.sum()),
            "score_mean": round(float(r.score.mean()), 2),
            "score_max": int(r.score.max()),
            "reset": r.reset,
            "count": r.count,
            "events": [
                {"frame": e.frame, "track_id": e.track_id, "cx": e.cx, "cy": e.cy,
                 "count_after": e.count_after}
                for e in r.events[-20:]
            ],
            "detections": [
                {"cx": d.cx, "cy": d.cy, "box": list(d.box), "area": d.area_small}
                for d in r.det.detections
            ],
            "tracks": [
                {"id": t.id, "cx": t.cx, "cy": t.cy, "box": list(t.box),
                 "hits": t.hits, "misses": t.misses, "confirmed": t.confirmed,
                 "visible": t.visible, "moved": t.moved, "age": t.age,
                 "counted": t.counted}
                for t in r.tracks
            ],
            "params": self.params.to_dict(),
        }

    def image(self, name: str, index: int, view: str) -> bytes:
        stem = self.clip_path(name).stem
        key = (stem, int(index), _params_hash(self.params))
        if key not in self.cache:
            self.frame(name, index)
        item = self.cache.get(key)
        if item is None or view not in item.images:
            raise HTTPException(404, "image not found")
        return item.images[view]


svc = Service()


@app.get("/api/clips")
def api_clips():
    return {"clips": svc.clip_list(), "params": svc.params.to_dict()}


@app.get("/api/params")
def api_get_params():
    return svc.params.to_dict()


@app.post("/api/params")
def api_set_params(body: dict):
    merged = svc.params.to_dict()
    merged.update({k: v for k, v in body.items() if k in Params.__dataclass_fields__})
    svc.params = Params.from_dict(merged)
    try:
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        DEFAULT_CONFIG.write_text(
            json.dumps(svc.params.to_dict(), ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
    except OSError:
        pass
    svc.reset()
    return svc.params.to_dict()


@app.get("/api/frame")
def api_frame(clip: str, index: int):
    item = svc.frame(clip, index)
    v = _params_hash(svc.params)
    meta = dict(item.meta)
    meta["images"] = {
        view: f"/api/image?clip={Path(clip).stem}&index={index}&view={view}&v={v}"
        for view in ("orig", "proc", "score", "mask", "osd")
    }
    return meta


@app.get("/api/image")
def api_image(clip: str, index: int, view: str):
    data = svc.image(clip, index, view)
    return Response(content=data, media_type="image/jpeg",
                    headers={"Cache-Control": "no-store"})


@app.get("/api/annotations")
def api_get_annotations(clip: str):
    return annotations.load(clip)


@app.post("/api/annotations")
def api_save_annotations(body: dict):
    clip = body.get("clip")
    if not clip:
        raise HTTPException(400, "clip required")
    annotations.save(clip, body)
    return {"ok": True}


@app.get("/api/calibration")
def api_get_calibration():
    return annotations.load_calibration()


@app.post("/api/calibration")
def api_save_calibration(body: dict):
    annotations.save_calibration(body)
    return {"ok": True}


@app.get("/api/scan")
def api_scan(clip: str):
    stem = Path(clip).stem
    p = ANALYSIS_DIR / f"{stem}_scan.json"
    if not p.exists():
        return {"clip": stem, "missing": True, "top": [], "frames": 0}
    data = json.loads(p.read_text(encoding="utf-8"))
    return {
        "clip": stem,
        "missing": False,
        "frames": len(data.get("all", [])),
        "top": data.get("top", [])[:200],
    }


@app.get("/")
def index():
    return FileResponse(STATIC_DIR / "index.html")


app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")
