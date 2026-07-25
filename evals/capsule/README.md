# Meecho 本地评测测试舱

这里的文件只服务于源码开发和行为评测，不进入最终 Meecho Plugin。测试舱在当前 Windows 用户下运行，不需要管理员权限、第二个 Windows 用户、Python runtime 或模型训练。

## 隔离边界

初始化器把持久状态放在仓库外：

```text
%LOCALAPPDATA%\MeechoDev\eval\
├── control\codex-home\
├── treatment\codex-home\
└── runs\<run-id>\<mode>\<case-id>\<scenario-id>\
    ├── user-home\
    ├── workspace\
    ├── state\
    └── temp\
```

control 与 treatment 各自共享一个隔离的 `CODEX_HOME`，但每个 mode／case／scenario 都有唯一的虚拟 home、工作区、临时目录和 `CODEX_SQLITE_HOME`。仓库内 `evals/logs/<run-id>/<mode>/<case-id>/<scenario-id>/` 只保存已被 Git 忽略的本地审计记录。

测试子进程先清空继承环境，再只注入系统启动所需变量及重写后的测试舱路径。父进程中的 `OPENAI_*`、名称含 `KEY`／`SECRET`／`TOKEN` 的变量、真实 `CODEX_HOME` 和真实 home 不会传入。认证固定存放在对应隔离 `CODEX_HOME` 的 file credential store；不得复制开发者真实认证文件。

`--ephemeral` 只阻止本次 exec 持久化 rollout，并不单独构成隔离。完整边界还依赖独立 `CODEX_HOME`、scenario-local SQLite state、虚拟 home、最小 permission profile、清洗环境、仓库外干净工作区和实际 read／allow／deny 检查。

## 初始化

使用 PowerShell 7.4 或更高版本：

```powershell
.\evals\scripts\Initialize-EvalCapsule.ps1 -Mode control
```

脚本只输出以下终态之一：

- `ready`：CLI、配置、路径、版本、隔离认证，以及 read／allow／deny 三个真实文件 canary 均通过。
- `AUTH_REQUIRED`：其余前置条件通过，但该隔离 `CODEX_HOME` 尚未登录。
- `BLOCKED_NOT_RUN`：CLI 无法启动、版本／配置／路径／权限能力不符合契约，或其他安全前置条件失败。

只有收到 `AUTH_REQUIRED` 时，才显式运行：

```powershell
.\evals\scripts\Initialize-EvalCapsule.ps1 -Mode control -Login
```

登录在清洗后的隔离子进程中进行。脚本不会要求调用者永久设置环境变量，也不会修改当前 PowerShell 的环境。任务 1 只需要 control；treatment 在后续安装 Meecho Plugin 时另行初始化。

认证可用时，初始化器依次创建三个 fresh preflight scenario：read 必须读到只读 marker 且无法写回，allow 必须借助唯一的 `--add-dir` 写入、读回并由 harness 清理，deny 必须读到 manifest 但管理写入失败且没有部分文件。每个 Codex 版本、能力、登录状态和 canary 子进程都有有界超时，并在对应 `StepLogRoot` 保存 stdout、stderr、退出码、时间戳、脱敏参数、环境变量名和 SHA-256；不保存环境变量值或认证内容。

初始化器不运行九个行为 case。正式基线由要求显式模型和 `high` reasoning 的基线入口执行；正式改进证据必须由配对入口背靠背创建 fresh control 与 treatment。

## 三种 permission mode

- `read`：工作区可写，虚拟 `~/.meecho` 只读，不额外开放 virtual home。
- `allow`：工作区可写，并只把当前 scenario 的 virtual home 作为额外 workspace root。
- `deny`：底层权限与 read 相同，但发送管理写请求，用来证明拒绝后安全停止且无部分文件。

自动化 `codex exec` 固定使用 `approval_policy="never"`，所以这些 scenario 证明的是三种确定权限状态，不是交互式审批弹窗。真实弹窗的允许／拒绝证据属于后续人工 checklist。

## 清理

只通过模块删除一个明确 run：

```powershell
Import-Module .\evals\scripts\EvalCapsule.psm1 -Force
Remove-MeechoEvalRun -RunId '<run-id>' -Confirm
```

删除器拒绝非法 run id、路径越界以及 run 树中的 symlink／junction／reparse point。它保留 control／treatment `CODEX_HOME` 和仓库内日志；清理登录状态必须走后续显式的开发工具流程。
