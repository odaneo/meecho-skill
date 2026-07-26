# Meecho 本地开发工具

本目录只用于开发、验证和本地安装调试，不会随 Meecho Plugin 安装，也不会
参与普通用户的 `build`、`update`、写作或润色。

普通用户只需要 Codex 和 Meecho Plugin，不需要运行本脚本，也不需要安装
Word、LibreOffice、Python、Java、Node.js 或 Meecho 自定义运行时。

## 命令

从仓库根目录运行：

```powershell
pwsh .\tools\dev\meecho-dev.ps1 doctor
pwsh .\tools\dev\meecho-dev.ps1 validate
pwsh .\tools\dev\meecho-dev.ps1 reinstall
pwsh .\tools\dev\meecho-dev.ps1 smoke
```

### `doctor`

检查 PowerShell、Git、Codex CLI、仓库 Plugin 契约，以及 `reinstall` 所需的
开发 Python 和官方 Plugin cachebuster 工具。这里只检查开发机，不代表普通
用户需要这些开发依赖。

### `validate`

运行 `evals/contracts/Test-*.ps1` 中的全部静态契约检查。它检查 Plugin
结构、调用声明、档案 schema、合成语料和 DOCX fixture 的可验证属性，不评价
任何文字的风格。

该命令不会启动 Codex，不会执行 Meecho Skill，也不能证明大模型会遵守
Markdown 指令。实际客户端行为由任务 7 的人工端到端验收负责。

### `reinstall`

按官方本地 Plugin 更新流程执行三步：

1. 用 `plugin-creator` 的 `update_plugin_cachebuster.py` 更新 Plugin 版本后缀。
2. 用 `codex plugin marketplace add <仓库根目录> --json` 注册或确认本地
   marketplace。
3. 用 `codex plugin add meecho@meecho --json` 重装 Plugin。

该命令会修改 `plugins/meecho/.codex-plugin/plugin.json` 的版本字段。重装后
应新建 Codex 任务，让新的任务加载更新后的 Skill。

### `smoke`

读取 `codex plugin list --json`，确认 `meecho@meecho` 已安装并启用。它不会
调用 Meecho Skill，不会读取 `%USERPROFILE%\.meecho\`，也不会读取 DOCX。
真正的 `$meecho:meecho build` 与 DOCX 宿主读取属于任务 7。

## 日志

每次运行都会在 `evals/logs/dev/<UTC 时间>-<命令>/` 保存：

- `command.txt`：终端输出；
- `result.json`：命令、状态、时间和日志路径。

`evals/logs/` 已被 Git 忽略，日志只留在本机。
