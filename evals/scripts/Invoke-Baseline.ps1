[CmdletBinding()]
param(
    [switch] $DryRun,

    [switch] $Manual,

    [switch] $Finalize,

    [string] $RunRoot,

    [string] $LogsRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$casesRoot = Join-Path $repoRoot 'evals\cases'

if ([string]::IsNullOrWhiteSpace($LogsRoot)) {
    $LogsRoot = Join-Path $repoRoot 'evals\logs'
}

function Write-RunRecord {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [object] $Record
    )

    $Record |
        ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-CaseFiles {
    $caseFiles = @(
        Get-ChildItem -LiteralPath $casesRoot -File -Filter '*.md' |
            Sort-Object Name
    )
    if ($caseFiles.Count -ne 5) {
        throw "Expected exactly five baseline cases, found $($caseFiles.Count)."
    }

    return $caseFiles
}

function New-RunId {
    return (
        (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ') +
        '-' +
        [guid]::NewGuid().ToString('N').Substring(0, 8)
    )
}

function Get-GitCommit {
    $commit = @(& git -C $repoRoot rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or $commit.Count -eq 0) {
        return 'unknown'
    }

    return [string]$commit[-1]
}

function New-BaselineRun {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('dry-run', 'cli', 'current-thread')]
        [string] $ExecutionMode
    )

    $caseFiles = Get-CaseFiles
    New-Item -ItemType Directory -Path $LogsRoot -Force | Out-Null

    $newRunRoot = Join-Path $LogsRoot (New-RunId)
    New-Item -ItemType Directory -Path $newRunRoot | Out-Null

    $caseRecords = @()
    for ($index = 0; $index -lt $caseFiles.Count; $index++) {
        $caseId = 'case-{0:D2}' -f ($index + 1)
        $caseRoot = Join-Path $newRunRoot $caseId
        New-Item -ItemType Directory -Path $caseRoot | Out-Null

        $promptPath = Join-Path $caseRoot 'prompt.md'
        Copy-Item -LiteralPath $caseFiles[$index].FullName -Destination $promptPath

        $caseRecords += [ordered]@{
            caseId = $caseId
            sourceCase = $caseFiles[$index].Name
            prompt = "$caseId/prompt.md"
            response = "$caseId/response.md"
            events = "$caseId/events.jsonl"
            stderr = "$caseId/stderr.txt"
            score = "$caseId/score.json"
            exitCode = $null
        }
    }

    $status = switch ($ExecutionMode) {
        'dry-run' { '准备完成' }
        'current-thread' { '等待回答' }
        default { '运行中' }
    }

    $runRecord = [ordered]@{
        schemaVersion = 1
        runId = Split-Path -Leaf $newRunRoot
        status = $status
        executionMode = $ExecutionMode
        model = 'gpt-5.6-sol'
        reasoning = 'high'
        gitCommit = Get-GitCommit
        startedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        completedAtUtc = $null
        failureReason = $null
        cases = $caseRecords
    }

    Write-RunRecord -Path (Join-Path $newRunRoot 'run.json') -Record $runRecord
    return $newRunRoot
}

