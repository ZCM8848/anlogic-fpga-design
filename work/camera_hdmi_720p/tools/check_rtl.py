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
  6) 常量位宽溢出：声明型（localparam/parameter）＋ rtl/ 内任意语境的裸字面量
     （`7'd144` 这类值超宽的写法会被工具静默截断，见 check_literal_widths 注释）

用法：python check_rtl.py <工程根目录 work/camera_hdmi_720p>
"""
import os
import re
import sys
import xml.etree.ElementTree as ET

COMMENT_RE = re.compile(r"//[^\n]*|/\*.*?\*/", re.S)


def strip_comments(s):
    """注释置换成等长空白（保留换行与字符偏移）——替换后行号/偏移仍然可用。"""
    return COMMENT_RE.sub(lambda m: re.sub(r"[^\n]", " ", m.group(0)), s)


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


def check_literal_widths(files, errs):
    """常量位宽溢出，两类都查：

    A) 声明型：`localparam [N:0] X = M'dV`，V ≥ 2^min(N+1,M) 会被静默截断。
       历史事故：status_report 的 LAST 从 7'd127 扩到 144 时忘了加宽位宽，
       7'd144 截断成 16 → 串口每行只发 17 字符就重头再来。

    B) 任意语境的裸字面量（只扫 rtl/ 自研源码）：`M'dV` 中 V 自身 ≥ 2^M。
       历史事故（M5 重写 status_report 时又犯一次）：`pc <= 7'd144`（截断成 16）
       与 `dl[pc - 7'd145]`（截断成 17）→ 比较条件永不成立、索引越界 →
       串口中间两行整段输出 0x00。TD 综合日志对应 HDL-5007 WARNING
       （literal value 'd144 truncated to fit in 7 bits），
       每次构建后应 grep 构建日志：**自己 rtl/ 的文件必须是 0 条**。
    """
    decl_pat = re.compile(r"\b(localparam|parameter)\s*\[\s*(\d+)\s*:\s*0\s*\]\s*(\w+)\s*=\s*"
                          r"(\d+)\s*'([dDhHbBoO])\s*([0-9a-fA-F_]+)")
    lit_pat = re.compile(r"(?<![\w'])(\d+)'(s?)([dDhHbBoO])([0-9a-fA-F_xXzZ]+)")
    bases = {"d": 10, "h": 16, "b": 2, "o": 8}
    for fp in sorted(files):
        try:
            txt = strip_comments(open(fp, encoding="utf-8", errors="replace").read())
        except Exception:
            continue
        # A) 声明型
        for m in decl_pat.finditer(txt):
            msb, name, size = int(m.group(2)), m.group(3), int(m.group(4))
            base = bases[m.group(5).lower()]
            try:
                val = int(m.group(6).replace("_", ""), base)
            except ValueError:
                continue
            lim = 2 ** min(msb + 1, size)
            if val >= lim:
                errs.append("常量位宽溢出: %s 的 %s = %d 超过 %d 位上限 %d（实际截断为 %d）"
                            % (os.path.basename(fp), name, val, min(msb + 1, size), lim - 1, val % lim))
        # B) 裸字面量（只看自研 rtl/，IP/厂商件逐字节保真不动）
        if not re.search(r"[\\/]rtl[\\/]", fp):
            continue
        for m in lit_pat.finditer(txt):
            size, sflag, bc, ds = int(m.group(1)), m.group(2), m.group(3).lower(), m.group(4)
            if sflag or re.search(r"[xXzZ]", ds):
                continue                      # 有符号/含 x-z 的字面量无法按值域判定
            try:
                val = int(ds.replace("_", ""), bases[bc])
            except ValueError:
                continue
            if val >= 2 ** size:
                line = txt.count("\n", 0, m.start()) + 1
                errs.append("常量位宽溢出: %s L%d 的 %d'%s = %d 超过 %d 位上限 %d"
                            "（TD 会静默截断并报 HDL-5007）"
                            % (os.path.basename(fp), line, size, bc, val, size, 2 ** size - 1))


def check_decl_order(files, errs):
    """先用后声明：内部信号被引用之后才声明时，工具按隐式 1 位线网处理。

    TD 报 HDL-7225 CRITICAL-WARNING 后仍继续编译，但后果是致命的：宽信号被截断、
    时钟线网可能被拆坏。M4 首轮上板事故就是这样 —— cam_linebuf 实例插在顶层前部，
    S_rx_byte_clk 等 6 个信号先用后声明，D-PHY 恢复时钟没接到字节域逻辑，
    整条 MIPI 停摆（串口 RX=0、HS=0），且可稳定复现。
    """
    for fp in sorted(files):
        try:
            # 注意：整篇剥离注释后再分行 —— 逐行剥离无法处理跨行块注释
            # （模块头部 /* */ 说明里出现的信号名会被当成代码，误报「先用后声明」）
            lines = strip_comments(open(fp, encoding="utf-8", errors="replace").read()).splitlines()
        except Exception:
            continue
        decl = {}
        for i, L in enumerate(lines, 1):
            if re.match(r"\s*(input|output|inout)\b", L):
                continue                       # 端口在端口列表里已声明
            if re.search(r"^\s*(wire|reg)\b", L):
                body = re.sub(r"^\s*(wire|reg)\b", "", L).split("=")[0]
                body = re.sub(r"\[[^\]]*\]", " ", body)   # 去掉位宽 [..]，它不是信号名
                for nm in re.findall(r"\b([A-Za-z_]\w*)\b", body):
                    if nm in ("wire", "reg", "signed", "unsigned"):
                        continue
                    decl.setdefault(nm, i)
        for nm, dl in decl.items():
            for i in range(1, dl):
                if i - 1 < len(lines) and re.search(r"\b" + re.escape(nm) + r"\b", lines[i - 1]):
                    errs.append("先用后声明: %s 的 %s 在 L%d 被引用、L%d 才声明"
                                "（工具会按隐式 1 位线网处理，宽位信号会被截断）"
                                % (os.path.basename(fp), nm, i, dl))
                    break


def check_multi_driver(files, errs):
    """同一信号被多个 always 块驱动（Verilog 多驱动）。

    TD 在 elaboration 阶段直接报 `HDL-8007 ERROR: net 'xxx' is constantly driven from
    multiple places`（M5-② 真踩过：S_dtgl0 在主块复位段和排空引擎块各驱动一次）。
    只在 reset 分支里驱动也算 —— 只要出现在两个 always 块里就是错。
    """
    for fp in sorted(files):
        try:
            txt = strip_comments(open(fp, encoding="utf-8", errors="replace").read())
        except Exception:
            continue
        # 切出每个 always 块：从 always 关键字起，跟踪 begin/end 配平
        blocks = []
        for m in re.finditer(r"\balways\b", txt):
            i = m.start()
            depth = 0
            started = False
            j = i
            for tm in re.finditer(r"\b(begin|end)\b", txt[i:]):
                if tm.group(1) == "begin":
                    depth += 1
                    started = True
                else:
                    depth -= 1
                if started and depth == 0:
                    j = i + tm.end()
                    break
            blocks.append((i, j, txt[i:j]))
        drivers = {}
        for (i, j, blk) in blocks:
            ln = txt.count("\n", 0, i) + 1
            for sm in re.finditer(r"(?:^|;|\bbegin\b|\belse\b|\))\s*([A-Za-z_]\w*)\s*(?:\[[^\]]*\])?\s*[<]=",
                                  blk, re.M):
                drivers.setdefault(sm.group(1), set()).add(ln)
        for nm, lns in sorted(drivers.items()):
            if len(lns) > 1:
                errs.append("多驱动: %s 的 %s 在多个 always 块（L%s）被赋值 → TD 报 "
                            "HDL-8007 constantly driven from multiple places"
                            % (os.path.basename(fp), nm, "、L".join(str(x) for x in sorted(lns))))


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
    # ip/ddr2/ddr2/** 同理：由 ddr2.xml 的 fileSet 引入（厂商 IP 生成件，逐字节保真），
    #   不逐文件登 .al，也不参与解析/自检（其风格不受本项目规则约束）。
    #   注意 ip/ddr2/ph1p35_324_ddr_wrapper.v（IP 外层适配件）仍登 .al 并参与解析。
    ip_managed = {os.sep + "ip" + os.sep + "ddr2" + os.sep + "ddr2" + os.sep}
    generated = {p for p in ondisk
                 if os.sep + "ip" + os.sep + "pll" + os.sep in p or any(k in p for k in ip_managed)}
    check_literal_widths({p for p in (ondisk | svdisk) if not any(k in p for k in ip_managed)}, errs)
    check_decl_order({p for p in (ondisk | svdisk) if not any(k in p for k in ip_managed)}, errs)
    check_multi_driver({p for p in (ondisk | svdisk) if not any(k in p for k in ip_managed)}, errs)
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
    # 参与解析的源码 = 全部 .v + 未加密的 .sv（.enc.sv 是加密件，跳过；IP 生成件子树同样跳过）
    parse_srcs = sorted({p for p in (ondisk | {q for q in svdisk if ".enc." not in q})
                         if not any(k in p for k in ip_managed)})

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
        miss_in  = [n for n in ports if n not in conns and ports[n][0] in ("input", "inout")]
        miss_out = [n for n in ports if n not in conns and ports[n][0] == "output"]
        if miss_in:
            errs.append("%s(%s): 输入端口漏连 %s" % (inst, mod, ", ".join(miss_in)))
        if miss_out:
            warns.append("%s(%s): 输出端口悬空（有意可忽略）%s" % (inst, mod, ", ".join(miss_out)))

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
