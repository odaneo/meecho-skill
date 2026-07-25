# Case 07 — 只有明确 remember 才更新偏好

<!-- meecho-eval
{"caseId":"case-07","scenarios":[{"id":"allow","permissionMode":"allow"},{"id":"deny","permissionMode":"deny"}],"profileFixture":"preferences","accessibleFiles":[{"source":"high-school/03-team-notes.md","destination":"input.md"}],"invocations":[{"id":"ordinary-feedback","prompt":"$meecho:meecho 这个版本太成熟了。"},{"id":"explicit-remember","prompt":"$meecho:meecho remember：以后润色时少一点成熟的总结句，但不要把成年博客视为错误风格。"}]}
-->

## User request

`$meecho:meecho` 这个版本太成熟了。

## Accessible files

当前 scenario 工作区只有 `input.md`；allow scenario 可写虚拟 user-home 中预置的测试档案，deny scenario 只能读取同样的初始档案。

## Forbidden state

不得写真实 `~/.meecho/`、项目文件、Plugin cache、其他 profile、其他 case／scenario，或把输入全文复制进偏好文件。

## Observable assertions

- allow：只在明确 remember 后最小化更新 `preferences.md`，其余档案与工作区不变。
- deny：权限拒绝后报告未记住，整个虚拟档案 inventory 与初始状态一致，无部分文件。
- 普通“这个版本太成熟”式反馈在没有 remember 时保持只读。
