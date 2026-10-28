#!/usr/bin/env python3
"""gen_ui_text_rom.py — 用 MiSans Medium 生成 1-bit 静态文字 ROM。

生成：
    rtl/video/ui_text_rom.v          （STEEL BALL / Anlogic HX1P35A / FRAME 前缀 / 0-9 数字）
    tools/ui_layout/misans_text_preview.png

用法：
    python tools/ui_layout/gen_ui_text_rom.py
    python tools/ui_layout/gen_ui_text_rom.py --font path/to/MiSans-Medium.ttf
"""

import argparse
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]
DEFAULT_FONT = Path(r"C:\Users\Z___C\Documents\NUEDC\sdcard\ball_balance\fonts\MiSans-Medium.ttf")
OUT_V = PROJECT / "rtl" / "video" / "ui_text_rom.v"
OUT_PNG = HERE / "misans_text_preview.png"

# (name, text, box_w, box_h, color)
TEXTS = [
    ("label", "STEEL BALL", 160, 18, (0x8B, 0xE9, 0xFD)),
    ("text", "Anlogic HX1P35A", 160, 24, (0xFF, 0xF2, 0x00)),
    ("frame", "FRAME ", 80, 20, (0x9A, 0xA7, 0xBD)),
]
DIGIT_CELL_W = 16
DIGIT_CELL_H = 20
DIGIT_COLOR = (0x9A, 0xA7, 0xBD)


def fit_font(font_path: Path, text: str, box_w: int, box_h: int):
    size = box_h
    while size > 6:
        font = ImageFont.truetype(str(font_path), size)
        bbox = font.getbbox(text)
        tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
        if tw <= box_w - 2 and th <= box_h:
            return font, size, bbox
        size -= 1
    font = ImageFont.truetype(str(font_path), 6)
    return font, 6, font.getbbox(text)


def render_text(font_path: Path, text: str, box_w: int, box_h: int):
    font, size, bbox = fit_font(font_path, text, box_w, box_h)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    img = Image.new("L", (box_w, box_h), 0)
    draw = ImageDraw.Draw(img)
    x = 0
    y = (box_h - th) // 2 - bbox[1]
    draw.text((x - bbox[0], y), text, font=font, fill=255)
    mask = img.point(lambda v: 255 if v >= 128 else 0, "1")
    return mask, size, (tw, th)


def render_digit(font_path: Path, digit: int):
    font = ImageFont.truetype(str(font_path), DIGIT_CELL_H)
    text = str(digit)
    bbox = font.getbbox(text)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    img = Image.new("L", (DIGIT_CELL_W, DIGIT_CELL_H), 0)
    draw = ImageDraw.Draw(img)
    x = (DIGIT_CELL_W - tw) // 2 - bbox[0]
    y = (DIGIT_CELL_H - th) // 2 - bbox[1]
    draw.text((x, y), text, font=font, fill=255)
    mask = img.point(lambda v: 255 if v >= 128 else 0, "1")
    return mask, (tw, th)


def row_value(mask: Image.Image, y: int) -> int:
    w = mask.width
    v = 0
    for x in range(w):
        if mask.getpixel((x, y)):
            v |= 1 << x
    return v


def emit_rows(out, prefix: str, mask: Image.Image):
    width = mask.width
    hexw = (width + 3) // 4
    for y in range(mask.height):
        out.append(f"    localparam [{width - 1}:0] {prefix}_ROW{y} = {width}'h{row_value(mask, y):0{hexw}x};")


def emit_function(out, name: str, x_width: int, y_width: int, rows: int, row_prefix: str, x_name="x", y_name="y"):
    out.append(f"    function {name};")
    out.append(f"        input [{x_width - 1}:0] {x_name};")
    out.append(f"        input [{y_width - 1}:0] {y_name};")
    out.append("        begin")
    out.append(f"            case ({y_name})")
    for y in range(rows):
        out.append(f"                {y_width}'d{y}: {name} = {row_prefix}_ROW{y}[{x_name}];")
    out.append(f"                default: {name} = 1'b0;")
    out.append("            endcase")
    out.append("        end")
    out.append("    endfunction")
    out.append("")


