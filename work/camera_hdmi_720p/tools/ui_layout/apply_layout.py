#!/usr/bin/env python3
"""apply_layout.py — 把 UI 排布器导出的 ui_layout.json 写回现有 RTL。

应用范围：

    Logo      -> hdmi_mixer.v : LOGO_X / LOGO_Y            (ROM 固定 160x160，W/H 仅预览)
    Count     -> cv_top.v      : CNT_X / CNT_Y / CNT_W / CNT_H / CNT_SCALE_SHIFT
                                 (5x7 字模，按 W/H 换算 1/2/4/8 倍整数缩放)
    OSD 文本  -> hdmi_mixer.v : DYN_OSD_X / DYN_OSD_Y       (W/H 仅预览)

门线、ROI、球框、标签、帧计数等属于“预览元素”，不会写回 RTL。

用法：
    python tools/ui_layout/apply_layout.py ui_layout.json --dry-run
    python tools/ui_layout/apply_layout.py ui_layout.json

不带参数时默认读取当前目录的 ui_layout.json。
"""

import argparse
import difflib
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]          # work/camera_hdmi_720p
HDMI_MIXER = PROJECT / "rtl" / "video" / "hdmi_mixer.v"
CV_TOP = PROJECT / "rtl" / "cv" / "cv_top.v"

# 工具元素类型 -> (RTL 文件, X 参数, Y 参数, 说明)
MAPPING = {
    "logo":     (HDMI_MIXER, "LOGO_X", "LOGO_Y", "安路 Logo"),
    "count":    (CV_TOP, "CNT_X", "CNT_Y", "钢珠计数"),
    "osd_text": (HDMI_MIXER, "DYN_OSD_X", "DYN_OSD_Y", "动态 OSD 文本"),
}


def read_text(path: Path) -> str:
    with path.open("r", encoding="utf-8", newline="") as f:
        return f.read()


def write_text(path: Path, text: str) -> None:
    with path.open("w", encoding="utf-8", newline="") as f:
        f.write(text)


def localparam_re(name: str) -> re.Pattern:
    # 同时匹配：
    #   localparam LOGO_X = 12'd0;
    #   localparam [11:0] CNT_X = 12'd24;
    return re.compile(
        r"(localparam\s+(?:\[[^\]]+\]\s+)?" + re.escape(name) + r"\s*=\s*12'd)(\d+)(\s*;)"
    )


def patch_param(text: str, name: str, value: int):
    """返回 (新文本, 旧值, 是否变化, 出现次数)。"""
    pat = localparam_re(name)
    matches = list(pat.finditer(text))
    if not matches:
        return text, None, False, 0
    if len(matches) > 1:
        raise RuntimeError(f"{name} 在文件中出现 {len(matches)} 次，无法确定改哪一个")
    old = int(matches[0].group(2))
    new_text = pat.sub(lambda m: m.group(1) + str(value) + m.group(3), text, count=1)
    return new_text, old, old != value, 1


def load_elements(path: Path):
    data = json.loads(read_text(path))
    if not isinstance(data, dict) or not isinstance(data.get("elements"), list):
        raise ValueError("不是 UI Layout Studio 导出的 JSON（缺少 elements 数组）")
    return data["elements"]


def count_scale_shift(w, h) -> int:
    """把 Count 的 W/H 换算成 1/2/4/8 倍整数缩放（返回 shift）。"""
    if not isinstance(w, (int, float)) or not isinstance(h, (int, float)):
        return 0
    desired = min(float(w) / 40.0, float(h) / 7.0)
    if desired < 1.5:
        return 0
    if desired < 3.0:
        return 1
    if desired < 6.0:
        return 2
    return 3


