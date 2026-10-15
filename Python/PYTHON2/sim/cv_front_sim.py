# -*- coding: utf-8 -*-
"""
cv_front_sim.py -- cv_front_top 的逐拍行为级模型 + 与 impl_hw 对拍
================================================================
本机无 iverilog 时用 Python 复刻 RTL 的定点算术，验证：
  1) cv_gray     : Y = (77R+150G+29B)>>8        与 impl_hw.to_gray 逐点一致
  2) cv_norm_bg  : 块均值(16x16) / 倒数 LUT 归一化 / IIR(>>5) / 阈值 / 预热
                  其中 块均值 与 impl_hw._block_mean 一致；IIR 步进 = 8/256
  3) cv_morph3x3 : 3x3 腐蚀(AND)/膨胀(OR)

说明：RTL 的块域取值用**最近邻**（impl_hw 用双线性），故整链输出不会逐点相等，
      但每一步的定点运算都与 RTL 一致，可用于回归。

运行： python cv_front_sim.py
"""
import os
import sys

import numpy as np

_HERE = os.path.dirname(os.path.abspath(__file__))
_HW = os.path.abspath(os.path.join(_HERE, "..", "..", "..", "..", "Python", "impl_hw"))
if os.path.isdir(_HW):
    sys.path.insert(0, _HW)

RECIP_Q16 = [0] * 256
for _i in range(1, 256):
    RECIP_Q16[_i] = (1 << 16) // _i


# ---------------------------------------------------------------- RTL 模型
def rtl_gray(rgb):
    r = rgb[:, :, 0].astype(np.int64)
    g = rgb[:, :, 1].astype(np.int64)
    b = rgb[:, :, 2].astype(np.int64)
    return (77 * r + 150 * g + 29 * b) >> 8


class NormBgSim(object):
    """cv_norm_bg 的逐像素/逐帧行为级模型（跨帧保持 sp/bg/frm）。"""

    def __init__(self, BW, BH, blk=16, thresh=26, alpha_sh=5, target=128, warm=2):
        self.BW, self.BH, self.blk = BW, BH, blk
        self.thresh, self.alpha_sh, self.target, self.warm = thresh, alpha_sh, target, warm
        self.sp = np.zeros(BW * BH, np.int64)
        self.bg = np.zeros(BW * BH, np.int64)
        self.frm = 0

    def step(self, y):
        H, W = y.shape
        norm = np.zeros((H, W), np.uint8)
        mask = np.zeros((H, W), np.uint8)
        warm = (self.frm < self.warm)
        for by in range(self.BH):
            for bx in range(self.BW):
                addr = by * self.BW + bx
                sp_old = int(self.sp[addr])
                bg_old = int(self.bg[addr])
                den = sp_old if sp_old > 0 else 1
                acc_y = 0
                acc_n = 0
                for yy in range(by * self.blk, by * self.blk + self.blk):
                    for xx in range(bx * self.blk, bx * self.blk + self.blk):
                        v = int(y[yy, xx])
                        n = (v * self.target * RECIP_Q16[den]) >> 16
                        if n > 255:
                            n = 255
                        norm[yy, xx] = n
                        mask[yy, xx] = 0 if warm else (1 if abs(n - bg_old) > self.thresh else 0)
                        acc_y += v
                        acc_n += n
                self.sp[addr] = acc_y >> 8
                mean_norm = acc_n >> 8
                if warm:
                    self.bg[addr] = mean_norm
                else:
                    self.bg[addr] = bg_old + ((mean_norm - bg_old) >> self.alpha_sh)
        self.frm += 1
        return norm, mask


def rtl_erode3(m):
    pad = np.pad(m, 1, constant_values=1)
    e = m.astype(np.uint8).copy()
    for dy in range(3):
        for dx in range(3):
            e &= pad[dy:dy + m.shape[0], dx:dx + m.shape[1]]
    return e


def rtl_dilate3(m):
    pad = np.pad(m, 1, constant_values=0)
    d = m.astype(np.uint8).copy()
    for dy in range(3):
        for dx in range(3):
            d |= pad[dy:dy + m.shape[0], dx:dx + m.shape[1]]
    return d


# ---------------------------------------------------------------- 合成帧
def synth(n=8, w=640, h=368):
    import cv2
    grad = np.linspace(0, 40, w).astype(np.uint8)[None, :, None]
    for f in range(n):
        img = (np.full((h, w, 3), 60, np.uint8).astype(np.int16) + grad).clip(0, 255).astype(np.uint8)
        cx = 40 + f * 40
        cv2.circle(img, (cx, 180), 30, (215, 215, 215), -1)
        yield img


def main():
    w, h = 640, 368
    BW, BH = w // 16, h // 16
    frames = list(synth(n=8, w=w, h=h))

    # 1) 灰度对拍
    try:
        from hw_ops import to_gray, _block_mean
        from hw_config import HWConfig
        cfg = HWConfig()
        ok = np.array_equal(rtl_gray(frames[0]), to_gray(frames[0], cfg).astype(np.int64))
        print("[gray]   rtl vs impl_hw.to_gray           :", "PASS" if ok else "FAIL")
        bm_rtl = np.array([[(rtl_gray(frames[0])[by * 16:by * 16 + 16, bx * 16:bx * 16 + 16].sum() >> 8)
                            for bx in range(BW)] for by in range(BH)])
        bm_hw = _block_mean(rtl_gray(frames[0]).astype(np.uint8), 16)
        print("[block]  rtl vs impl_hw._block_mean       :",
              "PASS" if np.array_equal(bm_rtl, bm_hw) else "FAIL")
    except Exception as e:
        print("[gray/block] 跳过 impl_hw 对拍:", e)

    # 2) 整链（跨帧）
    sim = NormBgSim(BW, BH)
    print("[norm_bg] 逐帧前景像素数（预热 2 帧后应只剩运动目标）:")
    for i, fr in enumerate(frames):
        norm, mask = sim.step(rtl_gray(fr).astype(np.uint8))
        m_open = rtl_dilate3(rtl_erode3(mask))
        print("  frame %d: raw=%6d  open=%6d  bg_mean=%.1f"
              % (i, int(mask.sum()), int(m_open.sum()), float(sim.bg.mean())))
    print("[done] 行为级模型运行完成。")


if __name__ == "__main__":
    main()
