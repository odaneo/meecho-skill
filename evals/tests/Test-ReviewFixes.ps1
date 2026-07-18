[CmdletBinding()]
param([string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$baseline = Get-Content -Raw (Join-Path $RepositoryRoot 'evals/scripts/Invoke-Baseline.ps1')
$validator = Get-Content -Raw (Join-Path $RepositoryRoot 'evals/scripts/Invoke-EvalValidation.ps1')
$failures = [System.Collections.Generic.List[string]]::new()
function Require([bool]$Condition, [string]$Message) { if (-not $Condition) { $script:failures.Add($Message) } }

Require ($baseline -match 'WindowsIdentity.*User\.Value') 'Baseline must compare the current SID, not a username suffix.'
Require ($baseline -match 'Get-LocalUser.*meecho-eval') 'Baseline must resolve the dedicated local account.'
Require ($baseline -match 'ProfileList') 'Baseline must resolve the developer profile through HKLM ProfileList.'
Require ($baseline -match 'developerHomeCanary') 'Baseline must require a developer-home deny canary from ignored isolation config.'
Require ($baseline -match "'codex','login','status'") 'Baseline preflight must record Codex login status.'
Require ($baseline -match "'codex','plugin','list'") 'Baseline preflight must record the plugin list.'
Require ($baseline -match '--ignore-user-config' -and $baseline -match '--ignore-rules') 'Each Codex exec must ignore user config and rules.'
Require ($baseline -match 'Get-Inventory') 'Baseline must capture before/after inventories.'
Require ($baseline -match 'Stage-Case') 'Baseline must stage declared accessible files.'
Require ($baseline -match 'foreach\(\$n in 1\.\.9\)') 'Baseline must continue through all independent cases.'
Require ($validator -match 'Get-FileHash' -and $validator -match 'checksums') 'Validator must recompute checksums.'
Require (Test-Path -LiteralPath (Join-Path $RepositoryRoot 'evals/scripts/Invoke-Task1Tests.ps1')) 'Task test runner is required.'
Require (-not ($baseline -match '--full-auto')) 'Baseline must not use deprecated full-auto.'

$accessible = Get-Content -Raw (Join-Path $RepositoryRoot 'evals/fixtures/synthetic-corpus/high-school/01-platform-diary.md')
Require (-not ($accessible -match '只有这一篇出现|叙述者习惯|它延续')) 'Accessible high-school prose must not reveal evaluation metadata.'
$adult = Get-Content -Raw (Join-Path $RepositoryRoot 'evals/fixtures/synthetic-corpus/adult-contrast/01-city-blog.md')
Require (-not ($adult -match '不是错误|不是应被自动删除的负样本')) 'Adult prose must not reveal the correct scoring conclusion.'
Require (Test-Path -LiteralPath (Join-Path $RepositoryRoot 'evals/fixtures/reviewer-metadata.json')) 'Reviewer-only metadata is required.'

if ($failures.Count) { $failures | ForEach-Object { Write-Output "FAIL: $_" }; throw "Review-fix contract failed with $($failures.Count) issue(s)." }
Write-Output 'Review-fix contract passed.'