def main() -> int:
    ap = argparse.ArgumentParser(description="把 ui_layout.json 的布局参数写回 camera_hdmi_720p RTL")
    ap.add_argument("json", nargs="?", default="ui_layout.json", help="布局 JSON（默认 ./ui_layout.json）")
    ap.add_argument("--dry-run", action="store_true", help="只显示差异，不写文件")
    args = ap.parse_args()

    json_path = Path(args.json)
    if not json_path.is_absolute():
        json_path = Path.cwd() / json_path
    if not json_path.exists():
        print(f"找不到布局文件：{json_path}", file=sys.stderr)
        return 2

    try:
        elements = load_elements(json_path)
    except Exception as exc:
        print(f"读取失败：{exc}", file=sys.stderr)
        return 2

    by_type = {}
    for el in elements:
        t = el.get("type")
        if t in MAPPING and t not in by_type:
            by_type[t] = el

    if not by_type:
        print("布局中没有可写回 RTL 的元素（logo / count / osd_text）。", file=sys.stderr)
        return 2

    # 按文件聚合修改，避免同一文件读写多次
    file_text = {}
    changes = []
    notes = []
    warnings = []

    for el_type, el in by_type.items():
        path, x_name, y_name, label = MAPPING[el_type]
        if not path.exists():
            warnings.append(f"缺少 RTL 文件：{path}")
            continue
        text = file_text.get(path)
        if text is None:
            text = read_text(path)

        for name, key in ((x_name, "x"), (y_name, "y")):
            value = el.get(key)
            if not isinstance(value, (int, float)):
                warnings.append(f"{label} 的 {key} 不是数字，跳过 {name}")
                continue
            value = int(round(value))
            if value < 0 or value > 4095:
                warnings.append(f"{label} 的 {key}={value} 超出 12-bit 范围，跳过 {name}")
                continue
            try:
                text, old, changed, count = patch_param(text, name, value)
            except RuntimeError as exc:
                warnings.append(str(exc))
                continue
            if count == 0:
                warnings.append(f"{path.name} 中找不到 {name}，跳过")
                continue
            changes.append((path, name, old, value, changed))

        # Count 额外写回整数缩放参数
        if el_type == "count":
            shift = count_scale_shift(el.get("w"), el.get("h"))
            cw, ch = 40 << shift, 7 << shift
            notes.append(f"{label}: {1 << shift}x 整数缩放 -> {cw}x{ch}")
            for name, value in (("CNT_W", cw), ("CNT_H", ch), ("CNT_SCALE_SHIFT", shift)):
                try:
                    text, old, changed, count = patch_param(text, name, value)
                except RuntimeError as exc:
                    warnings.append(str(exc))
                    continue
                if count == 0:
                    warnings.append(f"{path.name} 中找不到 {name}，计数缩放未启用")
                    continue
                changes.append((path, name, old, value, changed))

        file_text[path] = text

    if not changes:
        print("没有可应用的修改。")
        for w in warnings:
            print(f"  ! {w}")
        return 1

    # 打印摘要和 diff
    any_changed = False
    for path, name, old, new, changed in changes:
        mark = "->" if changed else "=="
        print(f"{path.name:16s} {name:16s} {old} {mark} {new}" + ("" if changed else "  (unchanged)"))
        any_changed = any_changed or changed

    for note in notes:
        print(f"  * {note}")

    for w in warnings:
        print(f"  ! {w}")

    if not any_changed:
        print("\n所有参数已经是目标值，无需修改。")
        return 0

    for path, text in file_text.items():
        old_text = read_text(path)
        if old_text == text:
            continue
        diff = difflib.unified_diff(
            old_text.splitlines(keepends=True),
            text.splitlines(keepends=True),
            fromfile=str(path),
            tofile=str(path) + " (layout)",
            n=1,
        )
        sys.stdout.writelines(diff)

    if args.dry_run:
        print("\n[dry-run] 未写入文件。")
        return 0

    for path, text in file_text.items():
        if read_text(path) != text:
            write_text(path, text)
            print(f"已写入 {path}")

    print("\n完成。下一步：重新综合（syn_1 -> phy_1）并用新的 bit/ELF 上板验证。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
