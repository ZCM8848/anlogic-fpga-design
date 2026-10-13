# -*- coding: utf-8 -*-
"""
hw_config.py -- 硬件可实现版参数（全部整数 / 定点常量）
============================================================
本文件是 impl_a/config.py 的"硬件化"对应版本：**没有任何浮点运算**，
每一项都直接映射为 RTL 里的一组寄存器或比较器常量（注释里给出对应关系）。

命名约定与 work/camera_hdmi_720p/rtl/cv/cv_top.v 对齐：
  * 增益/系数一律用 Q 格式（_Q8 = x256，_Q10 = x1024）；
  * 计数/坐标用整数，内部定点统一 Q8.8；
  * 阈值/门限用整数比较。
"""


class HWConfig(object):
    def __init__(self):
        # ============================ 分辨率 / 缩放 ============================
        # 处理分辨率 = 输入 * num/den。num=1,den=2 -> 640x360（与 impl_a.proc_scale=0.5 等价）
        self.scale_num = 1
        self.scale_den = 2

        # ============================ 灰度（BT.601 定点）============================
        # Y = (77R + 150G + 29B) >> 8  ->  3 乘 + 1 加树 + 移位
        self.GY_R = 77
        self.GY_G = 150
        self.GY_B = 29

        # ============================ 光照归一化 ============================
        # norm = gray * TARGET / max(bg,1)，bg = 块均值(block) 双线性放大
        # 硬件：块均值降采样缓存(80x45) + 双线性插值 + 倒数 LUT + 1 乘法器
        self.use_illum_norm = True
        self.illum_block = 16        # 背景估计的块大小（1/16 降采样）
        self.norm_target = 128       # 归一化目标

        # ============================ IIR 背景（替代 MOG2）============================
        # bg = bg + ((cur - bg) * alpha_q8) >> 8   -> 1 乘 + 1 加 + 1 移位
        # 帧级缓存走 DDR2（不从片内 ERAM 要空间）
        self.bg_alpha_q8 = 8         # alpha = 8/256 = 1/32
        self.fg_thresh = 26          # |cur-bg| > 阈值 -> 前景
        self.warmup_frames = 15      # 冷启动帧数（前若干帧不出检测）

        # ============================ ROI 掩膜 ============================
        self.roi = None              # [x,y,w,h] 全分辨率坐标；None = 全画面

        # ============================ 形态学 ============================
        # 开/闭 = 窗口 min/max（移位寄存器窗口 + 比较树）
        self.open_k = 5              # 5x5 椭圆
        self.close_k = 9             # 9x9 椭圆
        self.destreak = True         # 竖向开运算去水平细条
        self.destreak_len = 14       # 竖窗长度（列方向）

        # ============================ 形状 / 尺度筛选 ============================
        self.ball_diam_px = 80.0     # 钢珠直径（全分辨率像素，标定得到）
        self.area_tol_q8 = 154       # 面积容差 ±0.6（Q8: 0.6*256≈154）
        self.min_circ_q10 = 358      # 圆度门限 0.35（Q10: 0.35*1024≈358）
        self.min_fill_q8 = 115       # 填充率门限 0.45（Q8）
        self.max_aspect_q8 = 640     # 长宽比上限 2.5（Q8）
        self.min_area_px = 6         # 绝对面积下限（去噪点）
        self.auto_diam = False       # 自动估直径（用直方图分位，默认关）
        self.max_ball_diam_frac_q8 = 26   # 自动估计上限 0.10*画面宽
        self.min_diam_floor_px = 15

        # ============================ 连通域 ============================
        self.connectivity = 8        # 8 连通（与 cv2.findContours / cv_top 一致）

        # ============================ 颜色门（金属球=低饱和）============================
        # S = (max-min)*255/max -> 3 比较 + 1 减 + 倒数 LUT + 1 乘
        self.use_color_gate = True
        self.max_sat = 90

        # ============================ 跟踪（对齐 cv_top.v）============================
        self.max_tracks = 16         # 轨迹表深度（cv_top 用 8）
        self.max_gate_q8 = 640       # 关联门限 = 2.5 x 半径（Q8）
        self.min_hits = 3            # 连续命中确认
        self.max_coast = 8           # 丢失后最多补位帧数
        self.vel_ema_q8 = 128        # 速度 EMA 系数 0.5（Q8）
        self.speed_eps_q8 = 128      # 速度阈值 0.5 像素/帧（Q8）
        self.use_direction_filter = True

        # ============================ 计数 ============================
        self.count_mode = "line"     # "line" 计数线穿越 / "exit" 离开视野
        self.line = None             # [[x1,y1],[x2,y2]] 全分辨率；None=过中心自动线
        self.direction = (1, 0)      # 期望运动方向（整数向量，非必须归一）

    # 便于与 impl_a 的 config.json 对照（只导出硬件相关的常量）
    def to_dict(self):
        return {k: v for k, v in vars(self).items()
                if not k.startswith("_")}
