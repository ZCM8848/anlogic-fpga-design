#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""cam_view.py — camera_eth_720p 实时显示（UDP 4660 → AWB → 列噪声校正 → 降噪 → 显示）

用法：
    python cam_view.py                 # 实时显示
    python cam_view.py --record out.mp4
    python cam_view.py --no-denoise

按键：q 退出，s 保存当前帧 PNG，r 开始/停止录像

说明：
  - FPGA 每帧先发一个元数据包（pkt_idx=0xFFFF），里面有曝光/增益/B/G/R 累加和，
    这里优先用它的统计做 AWB；收不到元数据包时退化为本帧灰世界。
  - 列固定图案噪声用「列剖面的高频分量」做校正，剖面用 EMA 缓慢跟踪场景。
  - 每 2 帧渲染 1 帧，保证 720p 在 Python 里也能跟上 60fps 的流。
"""
import argparse
import struct
import time
from collections import defaultdict

import numpy as np
import cv2

from cam_proc import (W, H, PKT_BYTES, PKT_TOTAL, META_IDX, parse_meta,
                      awb_gains, awb_gains_from_meta, apply_awb,
                      column_profile, column_correction, to_bgr, denoise,
                      BLACK_LEVEL)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=4660)
    ap.add_argument("--record", default=None, help="录像输出 mp4")
    ap.add_argument("--no-denoise", action="store_true")
    ap.add_argument("--fps", type=float, default=12.0, help="显示帧率上限（收包不丢优先）")
    ap.add_argument("--seconds", type=float, default=0, help="运行多少秒后自动退出（0=一直跑）")
    args = ap.parse_args()

    import socket
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    # 45k 包/秒，渲染时会暂停收包，必须把内核接收缓冲开大，否则整帧收不齐
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 * 1024 * 1024)
    except OSError:
        pass
    try:
        sock.bind(("0.0.0.0", args.port))
    except OSError as e:
        print(f"[error] 绑定 UDP {args.port} 失败: {e}")
        return 1
    sock.settimeout(0.5)
    print(f"[udp] listening on :{args.port}   (q 退出 / s 存图 / r 录像)")

    frames = {}
    cnt = {}
    metas = {}
    frame_no = 0
    shown = 0
    t0 = time.time()
    last_rx = time.time()
    last_render = 0.0
    last_key = 0.0

    prof_ema = None          # 列剖面 EMA
    lo = hi = None
    record = args.record
    writer = None
    vw = None
    last_bgr = None

    def render(fid, d):
        nonlocal prof_ema, lo, hi, shown, writer, vw, last_bgr
        buf = b"".join(d[i] for i in range(PKT_TOTAL))
        from cam_proc import unpack_raw10
        px = unpack_raw10(buf)[:W * H].reshape(H, W)

        m = metas.get(fid)
        if m:
            gb, gr = awb_gains_from_meta(m)
        else:
            gb, gr = awb_gains(px)

        bal = apply_awb(px, gb, gr)

        # 列固定图案噪声：列剖面 EMA 的高频部分
        cp = column_profile(bal)
        prof_ema = cp if prof_ema is None else (prof_ema * 0.9 + cp * 0.1)
        bal -= column_correction(prof_ema)[None, :]
        np.clip(bal, 0, 1023, out=bal)

        if lo is None:
            lo = float(np.percentile(bal, 0.5))
            hi = float(np.percentile(bal, 99.5))
        else:
            lo = lo * 0.9 + float(np.percentile(bal, 0.5)) * 0.1
            hi = hi * 0.9 + float(np.percentile(bal, 99.5)) * 0.1
        if hi - lo < 16:
            hi = lo + 16

        bgr = to_bgr(bal, lo, hi)
        if not args.no_denoise:
            bgr = denoise(bgr, 1)

        # 信息条
        info = f"F{fid} {gb:.2f}/{gr:.2f}"
        if m:
            info += f" ae={m['ae']} ag={m['ag']} sid={m['sensor_id']:04X}"
        cv2.putText(bgr, info, (12, 26), cv2.FONT_HERSHEY_SIMPLEX, 0.7,
                    (0, 255, 0), 2, cv2.LINE_AA)

        shown += 1
        last_bgr = bgr
        cv2.imshow("camera_eth_720p (q=quit s=save r=record)", bgr)

        if vw is not None:
            vw.write(bgr)
        return bgr

    try:
        while True:
            try:
                data, _ = sock.recvfrom(2048)
            except socket.timeout:
                data = None

            if data is not None:
                last_rx = time.time()
                if data[:2] == b"\xAA\x55" and len(data) >= 1448:
                    fid = (data[2] << 8) | data[3]
                    pidx = (data[4] << 8) | data[5]
                    if pidx == META_IDX:
                        m = parse_meta(data[8:])
                        if m:
                            metas[m["frame_id"]] = m
                    elif pidx < PKT_TOTAL:
                        fr = frames.get(fid)
                        if fr is None:
                            fr = frames[fid] = [None] * PKT_TOTAL
                            cnt[fid] = 0
                        if fr[pidx] is None:
                            fr[pidx] = data[8:]
                            cnt[fid] += 1
                            if cnt[fid] == PKT_TOTAL:
                                frame_no += 1
                                now = time.time()
                                if now - last_render >= 1.0 / max(1.0, args.fps):
                                    render(fid, fr)
                                    last_render = now
                                # 只保留最近两帧，防止内存膨胀
                                for k in [k for k in frames if k < fid - 1]:
                                    del frames[k]
                                    cnt.pop(k, None)
                                for k in [k for k in metas if k < fid - 1]:
                                    del metas[k]
            elif time.time() - last_rx > 3:
                print("[warn] 3 秒没有收到视频包：检查 PC IP 是否 192.168.1.100 / 网线 / 防火墙")
                last_rx = time.time()

            # cv2.waitKey 很贵，不能每包调用（45k 包/秒会把收包拖垮）
            now = time.time()
            if args.seconds and (now - t0) > args.seconds:
                break
            if now - last_key < 0.02:
                continue
            last_key = now

            key = cv2.waitKey(1) & 0xFF
            if key == ord("q"):
                break
            elif key == ord("s"):
                if last_bgr is not None:
                    fn = f"snapshot_{int(time.time())}.png"
                    cv2.imwrite(fn, last_bgr)
                    print(f"[save] {fn}")
            elif key == ord("r"):
                if writer is None and args.record:
                    vw = cv2.VideoWriter(args.record, cv2.VideoWriter_fourcc(*"mp4v"),
                                         30.0, (W, H))
                    print(f"[record] {args.record}")
                    writer = args.record
                elif writer is not None:
                    vw.release()
                    vw = None
                    print("[record] stopped")
    except KeyboardInterrupt:
        pass
    finally:
        if vw is not None:
            vw.release()
        sock.close()
        dur = max(time.time() - t0, 1e-3)
        print(f"[exit] 渲染 {shown} 帧 / {dur:.1f}s = {shown/dur:.1f} fps")
        cv2.destroyAllWindows()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
