# work/ — 团队自研代码

本目录用于放置团队在示例工程（`ref/.../lab_ex1|2|3`）基础上开发的功能代码。

约定：

- 每个模块独立子目录，例如 `work/osd_overlay/`、`work/awb_tuning/`。
- 只提交源码、约束与工程文件（`.v/.sv/.vh/.al/.adc/.cst/.sdc` 等）。
- 不提交编译产物（`*_Runs/`、`log/`、`*.db/.bit/.fs/.bin` 等），已由 `.gitignore` 排除。
- 上板验证结果建议写入各模块子目录的 `README.md`。
