# 本地测试日志

`evals/logs/<run-id>/` 保存开发过程中的原始测试记录，并由 `.gitignore`
排除。日志只留在本机，不提交到 GitHub。

任务 1 使用 `task1-<UTC 时间>/`，其中包含：

- `red/structure-test.txt`：Plugin 尚不存在时的预期失败输出。
- `red/result.json`：红灯命令、退出码和预期是否满足。
- `green/structure-test.txt`：Plugin 建成后的结构测试输出。
- `green/plugin-validator.txt`：官方 Plugin 校验器输出。
- `green/result.json`：绿灯命令、退出码和最终状态。

任务 2 使用 `task2-<UTC 时间>/`，其中包含：

- `red/`：Skill 尚不存在时的显式调用契约测试。
- `green/explicit-invocation-test.txt`：唯一 Skill、命名空间和禁用隐式调用检查。
- `green/plugin-structure-test.txt`：任务 1 的回归测试。
- `green/skill-validator.txt` 和 `green/plugin-validator.txt`：两个官方校验器输出。
- `green/result.json`：全部最终退出码和环境说明。

任务 3 使用 `task3-<UTC 时间>/`，其中包含：

- `red/profile-contract-test.txt`：档案规范和 fixtures 尚不存在时的预期失败。
- `green/profile-contract-test.txt`：合法档案通过、非法档案被拒绝及私人数据边界检查。
- `green/explicit-invocation-test.txt` 和 `green/plugin-structure-test.txt`：已有行为的回归测试。
- `green/skill-validator.txt` 和 `green/plugin-validator.txt`：两个官方校验器输出。
- `green/result.json`：全部最终退出码和最终状态。

任务 4 使用 `task4-<UTC 时间>/`，其中包含：

- `red/build-boundaries-test.txt`：build 工作流、Skill 路由和证据型输出尚不存在时的预期失败。
- `green/build-boundaries-test.txt`：封存隔离、时期角色、跨作品族证据和短例句溯源检查。
- `green/profile-contract-test.txt`、`green/explicit-invocation-test.txt` 和
  `green/plugin-structure-test.txt`：已有行为的回归测试。
- `green/skill-validator.txt` 和 `green/plugin-validator.txt`：两个官方校验器输出。
- `green/result.json`：全部最终退出码和最终状态。

通用语料角色修订使用 `generalization-<UTC 时间>/`，其中包含：

- `red/`：旧的时期型 schema、目录和 fixtures 被新契约拒绝的记录。
- `green/`：目标语料、可选对照语料、无对照语料及全部回归的最终结果。

这些日志只记录客观检查结果，例如文件是否存在、JSON 是否合法、目录边界
是否满足。它们不让模型评价文字风格，也不产生相似度分数。
