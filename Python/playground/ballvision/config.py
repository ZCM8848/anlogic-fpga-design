from __future__ import annotations

import json
from pathlib import Path

from .annotations import load_calibration
from .params import Params

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "configs" / "default.json"


def load_params() -> Params:
    """Config file + calibration (calibration wins for ball diameter)."""
    if CONFIG.exists():
        params = Params.from_dict(json.loads(CONFIG.read_text(encoding="utf-8")))
    else:
        params = Params()
    calib = load_calibration()
    try:
        if calib.get("ball_diameter_px"):
            params.ball_diameter_px = int(round(float(calib["ball_diameter_px"])))
    except (TypeError, ValueError):
        pass
    return params
