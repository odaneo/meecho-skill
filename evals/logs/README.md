# 任务 1 本地日志

`evals/logs/<run-id>/` 保存任务 1 的本地原始记录，并由 `.gitignore` 排除。

每个正式基线 run 包含：

- `run.json`：运行方式、模型、reasoning、Git commit、状态和每题退出码。
- `case-01/` 至 `case-05/`：每题的 `prompt.md`、`response.md`、
  `events.jsonl`、`stderr.txt` 和 `score.json`。
- `tests/`：结构测试的 `result.json`、`stdout.txt` 和 `stderr.txt`。

任务 1 允许两种真实运行方式：

- `cli`：普通登录环境中的 `codex exec`。
- `current-thread`：当前 Codex 任务直接产生回答，用于宿主环境禁止启动
  WindowsApps CLI 的情况。此模式必须在 `run.json` 中如实记录，不能冒充
  独立 CLI 会话。

GitHub 只提交脱敏的 `evals/results/baseline-summary.md`，不提交上述原始日志。
