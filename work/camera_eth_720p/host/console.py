#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""console.py — 启动 Web 控制台（一键式录制/处理）

用法：
    python console.py                 # 自动找网卡 + 自动开浏览器
    python console.py --com COM4
    python console.py --no-browser
    python console.py --port 8770 --udp 4660

启动后浏览器打开 http://127.0.0.1:8770/
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from console_server import main

if __name__ == "__main__":
    sys.exit(main())