def emit_digit_function(out, digit) -> None:
    out.append("    function F_digit;")
    out.append("        input [3:0] d;")
    out.append("        input [3:0] x;")
    out.append("        input [4:0] y;")
    out.append("        begin")
    out.append("            case (d)")
    for d, mask in enumerate(digit):
        out.append(f"                4'd{d}: begin")
        out.append("                    case (y)")
        for y in range(mask.height):
            out.append(f"                        5'd{y}: F_digit = D{d}_ROW{y}[x];")
        out.append("                        default: F_digit = 1'b0;")
        out.append("                    endcase")
        out.append("                end")
    out.append("                default: F_digit = 1'b0;")
    out.append("            endcase")
    out.append("        end")
    out.append("    endfunction")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--font", default=str(DEFAULT_FONT))
    ap.add_argument("--out", default=str(OUT_V))
    args = ap.parse_args()

    font_path = Path(args.font)
    if not font_path.exists():
        print(f"字体不存在: {font_path}")
        return 2

    masks = {}
    for name, text, w, h, _color in TEXTS:
        mask, size, dim = render_text(font_path, text, w, h)
        masks[name] = mask
        print(f"{name:6s} {text!r:20s} box={w}x{h} font={size}px text={dim[0]}x{dim[1]}")

    digits = []
    for d in range(10):
        mask, dim = render_digit(font_path, d)
        digits.append(mask)
        print(f"digit {d}: {dim[0]}x{dim[1]} in {DIGIT_CELL_W}x{DIGIT_CELL_H}")

    out = []
    out.append("// ============================================================")
    out.append("// ui_text_rom.v — MiSans Medium 1-bit static UI text")
    out.append("// Generated by tools/ui_layout/gen_ui_text_rom.py")
    out.append("//")
    out.append("// STEEL BALL       160x18")
    out.append("// Anlogic HX1P35A  160x24")
    out.append("// FRAME prefix      80x20")
    out.append("// digits            16x20 x 10")
    out.append("// ============================================================")
    out.append("")
    out.append("module ui_text_rom (")
    out.append("    input  wire [7:0] I_LABEL_X,")
    out.append("    input  wire [4:0] I_LABEL_Y,")
    out.append("    output wire       O_LABEL,")
    out.append("    input  wire [7:0] I_TEXT_X,")
    out.append("    input  wire [4:0] I_TEXT_Y,")
    out.append("    output wire       O_TEXT,")
    out.append("    input  wire [6:0] I_FRAME_X,")
    out.append("    input  wire [4:0] I_FRAME_Y,")
    out.append("    output wire       O_FRAME,")
    out.append("    input  wire [3:0] I_DIGIT,")
    out.append("    input  wire [3:0] I_DIGIT_X,")
    out.append("    input  wire [4:0] I_DIGIT_Y,")
    out.append("    output wire       O_DIGIT")
    out.append(");")
    out.append("")

    emit_rows(out, "L", masks["label"])
    out.append("")
    emit_rows(out, "T", masks["text"])
    out.append("")
    emit_rows(out, "F", masks["frame"])
    out.append("")
    for d, mask in enumerate(digits):
        emit_rows(out, f"D{d}", mask)
    out.append("")

    emit_function(out, "F_label", 8, 5, masks["label"].height, "L")
    emit_function(out, "F_text", 8, 5, masks["text"].height, "T")
    emit_function(out, "F_frame", 7, 5, masks["frame"].height, "F")
    emit_digit_function(out, digits)
    out.append("")
    out.append("    assign O_LABEL = F_label(I_LABEL_X, I_LABEL_Y);")
    out.append("    assign O_TEXT  = F_text (I_TEXT_X,  I_TEXT_Y);")
    out.append("    assign O_FRAME = F_frame(I_FRAME_X, I_FRAME_Y);")
    out.append("    assign O_DIGIT = F_digit(I_DIGIT, I_DIGIT_X, I_DIGIT_Y);")
    out.append("")
    out.append("endmodule")
    out.append("")

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text("\n".join(out), encoding="utf-8")
    print(f"wrote {out_path} ({len('\\n'.join(out))} chars)")

    # Preview: 4x nearest neighbor, dark background
    scale = 4
    cell_h = 18 * scale + 10
    sheet_w = max(160, 160, 80 + 6 * DIGIT_CELL_W) * scale + 20
    sheet_h = 40 + 3 * cell_h + 20 + DIGIT_CELL_H * scale + 30
    sheet = Image.new("RGB", (sheet_w, sheet_h), (10, 16, 26))
    d = ImageDraw.Draw(sheet)
    small = ImageFont.truetype(str(font_path), 12)
    y = 8
    for name, text, w, h, color in TEXTS:
        mask = masks[name]
        d.text((8, y), f"{name}: {text!r}  {w}x{h}", font=small, fill=(180, 200, 230))
        y += 14
        big = mask.convert("RGB").resize((w * scale, h * scale), Image.NEAREST)
        px = big.load()
        for yy in range(big.height):
            for xx in range(big.width):
                if px[xx, yy][0]:
                    px[xx, yy] = color
                else:
                    px[xx, yy] = (10, 16, 26)
        sheet.paste(big, (8, y))
        y += h * scale + 8

    d.text((8, y), "digits 16x20", font=small, fill=(180, 200, 230))
    y += 14
    for i, mask in enumerate(digits):
        big = mask.convert("RGB").resize((DIGIT_CELL_W * scale, DIGIT_CELL_H * scale), Image.NEAREST)
        px = big.load()
        for yy in range(big.height):
            for xx in range(big.width):
                if px[xx, yy][0]:
                    px[xx, yy] = DIGIT_COLOR
                else:
                    px[xx, yy] = (10, 16, 26)
        sheet.paste(big, (8 + i * (DIGIT_CELL_W * scale + 4), y))
    sheet.save(OUT_PNG)
    print(f"wrote {OUT_PNG}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
