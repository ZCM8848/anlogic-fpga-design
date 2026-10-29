from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ANNOTATION_DIR = ROOT / "data" / "annotations"
CALIBRATION_DIR = ROOT / "data" / "calibration"


def _path(clip: str) -> Path:
    return ANNOTATION_DIR / f"{Path(clip).stem}.json"


def load(clip: str) -> dict:
    p = _path(clip)
    if not p.exists():
        return {"clip": Path(clip).stem, "frames": {}}
    return json.loads(p.read_text(encoding="utf-8"))


def save(clip: str, data: dict) -> Path:
    ANNOTATION_DIR.mkdir(parents=True, exist_ok=True)
    p = _path(clip)
    p.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    return p


def load_calibration() -> dict:
    p = CALIBRATION_DIR / "calibration.json"
    if not p.exists():
        return {}
    return json.loads(p.read_text(encoding="utf-8"))


def save_calibration(data: dict) -> Path:
    CALIBRATION_DIR.mkdir(parents=True, exist_ok=True)
    p = CALIBRATION_DIR / "calibration.json"
    p.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    return p
