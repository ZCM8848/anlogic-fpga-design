# -*- coding: utf-8 -*-
"""
main.py -- 钢珠跟踪与计数（FPGA 黄金参考 / 传统 CV）
======================================================
链路: 采集 -> 亮度 -> Sobel -> 阈值 -> run/CCL -> 筛选 -> α-β 跟踪 -> 计数 -> OSD

与 FPGA 的对应（cv_top.v）：
  检测/跟踪/叠加算法与 RTL 逐算法一致；叠加的框有 1 帧延迟（等价 vblank 更新）。

用法:
  python main.py                                  # 摄像头
  python main.py --video sim_test.mp4             # 离线回放
  python main.py --video sim_test.mp4 --no-display --output out.mp4   # 自动测试
  python main.py --mask-view 0                    # 关闭机器视角，看原始彩色画面

按键:
  q / ESC : 退出       空格 : 暂停/继续       r : 复位计数与跟踪
  m       : 切换机器视角(MASK_VIEW)           d : 掩膜调试窗
  - / =   : 阈值偏置 -1 / +1（等价 FPGA K3/K4） s : 保存参数
"""
import argparse
import time

import cv2
import numpy as np

import osd
from config import Config, CONFIG_PATH
from count import count_crossings
from detect import Detector
from track import Tracker


# ======================================================================
# 采集
# ======================================================================
def _backend_flag(name):
    name = (name or "AUTO").upper()
    if name == "DSHOW" and hasattr(cv2, "CAP_DSHOW"):
        return cv2.CAP_DSHOW
    if name == "MSMF" and hasattr(cv2, "CAP_MSMF"):
        return cv2.CAP_MSMF
    return cv2.CAP_ANY


def open_camera(cfg):
    order = [cfg.backend]
    if cfg.backend.upper() != "AUTO":
        order.append("AUTO")
    for index in [cfg.cam_index, cfg.fallback_index]:
        for be in order:
            cap = cv2.VideoCapture(index, _backend_flag(be))
            if not cap.isOpened():
                cap.release()
                continue
            if cfg.fourcc:
                cap.set(cv2.CAP_PROP_FOURCC,
                        cv2.VideoWriter_fourcc(*cfg.fourcc))
            cap.set(cv2.CAP_PROP_FRAME_WIDTH, cfg.frame_w)
            cap.set(cv2.CAP_PROP_FRAME_HEIGHT, cfg.frame_h)
            cap.set(cv2.CAP_PROP_FPS, cfg.fps)
            cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
            if cfg.lock_exposure:
                try:
                    cap.set(cv2.CAP_PROP_AUTO_EXPOSURE, 0.25)
                    cap.set(cv2.CAP_PROP_EXPOSURE, cfg.exposure)
                except Exception:
                    pass
            ok, frame = cap.read()
            if ok and frame is not None:
                aw = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
                ah = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
                print("[camera] index=%d backend=%s  %dx%d"
                      % (index, be, aw, ah))
                return cap
            cap.release()
    return None


def to_bgr(frame):
    """把任意读入帧规整为 (H,W,3) uint8 BGR。"""
    if frame.ndim == 2:
        return cv2.cvtColor(frame, cv2.COLOR_GRAY2BGR)
    if frame.shape[2] == 4:
        return cv2.cvtColor(frame, cv2.COLOR_BGRA2BGR)
    return frame


