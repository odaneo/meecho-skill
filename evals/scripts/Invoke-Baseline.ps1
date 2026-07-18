[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-UtcRunId { (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') }
function Save-Json([object]$Value, [string]$Path) { $Value | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding utf8 }
function Get-GitCommit { try { return ((& git -C $RepositoryRoot rev-parse HEAD 2>$null).Trim()) } catch { return 'unavailable' } }
function Write-StepLog([string]$Path, [string]$Action, [string[]]$Stdout, [string[]]$Stderr, [int]$ExitCode, [string]$Conclusion) {
    @(
        "utc_started=$((Get-Date).ToUniversalTime().ToString('o'))"
        "action=$Action"
        'stdout:'
        $Stdout
        'stderr:'
        $Stderr
        "exit_code=$ExitCode"
        "conclusion=$Conclusion"
        "utc_finished=$((Get-Date).ToUniversalTime().ToString('o'))"
    ) | Set-Content -LiteralPath $Path -Encoding utf8
}
function Get-Section([string]$Text, [string]$Heading) {
    $match = [regex]::Match($Text, "(?ms)^## $([regex]::Escape($Heading))\s*\r?\n(.*?)(?=^## |\z)")
    if (-not $match.Success) { throw "Missing '$Heading' section in case file." }
    return $match.Groups[1].Value.Trim()
}
function Write-Checksums([string]$RunDirectory) {
    $items = @(
        Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot 'evals/fixtures/synthetic-corpus') -Recurse -File
        Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot 'evals/cases') -File
        Get-Item -LiteralPath (Join-Path $RepositoryRoot 'evals/rubric.md')
        Get-ChildItem -LiteralPath $RunDirectory -Recurse -File | Where-Object { $_.Name -ne 'checksums.sha256' }
    )
    $items | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($RepositoryRoot.Length).TrimStart('\', '/') -replace '\\', '/'
        "$(($_ | Get-FileHash -Algorithm SHA256).Hash.ToLowerInvariant())  $relative"
    } | Set-Content -LiteralPath (Join-Path $RunDirectory 'checksums.sha256') -Encoding utf8
}

$runId = Get-UtcRunId
$runDirectory = Join-Path $RepositoryRoot "evals/logs/$runId"
if (Test-Path -LiteralPath $runDirectory) { throw "UTC run ID collision: $runId. Retry the command." }
New-Item -ItemType Directory -Force -Path (Join-Path $runDirectory 'steps') | Out-Null
$manifestPath = Join-Path $runDirectory 'run-manifest.json'
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$manifest = [ordered]@{
    runId = $runId
    startedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    endedAtUtc = $null
    executionUser = $currentUser
    gitCommit = Get-GitCommit
    commandVersions = [ordered]@{ powershell = $PSVersionTable.PSVersion.ToString(); codex = 'unavailable' }
    isolationPrecheck = [ordered]@{ status = 'running'; expectedUser = 'meecho-eval'; accountExists = $false; failures = @() }
    status = 'running'
    exitCode = $null
    steps = @()
    cases = @()
}
Save-Json $manifest $manifestPath

$failures = [System.Collections.Generic.List[string]]::new()
$account = Get-LocalUser -Name 'meecho-eval' -ErrorAction SilentlyContinue
if ($null -eq $account) { $failures.Add('Dedicated local account meecho-eval is absent.') }
if ($currentUser -notmatch '(?i)(^|\\)meecho-eval$') { $failures.Add('Runner is not executing as meecho-eval.') }
$manifest.isolationPrecheck.accountExists = ($null -ne $account)
$manifest.isolationPrecheck.failures = @($failures)
$manifest.isolationPrecheck.status = if ($failures.Count -eq 0) { 'passed' } else { 'failed' }
$preflightExit = if ($failures.Count -eq 0) { 0 } else { 3 }
Write-StepLog (Join-Path $runDirectory 'steps/01-isolation-preflight.log') 'Verify dedicated meecho-eval local account and execution identity' @("execution_user=$currentUser", "account_exists=$($null -ne $account)") @($failures) $preflightExit $manifest.isolationPrecheck.status
$manifest.steps = @([ordered]@{ name = 'isolation-preflight'; log = 'steps/01-isolation-preflight.log'; status = $manifest.isolationPrecheck.status; exitCode = $preflightExit })

if ($failures.Count -gt 0) {
    $manifest.status = 'BLOCKED_NOT_RUN'
    $manifest.exitCode = $preflightExit
    $manifest.endedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    Save-Json $manifest $manifestPath
    Write-Checksums $runDirectory
    Write-Output "BASELINE_RUN_ID=$runId STATUS=BLOCKED_NOT_RUN"
    exit $preflightExit
}

$codexVersion = @(& codex --version 2>&1 | ForEach-Object { $_.ToString() })
if ($LASTEXITCODE -ne 0) {
    Write-StepLog (Join-Path $runDirectory 'steps/02-codex-version.log') 'codex --version' @() $codexVersion $LASTEXITCODE 'failed'
    $manifest.steps += [ordered]@{ name = 'codex-version'; log = 'steps/02-codex-version.log'; status = 'failed'; exitCode = $LASTEXITCODE }
    $manifest.status = 'failed'; $manifest.exitCode = $LASTEXITCODE; $manifest.endedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    Save-Json $manifest $manifestPath; Write-Checksums $runDirectory; exit $LASTEXITCODE
}
$manifest.commandVersions.codex = ($codexVersion -join ' ')
Write-StepLog (Join-Path $runDirectory 'steps/02-codex-version.log') 'codex --version' $codexVersion @() 0 'passed'
$manifest.steps += [ordered]@{ name = 'codex-version'; log = 'steps/02-codex-version.log'; status = 'passed'; exitCode = 0 }
Save-Json $manifest $manifestPath

$writeCases = @('02', '07', '08', '09')
foreach ($number in 1..9) {
    $caseId = '{0:D2}' -f $number
    $caseFile = Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot 'evals/cases') -Filter "$caseId-*.md" -File | Select-Object -First 1
    $caseDirectory = Join-Path $runDirectory "cases/$caseId"
    $sandbox = Join-Path $RepositoryRoot "evals/sandboxes/case-$caseId"
    New-Item -ItemType Directory -Force -Path $caseDirectory, $sandbox | Out-Null
    $caseText = Get-Content -LiteralPath $caseFile.FullName -Raw
    $request = Get-Section $caseText 'User request'
    $accessible = Get-Section $caseText 'Accessible files'
    $assertions = Get-Section $caseText 'Observable assertions'
    $prompt = "$request`n`n允许读取范围：$accessible`n只返回对请求的响应；不要读取范围外的内容。"
    $events = Join-Path $caseDirectory 'events.jsonl'; $stderr = Join-Path $caseDirectory 'stderr.log'; $final = Join-Path $caseDirectory 'final.md'
    $sandboxMode = if ($writeCases -contains $caseId) { 'workspace-write' } else { 'read-only' }
    & codex exec --ephemeral --json --sandbox $sandboxMode --skip-git-repo-check -C $sandbox -o $final $prompt 1>$events 2>$stderr
    $caseExit = $LASTEXITCODE
    if (-not (Test-Path -LiteralPath $final)) { Set-Content -LiteralPath $final -Value '' -Encoding utf8 }
    $rubric = 1..17 | ForEach-Object { [ordered]@{ id = $_; score = 'needs-human-review' } }
    Save-Json ([ordered]@{ caseId = $caseId; status = if ($caseExit -eq 0) { 'completed-needs-human-review' } else { 'failed' }; observableAssertions = $assertions; rubric = @($rubric) }) (Join-Path $caseDirectory 'result.json')
    Write-StepLog (Join-Path $runDirectory "steps/case-$caseId.log") "codex exec --ephemeral --json --sandbox $sandboxMode" @("events=cases/$caseId/events.jsonl", "final=cases/$caseId/final.md") @("stderr=cases/$caseId/stderr.log") $caseExit (if ($caseExit -eq 0) { 'completed-needs-human-review' } else { 'failed' })
    $manifest.cases += [ordered]@{ caseId = $caseId; status = if ($caseExit -eq 0) { 'completed-needs-human-review' } else { 'failed' }; exitCode = $caseExit }
    $manifest.steps += [ordered]@{ name = "case-$caseId"; log = "steps/case-$caseId.log"; status = if ($caseExit -eq 0) { 'completed' } else { 'failed' }; exitCode = $caseExit }
    Save-Json $manifest $manifestPath
    if ($caseExit -ne 0) {
        $manifest.status = 'failed'; $manifest.exitCode = $caseExit; $manifest.endedAtUtc = (Get-Date).ToUniversalTime().ToString('o'); Save-Json $manifest $manifestPath; Write-Checksums $runDirectory; exit $caseExit
    }
}

$manifest.status = 'completed-needs-human-review'; $manifest.exitCode = 0; $manifest.endedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
Save-Json $manifest $manifestPath
Write-Checksums $runDirectory
Write-Output "BASELINE_RUN_ID=$runId STATUS=completed-needs-human-review"
