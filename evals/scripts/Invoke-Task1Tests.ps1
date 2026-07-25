[CmdletBinding()]
param(
    [string] $RunRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$testPath = Join-Path $repoRoot 'evals\tests\Test-BaselineRunner.ps1'
$runnerPath = Join-Path $repoRoot 'evals\scripts\Invoke-Baseline.ps1'
$logsRoot = Join-Path $repoRoot 'evals\logs'

if ([string]::IsNullOrWhiteSpace($RunRoot)) {
    $testRunId = (
        (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ') +
        '-' +
        [guid]::NewGuid().ToString('N').Substring(0, 8)
    )
    $testLogRoot = Join-Path $logsRoot (Join-Path $testRunId 'tests')
}
else {
    $testLogRoot = Join-Path (Resolve-Path -LiteralPath $RunRoot).Path 'tests'
}

New-Item -ItemType Directory -Path $testLogRoot -Force | Out-Null
$stdoutPath = Join-Path $testLogRoot 'stdout.txt'
$stderrPath = Join-Path $testLogRoot 'stderr.txt'
$resultPath = Join-Path $testLogRoot 'result.json'

$output = @()
$errorText = ''
$passed = $false

try {
    $output = @(& $testPath)
    if (-not [string]::IsNullOrWhiteSpace($RunRoot)) {
        $output += @(& $runnerPath -Finalize -RunRoot $RunRoot)
    }
    $passed = $true
}
catch {
    $errorText = ($_ | Out-String).Trim()
}

$output | Set-Content -LiteralPath $stdoutPath -Encoding UTF8
$errorText | Set-Content -LiteralPath $stderrPath -Encoding UTF8

[ordered]@{
    test = 'Task1'
    passed = $passed
    runRootValidated = if ([string]::IsNullOrWhiteSpace($RunRoot)) { $null } else { $RunRoot }
    stdout = 'stdout.txt'
    stderr = 'stderr.txt'
    completedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
} |
    ConvertTo-Json -Depth 4 |
    Set-Content -LiteralPath $resultPath -Encoding UTF8

if (-not $passed) {
    throw "Task 1 tests failed. See $testLogRoot"
}

Write-Output 'PASS Task1Tests'
Write-Output $testLogRoot
