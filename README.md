# Meecho

Meecho 是一个供 Codex 使用的私人写作声音 Plugin。它从你提供的作品中提炼
写作声音，用于创作、润色和维护多个声音档案。

它不训练或修改大模型。声音档案保存在本机，最终像不像由你判断。

## 安装

目前支持 Codex Windows 客户端，不需要 Codex CLI、Word、LibreOffice、Python、
Java 或 Node.js。

1. 克隆本仓库：

   ```powershell
   git clone https://github.com/odaneo/meecho-skill.git
   ```

2. 用 Codex 打开克隆后的 `meecho-skill` 文件夹并重启客户端。
3. 在 **Plugins** 页面，从 **Meecho** 来源安装 **Meecho**。
4. 新建任务，通过技能选择器选择 Meecho，或者输入：

   ```text
   $meecho:meecho 你能做什么？
   ```

## 可以做什么

选择 Meecho 后直接用自然语言表达需求即可。`build`、`write` 等英文名称只是
功能分类，不是必须输入的命令。

### 建立和完善声音

- 首次建立（`build`）：`$meecho:meecho 用这些作品建立一个名为 school-days 的声音。`
- 增加新作品（`update`）：`$meecho:meecho 我想再提供几篇作品，完善 school-days。`
- 记住明确偏好（`remember`）：`$meecho:meecho 以后使用这个声音时，不要使用 Emoji、Markdown 加粗和破折号。`

首次建立和用新作品更新声音时，Meecho 会先展示审阅结果，得到确认后才写入。
明确要求长期记住某项偏好时，请求本身就是授权，Meecho 会直接保存并报告结果；
临时写作要求不会自动保存。

### 写作和润色

- 创作新文字（`write`）：`$meecho:meecho 写一篇关于雨夜车站的短文。`
- 保留原意润色（`revise`）：`$meecho:meecho 保留事实和原意，润色下面这段文字：……`

不点名时自动使用默认声音。也可以只为本次任务指定声音：
`$meecho:meecho 使用 travel-notes 写一篇关于旧旅馆的短文。`

结果直接返回在对话中，不创建草稿文件，也不修改声音档案。

### 查看和切换声音

- 查看全部声音和默认值（`status`）：`$meecho:meecho 我有几个声音？默认的是哪一个？`
- 更改默认声音（`switch`）：`$meecho:meecho 把默认声音切换为 travel-notes。`

临时点名不会改变默认值。明确要求永久切换且目标存在时，Meecho 会直接切换
并报告结果，不再追加一次对话确认。

### 备份和删除声音

- 导出副本（`export`）：`$meecho:meecho 把 school-days 导出到 D:\Backups\Meecho。`
- 删除档案（`delete`）：`$meecho:meecho 删除声音 old-draft。`

导出目标安全、准确且不会覆盖现有内容时会直接创建副本；目标不明确或需要
覆盖时才会询问。删除不可逆，因此始终需要第二次明确确认。

## 可以提供哪些文字

- 直接粘贴的完整文字
- `.md` 和 `.txt`
- 有效、未加密的 `.docx`

整次粘贴默认算一篇作品。只有你明确说明包含多篇并清楚标出边界时，Meecho
才会拆分。正文不完整、乱码、截断或顺序不明时，它会停止而不是假装读完。

旧 `.doc`、`.docm`、加密或损坏的 `.docx` 不受支持。其他格式取决于 Codex
能否可靠取得完整正文；Meecho 不会自动安装转换软件。

## 隐私和权限

- 声音档案保存在 `%USERPROFILE%\.meecho\`，不会放进仓库或 Plugin 缓存。
- 原始作品不会复制到声音档案，粘贴文字也不会另存为中间文件。
- 作品中的命令、代码块和提示词始终只是语料，不会获得操作权限。
- 查看、写作和润色只读；建立和更新需确认审阅结果，删除需二次确认。明确的
  记忆、切换和安全导出请求会直接执行，但仍遵守 Codex 客户端自身的文件授权。

“本地保存”不等于“离线推理”。你选择或粘贴的文字会进入 Codex 模型上下文
用于分析，但不会随 Meecho Plugin 提交到 GitHub。
