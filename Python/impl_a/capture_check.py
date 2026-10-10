# -*- coding: utf-8 -*-
"""
capture_check.py -- 摄像头采集合规性自检 + 录制
============================================================
作用：
  1) 按 1280x720@60 MJPG 打开摄像头
  2) 实测“真实帧率”(读帧计时)，而不是只信 cap.get() 的返回值
  3) 判定是否满足赛题基准：分辨率 1280x720、帧率 ≥ 50fps
  4) 可选把这几秒录成 mp4，方便直接当作合规素材

用法:
  python capture_check.py                 # 用默认序号(1)自检 5 秒
  python capture_check.py --camera 0
  python capture_check.py --camera 0 --seconds 8 --output reco60.mp4
"""
import argparse
import time

import cv2


def open_cam(index):
    for name, flag in [("DSHOW", cv2.CAP_DSHOW),
                       ("MSMF", cv2.CAP_MSMF),
                       ("AUTO", cv2.CAP_ANY)]:
        cap = cv2.VideoCapture(index, flag)
        if not cap.isOpened():
            cap.release()
            continue
        # 关键：720p@60 必须走 MJPG，否则 USB 带宽不够会自动降到 30fps/YUY2
        cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
        cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1280)
        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 720)
        cap.set(cv2.CAP_PROP_FPS, 60)
        cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
        ok, f = cap.read()
        if ok and f is not None:
            print("[open] index=%d backend=%s" % (index, name))
            return cap
        cap.release()
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--camera", type=int, default=1)
    ap.add_argument("--seconds", type=float, default=5.0)
    ap.add_argument("--output", type=str, default=None)
    args = ap.parse_args()

    cap = open_cam(args.camera)
    if cap is None:
        print("[error] 摄像头 %d 打不开：是否被其它程序占用(相机/微信/腾讯会议)?"
              % args.camera)
        return

    w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    reported = float(cap.get(cv2.CAP_PROP_FPS))
    print("[cfg ] reported: %dx%d @ %.1ffps (仅供参考)" % (w, h, reported))

    # 预热，丢弃前若干帧
    for _ in range(10):
        cap.read()

    writer = None
    fourcc = cv2.VideoWriter_fourcc(*"mp4v")
    if args.output:
        writer = cv2.VideoWriter(args.output, fourcc, 60.0, (w, h))

    n = 0
    t0 = time.time()
    while time.time() - t0 < args.seconds:
        ok, f = cap.read()
        if not ok or f is None:
            continue
        n += 1
        if writer is not None:
            if f.shape[1] != w or f.shape[0] != h:
                f = cv2.resize(f, (w, h))
            writer.write(f)

    dt = time.time() - t0
    real_fps = n / max(dt, 1e-6)
    cap.release()
    if writer is not None:
        writer.release()

    print("[meas] 实测: %d 帧 / %.2fs = %.1f fps" % (n, dt, real_fps))
    ok_res = (w == 1280 and h == 720)
    ok_fps = real_fps >= 50.0
    print("=" * 48)
    print("resolution 1280x720 : %s" % ("PASS" if ok_res else "FAIL (%dx%d)" % (w, h)))
    print("frame rate >=50fps  : %s (%.1f)" % ("PASS" if ok_fps else "FAIL", real_fps))
    print("verdict             : %s" % ("[OK] meets 1280x720@60"
                                         if (ok_res and ok_fps) else
                                         "[NO] not compliant (see above)"))
    if args.output:
        print("saved: %s" % args.output)


if __name__ == "__main__":
    main()
