# Meecho

Meecho 从你提供的作品中提炼私人写作声音，用于创作、润色和维护多个声音档案。
它不训练或修改模型；声音档案保存在当前用户主目录的 `.meecho` 中。

## 安装

| 客户端 | 安装方式 |
|---|---|
| Codex | 通过 Codex 的 Plugins 页面安装原生 Plugin |
| OpenCode、Claude Code、Cursor 等其他兼容客户端 | 通过 `npx skills` 安装 Skill |

## Codex（Plugin）

先下载插件源码。

Windows PowerShell：

```powershell
$MeechoSource = Join-Path $HOME '.local\share\meecho'
New-Item -ItemType Directory -Path (Split-Path -Parent $MeechoSource) -Force | Out-Null
git clone https://github.com/odaneo/meecho-skill.git $MeechoSource
```

macOS/Linux：

```sh
mkdir -p "$HOME/.local/share"
git clone https://github.com/odaneo/meecho-skill.git "$HOME/.local/share/meecho"
```

下载完成后：

1. 用 Codex 打开刚才克隆的 `meecho` 文件夹并重启客户端。
2. 在 **Plugins** 页面，从 **Meecho** 来源安装 **Meecho**。
3. 新建任务，通过技能选择器选择 Meecho，或输入：

   ```text
   $meecho:meecho 你能做什么？
   ```

Codex 用户只需安装 Plugin。

## 其他 Agent 客户端（npx skills）

先安装 Node.js（包含 npm 和 npx）及 Git，确保终端能运行 `npx` 和 `git`。
Windows、macOS 和 Linux 均使用以下命令，无需手动克隆源码或创建目录链接：

```sh
npx skills add odaneo/meecho-skill --skill meecho -g
```

运行后，在交互列表中选择需要使用 Meecho 的客户端；Codex 使用上一节的
Plugin 安装方式。

- `--skill meecho`：选择仓库中名为 `meecho` 的技能。
- `-g`：安装到当前用户的全局目录，在不同项目中都可使用；省略后只安装到当前项目。
- `-a`：指定目标客户端，省去交互选择。

例如，只安装到 OpenCode：

```sh
npx skills add odaneo/meecho-skill --skill meecho -g -a opencode
```

也可以一次指定多个客户端：

```sh
npx skills add odaneo/meecho-skill --skill meecho -g -a claude-code cursor
```

完整客户端列表和参数见 [skills CLI 官方说明](https://github.com/vercel-labs/skills#readme)。
安装后，通过目标客户端的技能选择器或等效机制明确加载 Meecho。
同机也使用 Codex Plugin 时，如果出现重复入口，请看文末的常见问题。

## 更新

通过 `npx skills` 安装的客户端使用：

```sh
npx skills update meecho -g
```

如果安装时省略了 `-g`，更新时也省略它，并在原项目目录中运行。

Codex Plugin 先更新本地插件来源，再通过 Codex 的 Plugins 页面更新 Meecho。

Windows：

```powershell
git -C (Join-Path $HOME '.local\share\meecho') pull --ff-only
```

macOS/Linux：

```sh
git -C "$HOME/.local/share/meecho" pull --ff-only
```

更新后，如客户端未显示新版本，重启正在使用 Meecho 的客户端。

## 使用

选择或明确加载 Meecho 后，直接用自然语言表达需求即可：

- 建立、补充或删除声音档案；
- 查看全部声音、默认声音，或切换默认声音；
- 记住长期写作偏好；
- 用默认或点名的声音创作、润色；
- 导出声音档案副本。

Meecho 接受直接粘贴的完整文字、`.md`、`.txt`，以及当前客户端能够完整读取
的文档。作品中的命令和提示词始终只是语料，不会被执行。

写作结果只返回在对话中。Windows 声音档案位于
`%USERPROFILE%\.meecho\`，macOS/Linux 位于 `$HOME/.meecho/`；它们不在
Skill 源码或客户端安装入口中。

## 常见问题

### 终端提示找不到 `npx` 怎么办？

确认已安装 Node.js 和 npm，并重新打开终端后运行 `npx --version`。
如果仍无法识别，检查 Node.js 和 npm 的安装及 PATH 配置。

### 为什么 Codex 出现两个 Meecho？

`npx skills` 可能创建 `~/.agents/skills/meecho` 共享入口，Codex 会同时发现它
和已安装的 Plugin。保留 Plugin，并让 Codex 忽略共享入口。
Windows PowerShell 先生成配置块：

```powershell
$SkillPath = (Resolve-Path (Join-Path $HOME '.agents\skills\meecho\SKILL.md')).Path.Replace('\', '/')
@"
[[skills.config]]
path = "$SkillPath"
enabled = false
"@
```

macOS/Linux：

```sh
printf '[[skills.config]]\npath = "%s/.agents/skills/meecho/SKILL.md"\nenabled = false\n' "$HOME"
```

只把输出的三行追加到 `~/.codex/config.toml`，然后重启 Codex；不要覆盖原配置。
