# Python 原型 — 钢珠跟踪与计数

本目录包含两套独立的 PC 端 OpenCV 实现原型，分别置于各自子目录，互不冲突。

| 目录 | 说明 | 入口 |
|------|------|------|
| `impl_a/` | 传统 CV 流水线（MOG2/霍夫圆 + 多目标跟踪 + 计数 + OSD） | `cd impl_a && python main.py` |
| `impl_b/` | （待提交） | — |

## 共享依赖

两套实现均基于 Python + OpenCV，共享同一份依赖清单：

```powershell
pip install -r requirements.txt
```

## 各自文档

详细的使用说明、参数表、调参指南请参阅各子目录下的 `README.md`。
