#!/usr/bin/env python3
"""sync_prj.py —— 把 .al 的源文件清单同步进 run 目录的 .prj

背景（M5-② 实测）：
  TD 命令行流程（DefaultFlow.tcl）打开的是 run 目录里的 <prj>.prj（工程运行态），
  而 .al 只是「可移植工程文件」。往 .al 里新增源文件后，若不重新在 GUI 打开一次工程，
  .prj 里仍是旧清单 → 综合报 `HDL-8007 <module> is a black box`。
  本脚本做定向同步：只把 .al 里存在、.prj 里缺失的条目补进 .prj 对应小节，
  不动 .prj 的其他内容（Runs/Configurations 等）。

用法：
  python tools/td_run/sync_prj.py <工程目录，含 td_project/xxx.al>
  # 例：python tools/td_run/sync_prj.py work/camera_hdmi_720p
  # 会同步 td_project/camera_hdmi_720p.al → */camera_hdmi_720p_Runs/{syn_1,phy_1}/*.prj
"""
import re
import sys
from pathlib import Path

SECTIONS = ["Verilog", "System_Verilog", "ADC_FILE", "SDC_FILE", "IP_FILE"]


def parse_al_files(al_text):
    """-> [(section, rel_path)]，保持 .al 内顺序"""
    out = []
    for sec in SECTIONS:
        m = re.search(r"<%s>(.*?)</%s>" % (sec, sec), al_text, re.S)
        if not m:
            continue
        for p in re.findall(r'<File Path="([^"]+)">', m.group(1)):
            out.append((sec, p))
    return out


def sync_one(prj_path: Path, entries) -> int:
    raw = prj_path.read_bytes().decode("utf-8")
    nl = "\r\n" if "\r\n" in raw else "\n"
    added = 0
    for sec, al_path in entries:
        # .al 在 td_project/ 下，路径以 ../ 开头；.prj 在 td_project/<prj>_Runs/<run>/ 下
        prj_rel = "../../../" + al_path[3:] if al_path.startswith("../") else al_path
        if prj_rel in raw:
            continue
        m = re.search(r"^([ \t]*)</%s>" % sec, raw, re.M)
        if not m:
            print("  [WARN] %s 无 <%s> 小节，跳过 %s" % (prj_path.name, sec, al_path))
            continue
        indent = m.group(1)          # 小节闭合行缩进（如 8 空格）
        body = indent + "    "       # <File> 行缩进（如 12 空格）
        blk = []
        blk.append('%s<File Path="%s">' % (body, prj_rel))
        blk.append("%s    <FileInfo>" % body)
        blk.append('%s        <Attr Name="UsedInSyn" Val="true"/>' % body)
        blk.append('%s        <Attr Name="UsedInP&R" Val="true"/>' % body)
        blk.append('%s        <Attr Name="BelongTo" Val="design_1"/>' % body)
        blk.append('%s        <Attr Name="CompileOrder" Val="99"/>' % body)
        blk.append("%s    </FileInfo>" % body)
        blk.append("%s</File>" % body)
        raw = raw[: m.start()] + nl.join(blk) + nl + raw[m.start():]
        added += 1
        print("  [补] %s ← %s" % (prj_path.name, prj_rel))
    if added:
        prj_path.write_bytes(raw.encode("utf-8"))
    return added


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    proj = Path(sys.argv[1]).resolve()
    als = list((proj / "td_project").glob("*.al"))
    if not als:
        print("找不到 .al：", proj / "td_project")
        return 1
    total = 0
    for al in als:
        entries = parse_al_files(al.read_text(encoding="utf-8"))
        prjs = sorted((proj / "td_project").glob("%s_Runs/*/%s.prj" % (al.stem, al.stem)))
        print("%s：%d 条源文件 → %d 个 .prj" % (al.name, len(entries), len(prjs)))
        for p in prjs:
            total += sync_one(p, entries)
    print("共补入 %d 条" % total)
    return 0


if __name__ == "__main__":
    sys.exit(main())
