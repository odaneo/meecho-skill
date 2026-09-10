# Meecho

Meecho 从你提供的作品中提炼私人写作声音，用于创作、润色和维护多个声音档案。
它不训练或修改模型；声音档案保存在当前用户主目录的 `.meecho` 中。

## 安装位置

| 客户端 | Meecho 入口 |
|---|---|
| Codex | 作为原生 Plugin 安装；Windows 当前由 Codex 缓存在 `%USERPROFILE%\.codex\plugins\cache\meecho\meecho\<version>\` |
| OpenCode | `~/.config/opencode/skills/meecho` |
| 其他兼容 Agent Skills 的客户端 | `~/.agents/skills/meecho` |

OpenCode 和其他客户端的入口都链接到同一份公开源码：

```text
Windows: %USERPROFILE%\.local\share\meecho\plugins\meecho\skills\meecho\
POSIX:   $HOME/.local/share/meecho/plugins/meecho/skills/meecho/
```

不要链接 Codex Plugin 缓存，也不要复制整个 Skill 文件夹。

## 下载一次源码

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

## Codex

1. 用 Codex 打开刚才克隆的 `meecho` 文件夹并重启客户端。
2. 在 **Plugins** 页面，从 **Meecho** 来源安装 **Meecho**。
3. 新建任务，通过技能选择器选择 Meecho，或输入：

   ```text
   $meecho:meecho 你能做什么？
   ```

Codex 用户不需要创建下面的 OpenCode 或通用 Skill 链接。

## OpenCode

如果只需要 OpenCode，或只需要 Codex 与 OpenCode 并用，创建 OpenCode 自己的
全局入口。

Windows PowerShell：

```powershell
$SourceSkill = Join-Path $HOME '.local\share\meecho\plugins\meecho\skills\meecho'
$TargetParent = Join-Path $HOME '.config\opencode\skills'
$TargetSkill = Join-Path $TargetParent 'meecho'
New-Item -ItemType Directory -Path $TargetParent -Force | Out-Null
New-Item -ItemType Junction -Path $TargetSkill -Target $SourceSkill
```

macOS/Linux：

```sh
mkdir -p "$HOME/.config/opencode/skills"
ln -s "$HOME/.local/share/meecho/plugins/meecho/skills/meecho" \
  "$HOME/.config/opencode/skills/meecho"
```

安装位置是 `%USERPROFILE%\.config\opencode\skills\meecho\` 或
`$HOME/.config/opencode/skills/meecho/`。

## 其他兼容客户端

需要让多个兼容 Agent Skills 的客户端共用 Meecho 时，创建通用入口。OpenCode
也能读取这个入口，因此不要再创建上一节的 OpenCode 专用入口。

Windows PowerShell：

```powershell
$SourceSkill = Join-Path $HOME '.local\share\meecho\plugins\meecho\skills\meecho'
$TargetParent = Join-Path $HOME '.agents\skills'
$TargetSkill = Join-Path $TargetParent 'meecho'
New-Item -ItemType Directory -Path $TargetParent -Force | Out-Null
New-Item -ItemType Junction -Path $TargetSkill -Target $SourceSkill
```

macOS/Linux：

```sh
mkdir -p "$HOME/.agents/skills"
ln -s "$HOME/.local/share/meecho/plugins/meecho/skills/meecho" \
  "$HOME/.agents/skills/meecho"
```

安装位置是 `%USERPROFILE%\.agents\skills\meecho\` 或
`$HOME/.agents/skills/meecho/`。

如果同机还安装了 Codex Plugin，请看文末“为什么 Codex 出现两个 Meecho？”。

## 更新

Windows：

```powershell
git -C (Join-Path $HOME '.local\share\meecho') pull --ff-only
```

macOS/Linux：

```sh
git -C "$HOME/.local/share/meecho" pull --ff-only
```

更新后链接不用重建，只需重启正在使用 Meecho 的客户端。

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

### 创建 OpenCode 链接时提示 `meecho` 已存在怎么办？

确认目标是旧链接而不是存放文件的真实目录，然后删除旧链接并重新执行安装命令。
Windows PowerShell：

```powershell
Remove-Item -LiteralPath (Join-Path $HOME '.config\opencode\skills\meecho') -Force
```

macOS/Linux：

```sh
rm "$HOME/.config/opencode/skills/meecho"
```

### 为什么 Codex 出现两个 Meecho？

Codex Plugin 和 `~/.agents/skills/meecho` 通用入口会被分别发现。保留 Plugin，
并让 Codex 忽略通用入口。Windows PowerShell 先生成配置块：

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
OpenCode 如果使用通用入口，就不要再创建 OpenCode 专用入口。