function Complete-BaselineRun {
    param(
        [Parameter(Mandatory)]
        [string] $TargetRunRoot
    )

    $resolvedRunRoot = (Resolve-Path -LiteralPath $TargetRunRoot).Path
    $runRecordPath = Join-Path $resolvedRunRoot 'run.json'
    if (-not (Test-Path -LiteralPath $runRecordPath -PathType Leaf)) {
        throw "Missing run.json: $resolvedRunRoot"
    }

    $caseDirectories = @(
        Get-ChildItem -LiteralPath $resolvedRunRoot -Directory -Filter 'case-*' |
            Sort-Object Name
    )
    if ($caseDirectories.Count -ne 5) {
        throw "Expected five case directories, found $($caseDirectories.Count)."
    }

    $scoreNames = @(
        'taskCompletion',
        'styleMatch',
        'styleTransfer',
        'noCopying'
    )

    foreach ($caseDirectory in $caseDirectories) {
        foreach ($fileName in 'prompt.md', 'response.md', 'events.jsonl', 'stderr.txt', 'score.json') {
            $path = Join-Path $caseDirectory.FullName $fileName
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Missing $fileName in $($caseDirectory.Name)."
            }
            if ($fileName -in @('prompt.md', 'response.md', 'events.jsonl', 'score.json')) {
                $content = Get-Content -LiteralPath $path -Raw -Encoding UTF8
                if ([string]::IsNullOrWhiteSpace($content)) {
                    throw "Empty $fileName in $($caseDirectory.Name)."
                }
            }
        }

        $score = Get-Content `
            -LiteralPath (Join-Path $caseDirectory.FullName 'score.json') `
            -Raw `
            -Encoding UTF8 |
            ConvertFrom-Json

        $calculatedTotal = 0
        foreach ($scoreName in $scoreNames) {
            $value = $score.scores.$scoreName
            if ($value -isnot [int] -and $value -isnot [long]) {
                throw "Score $scoreName in $($caseDirectory.Name) must be an integer."
            }
            if ($value -lt 0 -or $value -gt 2) {
                throw "Score $scoreName in $($caseDirectory.Name) must be between 0 and 2."
            }
            $calculatedTotal += [int]$value
        }

        if ([int]$score.total -ne $calculatedTotal) {
            throw "Score total mismatch in $($caseDirectory.Name)."
        }
        if ([string]::IsNullOrWhiteSpace([string]$score.conclusion)) {
            throw "Missing conclusion in $($caseDirectory.Name)."
        }
    }

    $runRecord = Get-Content -LiteralPath $runRecordPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $runRecord.status = '完成'
    $runRecord.completedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    $runRecord.failureReason = $null
    Write-RunRecord -Path $runRecordPath -Record $runRecord
    return $resolvedRunRoot
}

if ($Finalize) {
    if ([string]::IsNullOrWhiteSpace($RunRoot)) {
        throw '-Finalize requires -RunRoot.'
    }
    Complete-BaselineRun -TargetRunRoot $RunRoot
    return
}

if ($DryRun -and $Manual) {
    throw '-DryRun and -Manual cannot be used together.'
}

$executionMode = if ($DryRun) {
    'dry-run'
}
elseif ($Manual) {
    'current-thread'
}
else {
    'cli'
}

$createdRunRoot = New-BaselineRun -ExecutionMode $executionMode

if ($DryRun -or $Manual) {
    Write-Output $createdRunRoot
    return
}

$runRecordPath = Join-Path $createdRunRoot 'run.json'
$runRecord = Get-Content -LiteralPath $runRecordPath -Raw -Encoding UTF8 |
    ConvertFrom-Json

for ($index = 0; $index -lt $runRecord.cases.Count; $index++) {
    $caseRecord = $runRecord.cases[$index]
    $promptPath = Join-Path $createdRunRoot $caseRecord.prompt
    $responsePath = Join-Path $createdRunRoot $caseRecord.response
    $eventsPath = Join-Path $createdRunRoot $caseRecord.events
    $stderrPath = Join-Path $createdRunRoot $caseRecord.stderr
    $prompt = Get-Content -LiteralPath $promptPath -Raw -Encoding UTF8

    try {
        & codex exec `
            --sandbox read-only `
            --model gpt-5.6-sol `
            -c 'model_reasoning_effort="high"' `
            --json `
            --output-last-message $responsePath `
            $prompt 1> $eventsPath 2> $stderrPath
        $caseRecord.exitCode = $LASTEXITCODE
    }
    catch {
        $_ | Out-String | Set-Content -LiteralPath $stderrPath -Encoding UTF8
        $caseRecord.exitCode = 1
    }

    Write-RunRecord -Path $runRecordPath -Record $runRecord
    if ($caseRecord.exitCode -ne 0) {
        $runRecord.status = '未运行'
        $runRecord.failureReason = 'Codex CLI 无法启动或执行'
        Write-RunRecord -Path $runRecordPath -Record $runRecord
        throw "Codex CLI failed for $($caseRecord.caseId). Logs: $createdRunRoot"
    }
}

$runRecord.status = '等待评分'
Write-RunRecord -Path $runRecordPath -Record $runRecord
Write-Output $createdRunRoot
