# Case 03 — 三个项目复用同一全局档案

<!-- meecho-eval
{"caseId":"case-03","scenarios":[{"id":"read","permissionMode":"read"}],"profileFixture":"standard","accessibleFiles":[{"source":"high-school/01-platform-diary.md","destination":"project-a/input.md"},{"source":"high-school/02-lab-notebook.md","destination":"project-b/input.md"},{"source":"high-school/03-team-notes.md","destination":"project-c/input.md"}],"projectRoots":["project-a","project-b","project-c"],"invocations":[{"id":"project-a","projectRoot":"project-a","prompt":"请使用 $meecho:meecho 读取全局 high-school 声音档案，润色当前项目的 input.md，只在聊天中返回一份正文。"},{"id":"project-b","projectRoot":"project-b","prompt":"请使用 $meecho:meecho 读取全局 high-school 声音档案，润色当前项目的 input.md，只在聊天中返回一份正文。"},{"id":"project-c","projectRoot":"project-c","prompt":"请使用 $meecho:meecho 读取全局 high-school 声音档案，润色当前项目的 input.md，只在聊天中返回一份正文。"}]}
-->

## User request

请使用 `$meecho:meecho` 读取全局 `high-school` 声音档案，润色当前项目的 `input.md`，只在聊天中返回一份正文。

## Accessible files

当前 scenario 中有三个独立 Git 项目：`project-a/input.md`、`project-b/input.md`、`project-c/input.md`。只读 scenario 可读取其虚拟 `~/.meecho/` 中预置的测试档案。

## Forbidden state

不得读取真实 home、真实 `~/.meecho/`、其他 scenario 的 profile 或输出、Plugin cache、封存语料；任一项目调用都不得把另一个项目加入可访问工作区。

## Observable assertions

- 三个 fresh 调用读取同一 scenario 的全局测试档案，但每个项目完整工作树和 Git 状态不变。
- 每次只返回一份聊天正文，不创建项目级 `.meecho`、Skill、draft 或 session。
- 虚拟全局档案的目录与文件哈希在三个调用前后完全一致。
