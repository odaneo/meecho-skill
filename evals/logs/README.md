# Local evaluation logs

Every harness invocation creates an ignored directory named
`evals/logs/<yyyyMMddTHHmmssfffZ-8hex>/`.

Behavior runs use the same `mode/case/scenario` hierarchy as the isolated
capsule:

```text
<run-id>/<mode>/<case>/<scenario>/
```

Each executed step records separate stdout and stderr files, its exit code,
UTC timestamps, a JSON record, and SHA-256 checksums. A run manifest records
only the names of effective environment variables; it never records their
values. Authentication files and authentication contents are never copied,
hashed, or logged.

Raw JSONL, stderr, final responses, local paths, and temporary scoring records
stay in this ignored directory. Git tracks only this README, `.gitignore`, and
the redacted summary in `evals/results/`.

The supported non-complete statuses are:

- `AUTH_REQUIRED`: the isolated Codex home has no usable file-backed login.
- `BLOCKED_NOT_RUN`: a path, capability, configuration, launch, or canary check
  failed before behavior cases were allowed to run.
- `INVALID_COMPARISON`: a paired control/treatment run completed with unequal
  comparison inputs.

Do not delete historical run directories unless their owner explicitly asks.
