Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$runnerPath = Join-Path $repoRoot 'evals\scripts\Invoke-Baseline.ps1'

function Assert-True {
    param(
        [Parameter(Mandatory)]
        [bool] $Condition,

        [Parameter(Mandatory)]
        [string] $Message
    )

    if (-not $Condition) {
        throw "FAIL: $Message"
    }
}

function Assert-Equal {
    param(
        [AllowNull()]
        $Expected,

        [AllowNull()]
        $Actual,

        [Parameter(Mandatory)]
        [string] $Message
    )

    if ($Expected -ne $Actual) {
        throw "FAIL: $Message Expected=<$Expected> Actual=<$Actual>"
    }
}

function Get-EnvironmentValue {
    param(
        [Parameter(Mandatory)]
        [string] $Name
    )

    $item = Get-Item "Env:$Name" -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return $null
    }

    return [string]$item.Value
}

Assert-True (Test-Path -LiteralPath $runnerPath -PathType Leaf) `
    'Invoke-Baseline.ps1 must exist before its behavior can be tested.'

$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'meecho-task1-' + [guid]::NewGuid().ToString('N')
)

$environmentBefore = [ordered]@{
    HOME = Get-EnvironmentValue -Name 'HOME'
    USERPROFILE = Get-EnvironmentValue -Name 'USERPROFILE'
    CODEX_HOME = Get-EnvironmentValue -Name 'CODEX_HOME'
}

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

    $dryRunOutput = @(
        & $runnerPath `
            -DryRun `
            -LogsRoot $testRoot
    )

    $runRoot = [string]$dryRunOutput[-1]
    Assert-True (Test-Path -LiteralPath $runRoot -PathType Container) `
        'Dry-run must print an existing run directory as its last line.'

    $caseDirectories = @(
        Get-ChildItem -LiteralPath $runRoot -Directory -Filter 'case-*'
    )
    Assert-Equal 5 $caseDirectories.Count 'Dry-run must prepare exactly five cases.'

    foreach ($caseDirectory in $caseDirectories) {
        Assert-True (
            Test-Path -LiteralPath (Join-Path $caseDirectory.FullName 'prompt.md') `
                -PathType Leaf
        ) "Missing prompt.md for $($caseDirectory.Name)."
    }

    foreach ($name in $environmentBefore.Keys) {
        Assert-Equal $environmentBefore[$name] (Get-EnvironmentValue -Name $name) `
            "Dry-run changed parent environment variable $name."
    }

    $incompleteRejected = $false
    try {
        & $runnerPath -Finalize -RunRoot $runRoot *> $null
    }
    catch {
        $incompleteRejected = $true
    }
    Assert-True $incompleteRejected `
        'Finalize must reject a run without five responses and five scores.'

    $scoreFixture = [ordered]@{
        scores = [ordered]@{
            taskCompletion = 2
            styleMatch = 1
            styleTransfer = 1
            noCopying = 2
        }
        total = 6
        conclusion = '合成测试评分'
    }

    foreach ($caseDirectory in $caseDirectories) {
        Set-Content `
            -LiteralPath (Join-Path $caseDirectory.FullName 'response.md') `
            -Value '合成测试回答' `
            -Encoding UTF8
        Set-Content `
            -LiteralPath (Join-Path $caseDirectory.FullName 'events.jsonl') `
            -Value '{"type":"test.fixture"}' `
            -Encoding UTF8
        Set-Content `
            -LiteralPath (Join-Path $caseDirectory.FullName 'stderr.txt') `
            -Value '' `
            -Encoding UTF8
        $scoreFixture |
            ConvertTo-Json -Depth 5 |
            Set-Content `
                -LiteralPath (Join-Path $caseDirectory.FullName 'score.json') `
                -Encoding UTF8
    }

    & $runnerPath -Finalize -RunRoot $runRoot *> $null

    $runRecord = Get-Content `
        -LiteralPath (Join-Path $runRoot 'run.json') `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json
    Assert-Equal '完成' $runRecord.status `
        'A complete run must use the plain Chinese status 完成.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Output 'PASS Test-BaselineRunner'
