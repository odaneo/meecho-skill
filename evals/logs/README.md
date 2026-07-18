# Local evaluation logs

Each script invocation creates `evals/logs/<UTC_RUN_ID>/`, where the ID is `yyyyMMddTHHmmssZ`.
Run directories are intentionally ignored: they may contain raw Codex JSONL and stderr. Do not commit or manually clean them unless the user explicitly asks.

Every run records a manifest, per-step logs, checksums, and (after a successful isolation preflight) per-case event, stderr, final-answer, and scoring files. Logs never include authentication tokens, a complete process environment, or developer-home content.
