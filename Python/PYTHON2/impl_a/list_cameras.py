# -*- coding: utf-8 -*-
"""
list_cameras.py -- 探测本机可用摄像头序号 / 分辨率 / 帧率
============================================================
用法:
    python list_cameras.py
会依次尝试 0~5 号摄像头(DSHOW/MSMF 两种后端)，打印能打开的那一个及其实测
分辨率与帧率。把你真实的摄像头序号记下来，传给 main.py --camera N。
"""
import cv2


def probe(index, backend_name, backend):
    cap = cv2.VideoCapture(index, backend)
    if not cap.isOpened():
        cap.release()
        return None
    # 尽量配置成 1280x720@60 MJPG
    cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1280)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 720)
    cap.set(cv2.CAP_PROP_FPS, 60)
    cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
    ok, frame = cap.read()
    if not ok or frame is None:
        cap.release()
        return None
    w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    fps = float(cap.get(cv2.CAP_PROP_FPS))
    cap.release()
    return backend_name, w, h, fps


def main():
    print("正在探测摄像头序号 0~5 ...")
    found = []
    for idx in range(0, 6):
        got = None
        for name, flag in [("DSHOW", cv2.CAP_DSHOW),
                           ("MSMF", cv2.CAP_MSMF),
                           ("AUTO", cv2.CAP_ANY)]:
            r = probe(idx, name, flag)
            if r:
                got = r
                break
        if got:
            print("  index %d : 可用  backend=%s  %dx%d @ %.1ffps"
                  % (idx, got[0], got[1], got[2], got[3]))
            found.append(idx)
        else:
            print("  index %d : (无)" % idx)
    print("-" * 48)
    if found:
        print("建议命令:  python main.py --camera %d" % found[0])
    else:
        print("没找到摄像头：请检查是否被其它程序占用(相机/微信/腾讯会议等)或未授权。")


if __name__ == "__main__":
    main()
