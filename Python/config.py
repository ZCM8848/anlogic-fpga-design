# -*- coding: utf-8 -*-
"""
config.py -- 全局参数集中配置
============================================================
所有可调参数都放在这里，便于“现场调参”，也便于后续 FPGA 移植时逐项对照。
保存/加载使用同目录下的 config.json。

FPGA 对照提示：本文件里的物理量（ROI、计数线、方向、直径门限等）
最终都会变成硬件里的寄存器/比较器常量。
"""
import json
import os

_HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(_HERE, "config.json")


class Config(object):
    """可序列化的配置对象。属性名刻意保持简短、扁平，方便 json 读写。"""

    def __init__(self):
        # ============================ 摄像头 ============================
        self.cam_index = 1          # 优先外接 SC520CS(USB)；打不开自动回退
        self.fallback_index = 0     # 笔记本内置摄像头
        self.frame_w = 1280         # 输出分辨率 1280x720
        self.frame_h = 720
        self.fps = 60               # 目标 60fps
        self.fourcc = "MJPG"        # 720p@60 走 USB 建议 MJPG 压缩
        self.backend = "DSHOW"      # DSHOW / MSMF / AUTO
        self.lock_exposure = True   # 锁定曝光，避免画面亮度“呼吸”
        self.exposure = -6.0        # 锁定曝光时的曝光值(依驱动而定, 可调)

        # ============================ 处理分辨率 ============================
        self.proc_scale = 0.5       # 检测在 640x360 上做，显示仍用 1280x720

        # ============ ROI / 计数线 / 方向（全部用“全分辨率”坐标）============
        self.roi = None             # [x, y, w, h]，None = 全画面
        self.line = None            # [[x1,y1],[x2,y2]]，None = 自动取画面中线
        self.direction = [1, 0]     # 期望运动方向(单位向量)，默认“向右滚入/滚出”

        # ============================ 钢珠尺寸 ============================
        self.ball_diam_px = 80.0    # 钢珠直径(全分辨率像素)，标定测量后写入
        self.auto_diam = False      # 自动估计直径(慎用:易被拖影/合并块带偏;建议标定测量)
        self.max_ball_diam_frac = 0.10  # 自动估计时的最大直径(占画面宽比例)，排除人手等大物体
        self.min_diam_floor_px = 15.0   # 自动估计时的最小直径，排除噪声小点
        self.area_tol = 0.6         # 面积容差 ±60%（抗运动拖影/透视形变）
        self.min_circularity = 0.35 # 圆度门限 4πA/P²，越接近1越圆(运动模糊时放宽)
        self.min_fill = 0.45        # 外接矩形填充率，剔除细长/不规则块

        # ============================ 颜色门(金属球=低饱和) ============================
        self.use_color_gate = True  # 剔除人手/彩色运动物体
        self.max_sat = 90           # HSV 饱和度上限(0-255)，超过则判为非金属

        # ============================ 运动检测 ============================
        self.use_mog2 = True            # 背景建模(抗缓慢光照变化)
        self.use_frame_diff = False     # 帧差法(对有纹理背景噪声大, 默认关; 需要时再开)
        self.bg_history = 400
        self.var_threshold = 26
        self.detect_shadows = False     # MOG2 阴影检测(本场景关掉更干净)
        self.diff_threshold = 20

        # ============================ 光照归一化 ============================
        self.use_illum_norm = True  # 灰度 / 大核模糊，抑制光照不均
        self.illum_sigma = 25
        self.use_clahe = False      # 局部对比度增强(可选, FPGA 上较费资源)
        self.clahe_clip = 2.0

        # ============================ 形态学 ============================
        self.morph_open = 5
        self.morph_close = 9
        self.destreak = True        # 竖向开运算，去掉水平细条(高对比边界产生的伪影)
        self.max_aspect = 2.5       # 长宽比上限，剔除细长条带

        # ============================ 检测模式 ============================
        # "motion": 运动前景为主(默认，适合背景静止、球与背景对比一般的场景)
        # "hough" : 霍夫圆+暗度校验(适合“深色球在浅色背景、相机可能平移、球快/重叠”的场景)
        self.detector_mode = "motion"
        # 计数模式: "line"=计数线穿越; "exit"=按“已确认轨迹离开视野”计数(相机平移时更稳)
        self.count_mode = "line"

        # ---- hough 模式参数(处理分辨率坐标, proc_scale=0.5 时适用) ----
        self.hough_dp = 1.2
        self.hough_min_dist = 34
        self.hough_param1 = 130
        self.hough_param2 = 24
        self.hough_min_radius = 20
        self.hough_max_radius = 36
        self.hough_dark_offset = 20     # 暗块阈值 = 128 - offset
        self.hough_dark_mean = 122      # 圆内平均灰度上限(比背景暗)
        self.hough_dark_frac = 0.55     # 圆内“暗像素”占比下限

        # ============================ 跟踪 ============================
        self.max_gate = 2.5         # 关联门限 = max_gate × 半径
        self.min_hits = 3           # 连续命中多少帧后确认为真实目标
        self.max_coast = 8          # 目标丢失后最多预测补位多少帧(保持 ID)
        self.vel_ema = 0.5          # 速度指数平滑系数
        self.use_direction_filter = True  # 用“单方向”约束剔除反向运动干扰
        self.speed_eps = 0.5        # 判定速度大小的阈值(像素/帧)
        self.warmup_frames = 15     # 背景模型冷启动帧数，前若干帧不输出检测

        # ============================ 显示 ============================
        self.show_debug = False     # 显示前景掩膜调试窗
        self.draw_roi = True
        self.show_trail = False     # 是否画运动轨迹尾巴
        self.trail_len = 20

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
        except Exception as e:  # 配置损坏时不影响启动
            print("[config] load failed:", e)
        return self


def default_line(direction, w, h):
    """根据运动方向，给出过画面中心、且与之垂直的默认计数线。"""
    cx, cy = w * 0.5, h * 0.5
    dx, dy = direction
    if abs(dx) >= abs(dy):
        # 水平运动 -> 竖直线
        return [[cx, 0], [cx, h]]
    else:
        # 垂直运动 -> 水平线
        return [[0, cy], [w, cy]]
