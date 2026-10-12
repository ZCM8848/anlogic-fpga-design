# -*- coding: utf-8 -*-
"""
config.py -- 全局参数集中配置（映射 cv_top.v 的 parameter 段）
============================================================
本文件是「FPGA 黄金参考」的参数中心：每一项都对应
`work/camera_hdmi_720p/rtl/cv/cv_top.v` 里同名 parameter，
以保证 PC 端与 FPGA 端用**同一套参数**、得到**同一套结果**。

FPGA 对照：
  - 这些数值在 FPGA 上都是编译期常量（parameter）或运行期寄存器，
    改这里等价于改 cv_top.v 顶部 parameter 段后重新综合。
"""
import json
import os

_HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(_HERE, "config.json")


class Config(object):
    """可序列化配置。属性名尽量与 cv_top.v 的 parameter 名保持一致。"""

    def __init__(self):
        # ==================== 分辨率（与 FPGA 全分辨率一致，不降采样） ====================
        self.frame_w = 1280
        self.frame_h = 720

        # ==================== 检测（cv_top.v parameter） ====================
        self.mask_src = 1          # MASK_SRC : 1=Sobel 边缘环(默认) 0=亮阈值回退
        self.edge_thr = 80         # EDGE_THR : Sobel 幅值阈值
        self.bin_thr = 91          # BIN_THR  : 亮阈值回退值(mask_src=0 时)
        self.min_area = 20         # MIN_AREA : 边缘像素数下限
        self.max_area = 500        # MAX_AREA : 边缘像素数上限
        self.min_fill = 5          # MIN_FILL : 填充率下限(百分比, 边缘环空心->低填充)
        self.min_ratio = 60        # MIN_RATIO: 长短边比下限(百分比, 圆球 bbox 近正方形)
        self.edge_mg = 4           # EDGE_MG  : 贴边剔除 margin
        self.max_blobs = 8         # MAX_BLOBS: 最大检测/轨迹数
        self.max_runs = 1024       # MAX_RUNS : run 缓冲上限
        self.max_labels = 32       # MAX_LABELS: 最大标签数
        self.max_rpr = 32          # MAX_RPR  : 每行最多 run 数(CCL 行缓存)
        self.fbox_w = 2            # FBOX_W   : 框线宽
        self.mask_view = 1         # MASK_VIEW: 机器视角(二值掩膜)开关
        self.user_off = 0          # 运行期阈值偏置(K3/K4 对应 +-1, clamp 到 [-128,127])

        # ==================== 跟踪（cv_top.v parameter） ====================
        self.alpha_q = 160         # ALPHA_Q : α×256 ≈ 0.625（位置增益）
        self.beta_q = 48           # BETA_Q  : β×256 ≈ 0.1875（速度增益）
        self.gate = 80             # GATE    : 配对最大 Manhattan 距离
        self.miss_k = 8            # MISS_K  : 丢失几帧删除轨迹
        # 说明：FPGA 跟踪器无 min_hits 确认，新检测立即有效并分配 ID（4 位，回绕 0~f）。

        # ==================== 计数线（Phase C，FPGA 尚未实现，见 README 设计规格） ====================
        self.line = [1, 0, -640]   # 直线 a*x + b*y + c = 0；默认竖直线 x=640
        self.direction = [1, 0]    # 期望运动方向(单位向量)，默认向右滚入

        # ==================== I/O ====================
        self.cam_index = 1
        self.fallback_index = 0
        self.fps = 60
        self.fourcc = "MJPG"
        self.backend = "DSHOW"
        self.lock_exposure = True
        self.exposure = -6.0

        # ==================== 显示 ====================
        self.show_mask = False     # 独立掩膜调试窗
        self.show_fps = True
        self.draw_line = True      # 画出计数线

    # ------------------------------ json ------------------------------
    def to_dict(self):
        return {k: v for k, v in vars(self).items()}

    def save(self, path=CONFIG_PATH):
        with open(path, "w", encoding="utf-8") as f:
            json.dump(self.to_dict(), f, ensure_ascii=False, indent=2)
        return path

    def load(self, path=CONFIG_PATH):
        if not os.path.exists(path):
            return self
        try:
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)
            for k, v in data.items():
                if hasattr(self, k):
                    setattr(self, k, v)
        except Exception as e:  # 配置损坏不影响启动
            print("[config] load failed:", e)
        return self


def line_from_points(p1, p2):
    """由两点 (x1,y1),(x2,y2) 得到直线系数 a,b,c，满足 a*x + b*y + c = 0。"""
    x1, y1 = p1
    x2, y2 = p2
    a = y2 - y1
    b = x1 - x2
    c = x2 * y1 - x1 * y2
    return [a, b, c]
