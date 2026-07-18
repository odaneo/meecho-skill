# Local evaluation logs

Each script invocation creates `evals/logs/<UTC_RUN_ID>/`, where the ID is `yyyyMMddTHHmmssZ`.
Run directories are intentionally ignored: they may contain raw Codex JSONL and stderr. Do not commit or manually clean them unless the user explicitly asks.

Every run records a manifest, per-step logs, checksums, and (after a successful isolation preflight) per-case event, stderr, final-answer, and scoring files. Logs never include authentication tokens, a complete process environment, or developer-home content.

Before a formal run, an administrator must provision `evals/sandboxes/isolation-config.json` locally (it is ignored). It contains a developer profile SID and a relative path to an existing developer-home canary that the `meecho-eval` account is denied from enumerating:

```json
{"developerProfileSid":"S-1-5-21-...","developerHomeCanary":"Documents\\meecho-isolation-canary"}
```

Do not create the account, canary, or ACLs from this repository. Copy the formal test bundle to a directory accessible to `meecho-eval` that is outside the developer home, then run the baseline there. The runner blocks if the repository is inside that home, the canary is readable, missing, or returns an ambiguous error.
