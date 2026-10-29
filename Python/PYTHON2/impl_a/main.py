# -*- coding: utf-8 -*-
"""
main.py -- 钢珠跟踪与计数系统（主程序）
============================================================
链路: 采集 -> 预处理 -> 检测 -> 跟踪 -> 计数 -> OSD 叠加 -> 显示

用法:
  # 外接 SC520CS(USB, 1280x720@60)，失败自动回退内置摄像头
  python main.py

  # 指定摄像头序号
  python main.py --camera 0

  # 离线回放调参(强烈推荐先用 simulate.py 生成测试视频)
  python main.py --video sim_test.mp4

  # 无显示 + 保存结果视频(适合服务器/自动测试)
  python main.py --video sim_test.mp4 --no-display --output out.mp4

  # 交互标定 ROI/计数线/方向/钢珠直径
  python main.py --calibrate

按键:
  q / ESC : 退出          c : 交互标定
  d       : 前景掩膜调试窗  r : 计数复位
  s       : 保存当前参数   空格: 暂停/继续
"""
import argparse
import time

import cv2
import numpy as np

import osd
from calibration import Calibrator
from config import Config, CONFIG_PATH, default_line
from counter import LineCounter, ExitCounter
from detector import BallDetector
from tracker import Tracker


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
    """按“外接优先 -> 内置回退”的顺序打开摄像头，并尽量配置 720p@60 MJPG。"""
    order = [cfg.backend]
    if cfg.backend.upper() != "MSMF":
        order.append("MSMF")
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
                    cap.set(cv2.CAP_PROP_AUTO_EXPOSURE, 0.25)  # 手动
                    cap.set(cv2.CAP_PROP_EXPOSURE, cfg.exposure)
                except Exception:
                    pass
            ok, frame = cap.read()
            if ok and frame is not None:
                aw = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
                ah = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
                af = float(cap.get(cv2.CAP_PROP_FPS))
                print("[camera] index=%d backend=%s opened  %dx%d @ %.1ffps"
                      % (index, be, aw, ah, af))
                return cap
            cap.release()
    return None


def measure_camera_fps(cap, seconds=1.0):
    """实测摄像头真实帧率(读帧计时)，用于给录制视频打正确的 fps 标签。"""
    for _ in range(5):
        cap.read()
    t0 = time.time()
    n = 0
    while time.time() - t0 < seconds:
        ok, _ = cap.read()
        if ok:
            n += 1
    dt = time.time() - t0
    return n / dt if dt > 0 else 0.0


class CameraThread(object):
    """后台持续抓帧，只保留最新一帧，避免处理慢导致缓冲积压(降低延迟)。"""

    def __init__(self, cap):
        import threading
        self.cap = cap
        self.lock = threading.Lock()
        self.frame = None
        self.running = True
        self.ok = True
        self.t = threading.Thread(target=self._run, daemon=True)
        self.t.start()

    def _run(self):
        while self.running:
            ok, f = self.cap.read()
            if not ok or f is None:
                self.ok = False
                time.sleep(0.003)
                continue
            self.ok = True
            with self.lock:
                self.frame = f

    def read(self):
        with self.lock:
            return None if self.frame is None else self.frame.copy()

    def stop(self):
        self.running = False
        try:
            self.t.join(timeout=1.0)
        except Exception:
            pass


# ======================================================================
# 辅助
# ======================================================================
def build_roi_mask(cfg, proc_w, proc_h):
    if not cfg.roi:
        return None
    mask = np.zeros((proc_h, proc_w), np.uint8)
    x, y, w, h = cfg.roi
    x = int(x * cfg.proc_scale)
    y = int(y * cfg.proc_scale)
    w = int(w * cfg.proc_scale)
    h = int(h * cfg.proc_scale)
    x = max(0, min(proc_w - 1, x))
    y = max(0, min(proc_h - 1, y))
    w = max(1, min(proc_w - x, w))
    h = max(1, min(proc_h - y, h))
    mask[y:y + h, x:x + w] = 255
    return mask


