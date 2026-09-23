# 贡献指南

## 分支模型

| 分支 | 用途 |
| --- | --- |
| `main` | 稳定分支，受保护，仅通过 PR 合入 |
| `feature/<模块>` | 新功能，如 `feature/osd-overlay` |
| `fix/<问题>` | 缺陷修复，如 `fix/mipi-lane-align` |
| `docs/<主题>` | 仅文档改动 |

流程：从最新 `main` 切出分支 → 开发并自测（尽量上板验证）→ 推送 → 发起 PR → 评审通过后 Squash 合入 `main`。

## 提交规范（Conventional Commits）

```
<type>(<scope>): <简要描述>
```

常用 `type`：`feat`、`fix`、`docs`、`refactor`、`test`、`ci`、`chore`。

示例：
- `feat(isp): 新增自动白平衡增益收敛判断`
- `fix(hdmi): 修正 720p 时序下的像素时钟`
- `docs: 补充 lab_ex1 上板步骤`

## 禁止提交的内容

- 安装包、演示视频、常用软件目录（`ref/常用软件/`、`ref/UsbDriverTool/`）
- TD 编译/烧录产物：`*_Runs/`、`log/`、`impl/`、`*.db`、`*.bit`、`*.fs`、`*.bin` 等
- 授权文件 `*.lic`
- 任何密钥、口令、个人隐私信息

CI 会对 >5 MB 的文件直接报错；本地提交前可执行：

```powershell
git status
git diff --cached --stat
```

## 本地检查

```powershell
# 渲染 Verilog 语法检查（需 iverilog，可选）
powershell -ExecutionPolicy Bypass -File tools/lint.ps1 -Paths work
```

## PR 检查清单

发起 PR 时请填写模板中的：改动说明、验证方式（是否上板 / 综合结果）、是否新增 IP。
