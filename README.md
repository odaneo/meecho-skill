# Meecho

Meecho 是一个供 Codex 使用的本地优先写作声音 Plugin。它根据用户主动选择的
作品提炼可追溯的声音证据，并在用户明确调用时辅助写作或润色。

Meecho 不训练、微调或修改大模型。项目当前也不会在用户最终盲评完成前宣称
风格模仿有效。

## 它是什么

- 用户安装的是一个 **Plugin**，不是项目模板，也不是需要手动复制的第二个
  Skill。
- Plugin 内只有一个 Skill，规范调用名是 `$meecho:meecho`。
- 私人声音档案保存在当前 Windows 用户的
  `%USERPROFILE%\.meecho\`，可供其他项目中的 Meecho 显式调用。
- 普通写作和润色只在聊天中返回正文，不创建 `drafts` 文件。
- Plugin 没有 Meecho 自定义运行时，也没有需要常驻的本地服务。

## 普通用户需要什么

- 支持 Plugin 的 Codex Windows 客户端。
- 用于从 GitHub 获取本仓库的 Git 或 GitHub Desktop。
- 一篇或多篇有效、未加密的 `.docx` 目标作品。

普通用户不需要安装 Word、LibreOffice、Python、Java、Node.js 或文档转换
服务。V1 不支持旧 `.doc`、宏启用 `.docm`、加密或损坏的 `.docx`，也不负责
格式转换。

## 从 GitHub 安装

当前 GitHub 版本通过仓库内的本地 marketplace 安装，不需要 Codex CLI。

1. 克隆本仓库：

   ```powershell
   git clone https://github.com/odaneo/meecho-skill.git
   ```

2. 在 Codex Windows 客户端中打开克隆后的 `meecho-skill` 文件夹。
3. 重新启动 Codex 客户端，让它发现
   `.agents/plugins/marketplace.json`。
4. 打开客户端的 **Plugins** 页面，选择 **Meecho** 来源并安装
   **Meecho**。
5. 新建一个任务，通过技能选择器选择 Meecho，或者输入：

   ```text
   $meecho:meecho 你能做什么？
   ```

安装完成后，Codex 从自己的 Plugin 缓存加载 Meecho。仓库中的 `tools/dev`、
`evals` 和 `docs` 不属于 Plugin，不会随安装进入 Plugin 缓存。

## 建立声音档案

准备好目标作品后，在 Codex 中明确调用：

```text
$meecho:meecho 使用我选择的 DOCX 作品建立一个名为 my-voice 的声音档案。
```

Meecho 会执行以下流程：

1. 通过 Codex 宿主已有的文档能力只读提取所选 `.docx` 的完整正文。
2. 先形成作品级观察，再归纳跨作品的稳定声音证据、反例和不确定项。
3. 展示准备写入的档案标识、来源范围和准确路径，供用户审阅。
4. 只有用户明确允许后，才把档案写入
   `%USERPROFILE%\.meecho\profiles\<profile-id>\`。

用于模仿的目标作品是必需的；对照作品是可选的。作品越少，Meecho 越会把
结论标记为不确定，不会把单篇题材特征冒充稳定声音。

## 写作与润色

在任意项目中显式调用同一个 Skill：

```text
$meecho:meecho 使用当前声音档案，写一篇关于雨夜车站的短文。
```

```text
$meecho:meecho 保留下面文字的事实和原意，按当前声音档案润色……
```

必须明确激活 Meecho，但不必输入 `build`、`write` 或 `revise` 等英文操作名。
只要中文请求的意思明确，Meecho 就会判断应该执行哪一种操作；无法确定时才会
简短询问。英文操作名只是可选的精确写法。

Meecho 内部区分八种操作：

| 操作 | 用途 |
| --- | --- |
| `build` | 从用户选择的 `.docx` 首次建立档案 |
| `write` | 使用活动档案创作新文本 |
| `revise` | 保留事实和原意并润色文本 |
| `update` | 用新选择的 `.docx` 更新档案 |
| `remember` | 保存用户明确提出的偏好或事实纠正 |
| `status` | 查看活动档案、版本和来源数量 |
| `export` | 经许可把档案复制到指定位置 |
| `delete` | 经二次确认删除指定档案 |

`status`、`write` 和 `revise` 是指 Meecho 会先说明准确路径并请求许可。
写作或润色不会暗中修改声音档案。读操作。`build`、`update`、`remember`、
`export` 和 `delete` 涉及文件变化，

## 文档处理、隐私与模型边界

Skill 的流程由 Codex 执行。大模型负责分析声音证据；Codex 宿主提供的文档和
文件工具负责读取 `.docx`，并且只在用户批准后写入档案。

“本地保存”不等于“离线推理”。声音档案保存在本机，但用户主动选择的作品
正文会进入 Codex 模型上下文，以便大模型分析。Meecho 不会把原始文档复制到
GitHub、Plugin 缓存、当前项目或声音档案目录，也不会创建文本转换副本。

## 开发验证与 CI

开发者可以在仓库根目录运行：

```powershell
pwsh ./tools/dev/meecho-dev.ps1 validate
```

该命令运行 `evals/functional/Test-*.ps1` 中的全部客观功能测试，并把本地日志
保存到被 Git 忽略的 `evals/logs/dev/`。

GitHub Actions 使用 `.github/workflows/validate.yml` 在代码推送、Pull
Request 和手动触发时执行同一条验证命令。CI 只检查 Plugin／Skill 结构、
必需文件、运行时和私人文件边界、合成 profile schema 以及 PowerShell 功能
测试；它不判断文字“像不像”，也不生成风格分数。