def build_counter(cfg, frame_w, frame_h):
    if cfg.count_mode == "exit":
        return ExitCounter(cfg), None
    line = cfg.line if (cfg.line and len(cfg.line) == 2) else \
        default_line(cfg.direction, frame_w, frame_h)
    p1 = [line[0][0] * cfg.proc_scale, line[0][1] * cfg.proc_scale]
    p2 = [line[1][0] * cfg.proc_scale, line[1][1] * cfg.proc_scale]
    return LineCounter(p1, p2, cfg.direction, cfg), line


# ======================================================================
# 主流程
# ======================================================================
def main():
    ap = argparse.ArgumentParser(description="钢珠跟踪与计数 (传统 CV)")
    ap.add_argument("--camera", type=int, default=None, help="摄像头序号")
    ap.add_argument("--video", type=str, default=None, help="离线视频文件")
    ap.add_argument("--output", type=str, default=None, help="保存结果视频")
    ap.add_argument("--no-display", action="store_true", help="不弹窗(自动测试)")
    ap.add_argument("--calibrate", action="store_true", help="启动即进入标定")
    ap.add_argument("--max-frames", type=int, default=0,
                    help="处理到指定帧数后自动退出(0=不限制，便于自动测试)")
    ap.add_argument("--ball-diam", type=float, default=None,
                    help="临时覆盖钢珠直径(全分辨率像素)，用于不同拍摄距离/速度")
    ap.add_argument("--area-tol", type=float, default=None,
                    help="临时覆盖面积容差(如 0.7)")
    ap.add_argument("--detector", choices=["motion", "hough"], default=None,
                    help="检测模式: motion(运动前景) / hough(霍夫圆,适合深色球+浅背景+相机平移)")
    ap.add_argument("--count-mode", choices=["line", "exit"], default=None,
                    help="计数模式: line(计数线穿越) / exit(按轨迹离开视野计数)")
    ap.add_argument("--unlock-exposure", action="store_true",
                    help="关闭手动曝光改用自动曝光(某些摄像头锁曝光会偏暗/发黑)")
    ap.add_argument("--config", type=str, default=CONFIG_PATH)
    args = ap.parse_args()

    cfg = Config().load(args.config)
    if args.camera is not None:
        cfg.cam_index = args.camera
    if args.unlock_exposure:
        cfg.lock_exposure = False
    if args.ball_diam is not None:
        cfg.ball_diam_px = args.ball_diam
    if args.area_tol is not None:
        cfg.area_tol = args.area_tol
    if args.detector is not None:
        cfg.detector_mode = args.detector
    if args.count_mode is not None:
        cfg.count_mode = args.count_mode

    # ------------------ 打开视频源 ------------------
    is_file = args.video is not None
    if is_file:
        cap = cv2.VideoCapture(args.video)
        if not cap.isOpened():
            print("[error] cannot open video:", args.video)
            return
        src_w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)) or cfg.frame_w
        src_h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT)) or cfg.frame_h
        src_fps = float(cap.get(cv2.CAP_PROP_FPS)) or 30.0
        src = "video"
    else:
        cap = open_camera(cfg)
        if cap is None:
            print("[error] no camera available (tried index %d / %d)"
                  % (cfg.cam_index, cfg.fallback_index))
            return
        src_w, src_h = cfg.frame_w, cfg.frame_h
        src_fps = float(cap.get(cv2.CAP_PROP_FPS)) or float(cfg.fps)
        if args.output:
            measured = measure_camera_fps(cap, seconds=1.0)
            if measured >= 5:
                print("[camera] measured fps = %.1f (tag used for recording)"
                      % measured)
                src_fps = measured
        src = "camera"

    grab = None if is_file else CameraThread(cap)

    # ------------------ 构建处理链 ------------------
    detector = BallDetector(cfg)
    tracker = Tracker(cfg)
    counter, line_full = build_counter(cfg, src_w, src_h)

    proc_w = int(src_w * cfg.proc_scale)
    proc_h = int(src_h * cfg.proc_scale)
    inv = 1.0 / cfg.proc_scale

    writer = None
    if args.output:
        fourcc = cv2.VideoWriter_fourcc(*"mp4v")
        writer = cv2.VideoWriter(args.output, fourcc, src_fps, (src_w, src_h))

    show = not args.no_display
    if show:
        cv2.namedWindow("ball_track", cv2.WINDOW_NORMAL)

    paused = False
    fps_t0 = time.time()
    fps_n = 0
    fps_val = 0.0
    proc_fps_val = 0.0
    proc_t0 = time.time()
    proc_n = 0

    # 启动即标定
    if args.calibrate:
        first = grab.read() if grab else None
        if first is None and is_file:
            ok, first = cap.read()
            if ok:
                cap.set(cv2.CAP_PROP_POS_FRAMES, 0)
        if first is not None:
            cal = Calibrator(cfg, first)
            if cal.run():
                cfg.save(args.config)
                detector.reset()
                counter, line_full = build_counter(cfg, src_w, src_h)

    print("[info] processing at %dx%d (scale=%.2f)" % (proc_w, proc_h,
                                                       cfg.proc_scale))

    frame_count = 0
    tracks = []
    while True:
        # ------------------ 取帧 ------------------
        if is_file:
            if not paused:
                ok, frame = cap.read()
                if not ok or frame is None:
                    break
            # 暂停时保持上一帧(frame 不变)
        else:
            frame = grab.read()
            if frame is None:
                time.sleep(0.005)
                continue

        if not paused:
            frame_count += 1

            # ------------------ 处理 ------------------
            proc = cv2.resize(frame, (proc_w, proc_h),
                              interpolation=cv2.INTER_AREA)
            roi_mask = build_roi_mask(cfg, proc_w, proc_h)

            t_proc = time.time()
            dets, fg_mask = detector.detect(proc, roi_mask)
            tracks = tracker.update(
                dets, cfg.direction if cfg.use_direction_filter else None)
            # 计数传入“全部轨迹”，以便记录出生侧、补偿确认前越线的情况
            counter.update(tracker.tracks)
            proc_n += 1
            if proc_n >= 15:
                proc_fps_val = proc_n / max(1e-6, time.time() - proc_t0)
                proc_t0 = time.time()
                proc_n = 0

        # ------------------ OSD ------------------
        vis = frame.copy()
        if cfg.draw_roi and cfg.roi:
            osd.draw_roi(vis, cfg.roi)
        if cfg.show_trail:
            for t in tracks:
                osd.draw_trail(vis, t, inv)
        for t in tracks:
            osd.draw_track(vis, t, inv)
        if line_full is not None:
            osd.draw_line(vis, line_full[0], line_full[1], cfg.direction, 1.0)
        osd.draw_count(vis, counter.count)
        osd.draw_status(vis, len(tracks), len(tracker.tracks))
        osd.draw_logo(vis)

        fps_n += 1
        if time.time() - fps_t0 >= 0.5:
            fps_val = fps_n / (time.time() - fps_t0)
            fps_t0 = time.time()
            fps_n = 0
        osd.draw_fps(vis, fps_val, proc_fps_val)

        if writer is not None:
            writer.write(vis)

        # ------------------ 显示 & 按键 ------------------
        if show:
            cv2.imshow("ball_track", vis)
            if cfg.show_debug:
                cv2.imshow("mask", fg_mask)
            k = cv2.waitKey(1) & 0xFF
            if k in (27, ord("q")):
                break
            elif k == ord("d"):
                cfg.show_debug = not cfg.show_debug
                if not cfg.show_debug:
                    try:
                        cv2.destroyWindow("mask")
                    except Exception:
                        pass
            elif k == ord("r"):
                counter.reset()
                tracker.reset()
                detector.reset()
            elif k == ord(" "):
                paused = not paused
            elif k == ord("s"):
                cfg.save(args.config)
                print("[info] config saved to", args.config)
            elif k == ord("c"):
                cal = Calibrator(cfg, frame)
                if cal.run():
                    cfg.save(args.config)
                    detector.reset()
                    tracker.reset()
                    counter, line_full = build_counter(cfg, src_w, src_h)

        if args.max_frames and frame_count >= args.max_frames:
            break

    # ------------------ 收尾 ------------------
    if writer is not None:
        writer.release()
    if grab is not None:
        grab.stop()
    cap.release()
    if show:
        cv2.destroyAllWindows()

    print("[result] frames=%d  count=%d  tracks_total=%d"
          % (frame_count, counter.count, tracker.next_id - 1))


if __name__ == "__main__":
    main()