# ======================================================================
# 主流程
# ======================================================================
def main():
    ap = argparse.ArgumentParser(description="钢珠跟踪与计数 (FPGA 黄金参考)")
    ap.add_argument("--camera", type=int, default=None)
    ap.add_argument("--video", type=str, default=None)
    ap.add_argument("--output", type=str, default=None)
    ap.add_argument("--no-display", action="store_true")
    ap.add_argument("--max-frames", type=int, default=0)
    ap.add_argument("--mask-view", type=int, default=None, choices=[0, 1])
    ap.add_argument("--edge-thr", type=int, default=None)
    ap.add_argument("--config", type=str, default=CONFIG_PATH)
    args = ap.parse_args()

    cfg = Config().load(args.config)
    if args.camera is not None:
        cfg.cam_index = args.camera
    if args.mask_view is not None:
        cfg.mask_view = args.mask_view
    if args.edge_thr is not None:
        cfg.edge_thr = args.edge_thr

    # ------------------ 打开视频源 ------------------
    is_file = args.video is not None
    if is_file:
        cap = cv2.VideoCapture(args.video)
        if not cap.isOpened():
            print("[error] cannot open video:", args.video)
            return
        src_fps = float(cap.get(cv2.CAP_PROP_FPS)) or 30.0
    else:
        cap = open_camera(cfg)
        if cap is None:
            print("[error] no camera available")
            return
        src_fps = float(cap.get(cv2.CAP_PROP_FPS)) or float(cfg.fps)

    # ------------------ 构建处理链 ------------------
    detector = Detector(cfg)
    tracker = Tracker(cfg)
    line_a, line_b, line_c = cfg.line
    dx, dy = cfg.direction
    count = 0
    prev_tracks = []          # 叠加用（1 帧延迟，等价 FPGA vblank 更新）

    writer = None
    if args.output:
        fourcc = cv2.VideoWriter_fourcc(*"mp4v")
        writer = cv2.VideoWriter(args.output, fourcc, src_fps,
                                 (cfg.frame_w, cfg.frame_h))

    show = not args.no_display
    if show:
        cv2.namedWindow("ball_track", cv2.WINDOW_NORMAL)

    paused = False
    fps_t0 = time.time()
    fps_n = 0
    fps_val = 0.0
    frame_count = 0

    print("[info] processing at %dx%d  (mask_src=%d edge_thr=%d)"
          % (cfg.frame_w, cfg.frame_h, cfg.mask_src, cfg.edge_thr))

    while True:
        # ------------------ 取帧 ------------------
        if is_file:
            if not paused:
                ok, frame = cap.read()
                if not ok or frame is None:
                    break
        else:
            ok, frame = cap.read()
            if not ok or frame is None:
                time.sleep(0.005)
                continue

        if not paused:
            frame_count += 1
            frame = to_bgr(frame)
            if (frame.shape[0], frame.shape[1]) != (cfg.frame_h, cfg.frame_w):
                frame = cv2.resize(frame, (cfg.frame_w, cfg.frame_h),
                                   interpolation=cv2.INTER_AREA)

            # ------------------ 处理（等价 FPGA 一帧：active + vblank） ------------------
            dets, mask, _Y, _mag = detector.process(frame)
            tracker.update(dets)
            count += count_crossings(tracker.tracks, line_a, line_b, line_c,
                                     dx, dy)

        # ------------------ 叠加（框用上一帧轨迹，1 帧延迟） ------------------
        vis = osd.render_overlay(frame, mask, prev_tracks, cfg)
        osd.draw_hud(vis, count, sum(1 for t in prev_tracks if t["valid"]),
                     fps_val if cfg.show_fps else None)
        if cfg.draw_line:
            osd.draw_line(vis, line_a, line_b, line_c)

        # 记录下一帧要叠加的轨迹
        prev_tracks = tracker.snapshot()

        fps_n += 1
        if time.time() - fps_t0 >= 0.5:
            fps_val = fps_n / (time.time() - fps_t0)
            fps_t0 = time.time()
            fps_n = 0

        if writer is not None:
            writer.write(vis)

        # ------------------ 显示 & 按键 ------------------
        if show:
            cv2.imshow("ball_track", vis)
            if cfg.show_mask:
                cv2.imshow("mask", mask.astype(np.uint8) * 255)
            k = cv2.waitKey(1) & 0xFF
            if k in (27, ord("q")):
                break
            elif k == ord(" "):
                paused = not paused
            elif k == ord("r"):
                count = 0
                tracker.reset()
                detector.reset()
            elif k == ord("m"):
                cfg.mask_view = 1 - cfg.mask_view
            elif k == ord("d"):
                cfg.show_mask = not cfg.show_mask
                if not cfg.show_mask:
                    try:
                        cv2.destroyWindow("mask")
                    except Exception:
                        pass
            elif k in (ord("-"), ord("_")):
                cfg.user_off = max(-128, cfg.user_off - 1)
                print("[thr] user_off=%d" % cfg.user_off)
            elif k in (ord("="), ord("+")):
                cfg.user_off = min(127, cfg.user_off + 1)
                print("[thr] user_off=%d" % cfg.user_off)
            elif k == ord("s"):
                cfg.save(args.config)
                print("[info] config saved to", args.config)

        if args.max_frames and frame_count >= args.max_frames:
            break

    # ------------------ 收尾 ------------------
    if writer is not None:
        writer.release()
    cap.release()
    if show:
        cv2.destroyAllWindows()

    print("[result] frames=%d  count=%d  tracks_total=%d"
          % (frame_count, count, tracker.next_id))


if __name__ == "__main__":
    main()
