# 全局私人声音档案规范

本文件定义 Meecho 档案结构的第一个稳定版本。所有档案内容只保存在用户
本机，不得进入插件目录、项目目录、插件缓存或 Git。

## 固定根目录

唯一根目录为：

```text
%USERPROFILE%\.meecho\
```

不得允许用户通过配置文件改写这个根目录。访问任何档案前，先取得规范化的
绝对路径，再确认它仍位于这个根目录之内。

```text
%USERPROFILE%\.meecho\
├── config.json
├── profiles\
│   └── <profile-id>\
│       ├── manifest.json
│       ├── style-profile.md
│       ├── attention-lens.md
│       ├── voices.md
│       ├── exemplars.jsonl
│       └── preferences.md
└── backups\
    └── <profile-id>\
        └── <UTC-timestamp>\
```

原始文章不属于档案目录。档案只能保存结构化结论、来源计数、作品标识和少量
短例句，不得复制整篇原文。

## 版本规则

- `config.json` 和每个 `manifest.json` 都必须包含整数 `schema`。
- 当前唯一支持的值是 `1`。
- 读取到未知 `schema` 时立即停止。
- 不得猜测新旧字段含义，不得自动覆盖，不得静默降级。
- 未来迁移必须先完整备份，再由明确的迁移流程处理。

## 活动档案

`config.json` 只允许两个字段：

```json
{
  "schema": 1,
  "active_profile_id": "high-school"
}
```

`active_profile_id` 是当前活动档案。它只允许小写英文字母、数字和连字符，
长度为 1 至 63 个字符，并且第一个字符必须是字母或数字。

```text
^[a-z0-9][a-z0-9-]{0,62}$
```

档案路径只能由程序按下式推导：

```text
%USERPROFILE%\.meecho\profiles\<active_profile_id>\
```

配置文件中不得出现自定义路径。拒绝绝对路径、`.`、`..`、斜杠、反斜杠、
符号链接、目录联接和其他重解析点。规范化后的档案路径必须仍是 `profiles\`
的直接子目录。

如果尚未建立档案，`.meecho` 和 `config.json` 可以都不存在。不得为了
`status` 操作创建空档案。

## 档案清单

每个档案目录中的 `manifest.json` 只允许下列结构：

```json
{
  "schema": 1,
  "profile_id": "high-school",
  "created_at": "2026-07-26T00:00:00Z",
  "updated_at": "2026-07-26T00:00:00Z",
  "source_counts": {
    "historical_works": 3,
    "current_context_works": 1
  }
}
```

- `profile_id` 必须与目录名及 `config.json` 的活动档案一致。
- `created_at` 和 `updated_at` 必须是 UTC 时间。
- 两个来源计数必须是非负整数。
- `manifest.json` 不得保存原始文档路径、原文或用户身份信息。
- 成年时期的文章只计入 `current_context_works`，不得自动当成负面样本。

## 内容文件职责

### `style-profile.md`

至少包含：

```markdown
## 已确认规律
## 反例与边界
## 不确定结论
```

已确认规律必须来自历史作品证据。反例和适用边界必须单独保存。不足以确认的
观察只能进入“不确定结论”，不得伪装成稳定风格规律。

### `attention-lens.md`

至少包含：

```markdown
## 关注对象
## 观察方式
```

这里只记录叙述者经常注意什么、忽略什么以及如何组织观察，不记录通用写作
建议。

### `voices.md`

至少包含：

```markdown
## 历史声音
## 当前声音
```

历史声音来自旧作证据。当前声音来自成年文章和用户当前表达。两者可以并存，
不得把差异自动解释为退步，也不得把当前声音自动当成历史声音的反例。

### `preferences.md`

至少包含：

```markdown
## 当前明确偏好
## 当前明确反感
```

这里只保存用户亲口确认的当前偏好和反感。模型从文章推测出的内容不得写入
本文件；未确认推测必须留在“不确定结论”。

### `exemplars.jsonl`

每行是一个独立 JSON 对象：

```json
{"id":"history-001","category":"historical_evidence","work_id":"hs-001","excerpt":"短例句","note":"支持某条节奏规律"}
{"id":"counter-001","category":"counterexample","work_id":"hs-002","excerpt":"短例句","note":"说明该规律并非总是成立"}
```

规则如下：

- `id` 在当前档案内唯一，只允许小写字母、数字和连字符。
- `category` 只能是 `historical_evidence` 或 `counterexample`。
- 当前偏好不得伪装成历史证据。
- 不确定结论不得伪装成例句证据。
- `work_id` 只保存作品标识，不保存原始文件路径。
- `excerpt` 必须是非空短例句，最长 120 个字符。
- `note` 必须说明该例句支持或限制什么结论。
- 不得保存整篇文章或可替代整篇文章的大段连续文字。

## 更新前备份

执行 `update` 或任何会改写既有档案的操作时：

1. 先校验当前 `config.json`、`manifest.json` 和全部必需文件。
2. 遇到未知 schema 或非法路径时立即停止，不得写入。
3. 将现有档案完整复制到：

```text
%USERPROFILE%\.meecho\backups\<profile-id>\<UTC-timestamp>\
```

4. 确认备份成功后，才写入临时目录。
5. 校验临时目录完整有效后，再替换原档案。
6. 任一步失败都保留原档案，不得留下部分更新。

备份目录同样是私人数据，不得复制到插件或项目。

## 删除确认

执行 `delete` 时：

1. 解析并显示准备删除的规范化绝对路径。
2. 明确说明是否同时删除该档案的备份。
3. 要求用户进行第二次确认。
4. 没有第二次明确确认时立即停止。
5. 只删除已经展示并确认的目标，不得扩大删除范围。
6. 如果删除的是活动档案且还有其他档案，先让用户明确选择新的活动档案。
7. 如果删除最后一个档案，则删除 `config.json`，但默认保留备份。

## 操作边界

- `status` 只读；档案不存在时直接说明，不创建文件。
- `write` 和 `revise` 只读取必要内容，并在聊天中返回正文。
- `build`、`update` 和 `remember` 只有在用户明确选择操作并批准写入后才能
  修改档案。
- `export` 只创建副本，不改变源档案。
- `delete` 必须遵守上面的二次确认规则。
