from __future__ import annotations

from dataclasses import asdict, dataclass


@dataclass
class Params:
    # "auto" picks bright for dark scenes and dark for bright scenes.
    mode: str = "bright"
    scale: int = 4                 # 1280x720 -> 320x180
    use_bg: bool = True            # moving-object detection on a static chute
    bg_shift: int = 4              # IIR time constant = 2^shift frames
    bg_update_thr: int = 10        # only update where the frame is close to bg
    bg_thr: int = 30               # foreground difference threshold
    bright_thr: int = 245         # highlight must be saturated
    bright_open: int = 1           # 3x3 opening applied bright_open times
    dark_win: int = 48            # black-hat window at reduced scale
    dark_thr: int = 40
    dark_close: int = 1
    min_area: int = 100           # at reduced scale
    max_area: int = 1500
    min_width: int = 18
    max_width: int = 100
    min_height: int = 5
    max_height: int = 50
    ball_diameter_px: int = 171   # full-resolution silhouette diameter (40 mm calibration)
    offset_x_px: int = 0          # highlight -> ball centre correction
    offset_y_px: int = 0
    gate_x_ratio: float = 0.30    # fixed by hardware: 30% from the left
    gate_y0_ratio: float = 0.08
    gate_y1_ratio: float = 0.92
    track_gate_px: int = 220      # full-resolution association radius
    track_max_miss: int = 5
    track_confirm_hits: int = 2
    min_move_ratio: float = 0.20  # a real ball must move >= this * D in total
    min_window_ratio: float = 0.50  # ... and >= this * D over the last 5 frames
    static_max_age: int = 30      # drop a track that has not moved for this many frames
    merge_distance_ratio: float = 0.80  # merge split pieces of one ball
    auto_split_threshold: int = 120     # frame mean below -> bright mode

    def to_dict(self) -> dict:
        return asdict(self)

    @classmethod
    def from_dict(cls, data: dict | None) -> "Params":
        data = dict(data or {})
        known = {f for f in cls.__dataclass_fields__}
        return cls(**{k: v for k, v in data.items() if k in known})

    def reduced_diameter(self) -> int:
        return max(1, int(round(self.ball_diameter_px / self.scale)))
