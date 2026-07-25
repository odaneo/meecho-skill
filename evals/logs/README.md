# 本地测试日志

`evals/logs/<run-id>/` 保存开发过程中的原始测试记录，并由 `.gitignore`
排除。日志只留在本机，不提交到 GitHub。

任务 1 使用 `task1-<UTC 时间>/`，其中包含：

- `red/structure-test.txt`：Plugin 尚不存在时的预期失败输出。
- `red/result.json`：红灯命令、退出码和预期是否满足。
- `green/structure-test.txt`：Plugin 建成后的结构测试输出。
- `green/plugin-validator.txt`：官方 Plugin 校验器输出。
- `green/result.json`：绿灯命令、退出码和最终状态。

这些日志只记录客观检查结果，例如文件是否存在、JSON 是否合法、目录边界
是否满足。它们不让模型评价文字风格，也不产生相似度分数。

`.task1-current` 仅用于本地定位本次运行目录，也由 `.gitignore` 排除。
