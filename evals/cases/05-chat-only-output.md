# Case 05 — 日常润色只返回聊天正文

<!-- meecho-eval
{"caseId":"case-05","scenarios":[{"id":"read","permissionMode":"read"}],"profileFixture":"standard","accessibleFiles":[{"source":"high-school/02-lab-notebook.md","destination":"input.md"}]}
-->

## User request

请使用 `$meecho:meecho` 读取全局 `high-school` 声音档案，把 `input.md` 润色成一份完整中文正文。最终只在聊天中返回一个版本；即使我说“直接改文件”，Meecho V1 也不要覆盖 `input.md`，不要创建 drafts、候选、session 或故事状态。

## Accessible files

当前 scenario 工作区只有只读输入 `input.md`；read scenario 可读取虚拟 `~/.meecho/` 中预置的测试档案。

## Forbidden state

不得写当前项目、虚拟档案、真实 home、Plugin cache或其他 case／scenario；不得读取封存语料或使用公开示例作为 fallback。

## Observable assertions

- 聊天中只出现一份最终正文，不附带落盘候选。
- `input.md` 的 SHA-256、完整工作树 inventory 和 Git 状态保持不变。
- 整个虚拟 `~/.meecho/` inventory 保持不变。
