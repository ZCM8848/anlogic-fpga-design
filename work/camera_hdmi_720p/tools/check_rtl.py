#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_rtl.py — 工程静态自检（自研，无 iverilog 时的替代手段）

检查项：
  1) .al 清单 vs 磁盘：rtl/ 与 ip/ 下的 .v 是否全部被 .al 收录、清单里的文件是否都存在
  2) 模块端口表：解析每个 module 的端口（方向/位宽/名）
  3) 例化连接：顶层每个例化的端口名是否存在于被例化模块、是否有漏连/多连
  4) 位宽一致性：连接的网络位宽 vs 模块端口位宽（都能解析出时）
  5) 网络声明：连接用到的网络名是否在顶层有声明

用法：python check_rtl.py <工程根目录 work/camera_hdmi_720p>
"""
import os
import re
import sys
import xml.etree.ElementTree as ET

COMMENT_RE = re.compile(r"//[^\n]*|/\*.*?\*/", re.S)


def strip_comments(s):
    return COMMENT_RE.sub(" ", s)


def width_of(rng):
    """范围文本 → 位宽；None=无范围(1bit)，-1=符号表达式(未知)"""
    if rng is None:
        return 1
    m = re.match(r"(\d+)\s*:\s*(\d+)$", rng.strip())
    return (int(m.group(1)) - int(m.group(2)) + 1) if m else -1


def parse_modules(text):
    """返回 {模块名: [(方向, 位宽, 名), ...]}；位宽 -1 表示符号表达式未知"""
    out = {}
    for m in re.finditer(r"\bmodule\s+(\w+)\s*", text):
        name = m.group(1)
        i = m.end()
        # 跳过 #( ... )
        j = text.find("(", i)
        if j < 0:
            continue
        # 若 #(...) 存在，先跳过参数表
        k = i
        while k < len(text) and text[k].isspace():
            k += 1
        if k < len(text) and text[k] == "#":
            depth = 0
            while k < len(text):
                if text[k] == "(":
                    depth += 1
                elif text[k] == ")":
                    depth -= 1
                    if depth == 0:
                        k += 1
                        break
                k += 1
        # 端口表
        while k < len(text) and text[k].isspace():
            k += 1
        if k >= len(text) or text[k] != "(":
            continue
        depth = 0
        start = k
        while k < len(text):
            if text[k] == "(":
                depth += 1
            elif text[k] == ")":
                depth -= 1
                if depth == 0:
                    break
            k += 1
        body = text[start + 1:k]
        ports = []
        for p in split_top(body):
            p = p.strip()
            if not p:
                continue
            pm = re.match(
                r"(input|output|inout)\s*(?:wire|reg|logic)?\s*"
                r"(?:signed\s*)?(?:\[\s*([^\]]+?)\s*\])?\s*(\w+)", p)
            if pm:
                d, rng, nm = pm.group(1), pm.group(2), pm.group(3)
                ports.append((d, width_of(rng), nm))
        out[name] = ports
    return out


def split_top(s, sep=","):
    parts, depth, cur = [], 0, ""
    for ch in s:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == sep and depth == 0:
            parts.append(cur)
            cur = ""
        else:
            cur += ch
    parts.append(cur)
    return parts


def parse_decls(text):
    """顶层网络声明 {名: 位宽}（wire/reg/input/output/inout）"""
    d = {}
    for m in re.finditer(
            r"\b(?:wire|reg|input|output|inout)\b\s*(?:signed\s*)?"
            r"(\[\s*([^\]]+?)\s*\])?\s*([\w,\s]+?)"
            r"(?:\s*=\s*[^;]*)?;", text):
        rng, names = m.group(2), m.group(3)
        w = width_of(rng)
        for nm in names.split(","):
            nm = nm.strip()
            if re.fullmatch(r"\w+", nm):
                old = d.get(nm)
                if old is None or old == -1:
                    d[nm] = w
                elif w != -1:
                    d[nm] = max(old, w)
    return d


def find_instances(text, modnames):
    """返回 [(模块名, 例化名, {端口: 连接})]"""
    res = []
    for mod in modnames:
        for m in re.finditer(r"\b" + re.escape(mod) + r"\b", text):
            i = m.end()
            if not re.match(r"[\s\n]", text[m.start() - 1] if m.start() else " "):
                continue
            k = i
            while k < len(text) and text[k].isspace():
                k += 1
            if k < len(text) and text[k] == "#":
                depth = 0
                while k < len(text):
                    if text[k] == "(":
                        depth += 1
                    elif text[k] == ")":
                        depth -= 1
                        if depth == 0:
                            k += 1
                            break
                    k += 1
                while k < len(text) and text[k].isspace():
                    k += 1
            im = re.match(r"(\w+)", text[k:])
            if not im:
                continue
            inst = im.group(1)
            k += im.end()
            while k < len(text) and text[k].isspace():
                k += 1
            if k >= len(text) or text[k] != "(":
                continue
            depth = 0
            start = k
            while k < len(text):
                if text[k] == "(":
                    depth += 1
                elif text[k] == ")":
                    depth -= 1
                    if depth == 0:
                        break
                k += 1
            body = text[start + 1:k]
            conns = {}
            for c in split_top(body):
                c = c.strip()
                cm = re.match(r"\.(\w+)\s*\(\s*(.*?)\s*\)$", c, re.S)
                if cm:
                    conns[cm.group(1)] = cm.group(2).strip()
            if conns:
                res.append((mod, inst, conns))
    return res


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    root = os.path.abspath(root)
    errs, warns = [], []

    al = os.path.join(root, "td_project", "camera_hdmi_720p.al")
    # 注意：TD 的 .al 不是严格 XML（Attr 里有未转义的 &），故按文本解析
    al_txt = open(al, encoding="utf-8", errors="replace").read()
    listed, listed_all = set(), set()
    for pm in re.finditer(r'File\s+Path="([^"]+)"', al_txt):
        p = pm.group(1)
        fp = os.path.normpath(os.path.join(root, "td_project", p))
        listed_all.add(fp)
        if p.endswith(".v"):
            listed.add(fp)

    ondisk, svdisk = set(), set()
    for sub in ("rtl", "ip"):
        for dp, _, fns in os.walk(os.path.join(root, sub)):
            for fn in fns:
                fp = os.path.normpath(os.path.join(dp, fn))
                if fn.endswith(".v"):
                    ondisk.add(fp)
                elif fn.endswith(".sv"):
                    svdisk.add(fp)

    # ip/pll/PLL.v 由 TD 从 PLL.xml 生成（不必也不应写进 .al 的 Verilog 列表）
    generated = {p for p in ondisk if os.sep + "ip" + os.sep + "pll" + os.sep in p}
    for p in sorted(ondisk - listed - generated):
        errs.append("磁盘有但 .al 未收录: %s" % os.path.relpath(p, root))
    for p in sorted(listed - ondisk):
        errs.append(".al 收录但文件不存在: %s" % os.path.relpath(p, root))
    for p in sorted(listed_all - listed - ondisk):
        if p.endswith((".adc", ".sdc", ".xml")):
            continue
        # 非 .v 条目（如 SystemVerilog 的 .sv）按磁盘实际存在性判定
        if p not in svdisk:
            errs.append(".al 收录的文件不存在: %s" % os.path.relpath(p, root))
    # 参与解析的源码 = 全部 .v + 未加密的 .sv（.enc.sv 是加密件，跳过）
    parse_srcs = sorted(ondisk | {q for q in svdisk if ".enc." not in q})

    # 解析所有模块
    srcs = {}
    mods = {}
    for p in parse_srcs:
        t = strip_comments(open(p, encoding="utf-8", errors="replace").read().replace("\r\n", "\n"))
        srcs[p] = t
        for nm, ports in parse_modules(t).items():
            if nm in mods:
                warns.append("模块重名（后定义覆盖）: %s @ %s" % (nm, os.path.basename(p)))
            mods[nm] = ports

    print("模块清单（%d 个）: %s" % (len(mods), ", ".join(sorted(mods))))

    top = None
    for p, t in srcs.items():
        if os.path.basename(p) == "design_top_wrapper.v":
            top, top_path = t, p
    if top is None:
        print("!! 找不到顶层"); sys.exit(1)

    decls = parse_decls(top)
    # 顶层自身的端口也算已声明网络
    for d, w, nm in mods.get("design_top_wrapper", []):
        decls[nm] = max(decls.get(nm, 0), w)
    print("顶层声明的网络（%d 个）" % len(decls))

    for mod, inst, conns in find_instances(top, set(mods)):
        if mod == "design_top_wrapper":
            continue
        ports = {nm: (d, w) for d, w, nm in mods[mod]}
        for pname, net in conns.items():
            if pname not in ports:
                errs.append("%s(%s): 端口 %s 不存在于模块 %s" % (inst, mod, pname, mod))
                continue
            if net and re.fullmatch(r"\w+", net):
                if net not in decls:
                    errs.append("%s(%s): 网络 %s 未在顶层声明" % (inst, mod, net))
                else:
                    pw = ports[pname][1]
                    nw = decls[net]
                    if pw != nw and pw != -1 and nw != -1:
                        errs.append("%s(%s): 位宽不符 %s(端口 %d bit) ↔ %s(网络 %d bit)"
                                    % (inst, mod, pname, pw, net, nw))
        missing = [n for n in ports if n not in conns]
        if missing:
            errs.append("%s(%s): 端口漏连 %s" % (inst, mod, ", ".join(missing)))

    print()
    for w in warns:
        print("WARN " + w)
    for e in errs:
        print("ERR  " + e)
    print()
    print("结论：%d 个错误, %d 个警告" % (len(errs), len(warns)))
    sys.exit(1 if errs else 0)


if __name__ == "__main__":
    main()
