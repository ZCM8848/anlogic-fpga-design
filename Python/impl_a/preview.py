# -*- coding: utf-8 -*-
"""
preview.py -- 纯摄像头实时预览（不跑跟踪算法）
============================================================
只打开摄像头并把实时画面显示出来，用于确认机位、对焦、曝光、构图。
按 q 或 ESC 退出；按 s 存一张快照。

用法:
  python preview.py                 # 默认序号 1
  python preview.py --camera 0
  python preview.py --camera 1 --unlock-exposure   # 画面偏暗时用自动曝光
"""
import argparse
import time

import cv2

from main import open_camera, measure_camera_fps
from config import Config


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--camera", type=int, default=None)
    ap.add_argument("--unlock-exposure", action="store_true")
    args = ap.parse_args()

    cfg = Config().load()
    if args.camera is not None:
        cfg.cam_index = args.camera
    if args.unlock_exposure:
        cfg.lock_exposure = False

    cap = open_camera(cfg)
    if cap is None:
        print("[error] 摄像头打不开：是否被其它程序占用?")
        return

    real_fps = measure_camera_fps(cap, seconds=1.0)
    w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    print("[preview] %dx%d  实测 %.1f fps   (按 q 退出, s 存快照)"
          % (w, h, real_fps))

    win = "camera preview  (q=quit, s=snapshot)"
    cv2.namedWindow(win, cv2.WINDOW_NORMAL)

    fps_t0 = time.time()
    n = 0
    fps = 0.0
    snap_i = 0
    while True:
        ok, frame = cap.read()
        if not ok or frame is None:
            continue
        n += 1
        if time.time() - fps_t0 >= 0.5:
            fps = n / (time.time() - fps_t0)
            fps_t0 = time.time()
            n = 0
        info = "%dx%d  %.1f fps" % (frame.shape[1], frame.shape[0], fps)
        cv2.putText(frame, info, (20, 40), cv2.FONT_HERSHEY_SIMPLEX,
                    1.0, (0, 0, 0), 5, cv2.LINE_AA)
        cv2.putText(frame, info, (20, 40), cv2.FONT_HERSHEY_SIMPLEX,
                    1.0, (0, 255, 255), 2, cv2.LINE_AA)
        cv2.imshow(win, frame)
        k = cv2.waitKey(1) & 0xFF
        if k in (27, ord("q")):
            break
        elif k == ord("s"):
            fn = "snapshot_%02d.png" % snap_i
            cv2.imwrite(fn, frame)
            snap_i += 1
            print("[preview] saved", fn)

    cap.release()
    cv2.destroyAllWindows()


if __name__ == "__main__":
    main()
