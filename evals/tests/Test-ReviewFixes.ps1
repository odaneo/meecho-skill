Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'TestSupport.psm1') -Force
$repoRoot = Get-MeechoRepoRoot
Import-Module (Join-Path $repoRoot 'evals/scripts/EvalCapsule.psm1') -Force
Import-Module (Join-Path $repoRoot 'evals/scripts/EvalAudit.psm1') -Force
Import-Module (Join-Path $repoRoot 'evals/scripts/CaseStaging.psm1') -Force

$testRoot = New-MeechoTestRoot
$previousLocalAppData = $env:LOCALAPPDATA
try {
    $env:LOCALAPPDATA = Join-Path $testRoot 'local'
    New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null

    $runId = '20260725T060000000Z-7654abcd'
    $context = New-MeechoEvalContext -Mode control -RunId $runId -CaseId case-01 -ScenarioId read -Model gpt-test -ReasoningEffort high -PermissionMode read
    $outside = Join-Path $testRoot 'outside'
    New-Item -ItemType Directory -Path $outside | Out-Null
    $sentinel = Join-Path $outside 'sentinel.txt'
    Set-Content -LiteralPath $sentinel -Value 'must-survive' -Encoding UTF8
    $sentinelHash = (Get-FileHash -LiteralPath $sentinel -Algorithm SHA256).Hash

    $junction = Join-Path $context.ScenarioRoot 'escape-junction'
    New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
    Assert-Throws { Get-MeechoFileInventory -Path $context.ScenarioRoot } 'Inventory must reject a reparse point instead of traversing it.'
    Assert-Throws { Remove-MeechoEvalRun -RunId $runId -Confirm } 'Run deletion must reject a reparse point instead of traversing it.'
    Assert-True (Test-Path -LiteralPath $sentinel -PathType Leaf) 'Outside sentinel was deleted through a junction.'
    Assert-Equal $sentinelHash (Get-FileHash -LiteralPath $sentinel -Algorithm SHA256).Hash 'Outside sentinel was modified through a junction.'

    Remove-Item -LiteralPath $junction -Force
    Remove-MeechoEvalRun -RunId $runId -Confirm
    Assert-True (Test-Path -LiteralPath $sentinel -PathType Leaf) 'Safe run deletion touched an outside directory.'

    $duplicateCase = Join-Path $testRoot 'duplicate-case.md'
    @'
# Duplicate scenario
<!-- meecho-eval
{"caseId":"case-01","scenarios":[{"id":"read","permissionMode":"read"},{"id":"read","permissionMode":"read"}],"accessibleFiles":[]}
-->
## User request
x
## Accessible files
x
## Forbidden state
x
## Observable assertions
x
'@ | Set-Content -LiteralPath $duplicateCase -Encoding UTF8
    Assert-Throws { Test-MeechoEvalCaseRegistry -Paths @($duplicateCase) } 'Duplicate scenario ids in one case must fail matrix preflight.'

    $metadataPath = Join-Path $repoRoot 'evals/fixtures/reviewer-metadata.json'
    $metadata = Read-MeechoJson -Path $metadataPath
    Assert-True (@($metadata.sealedFiles).Count -ge 1) 'Reviewer metadata must identify the sealed fixture family.'
    Assert-False (($metadata | ConvertTo-Json -Depth 20) -match '灯塔|句子|正文') 'Reviewer metadata must not embed sealed prose.'
    $sealedRoot = Join-Path $repoRoot 'evals/fixtures/synthetic-corpus/sealed'
    $actualSealedFiles = @(Get-ChildItem -LiteralPath $sealedRoot -Recurse -File | Sort-Object FullName)
    Assert-Equal $actualSealedFiles.Count @($metadata.sealedFiles).Count 'Reviewer metadata must enumerate the complete sealed file set, with no omissions or extras.'
    foreach ($sealed in $metadata.sealedFiles) {
        Assert-Matches $sealed.sha256 '^[0-9a-f]{64}$' 'Sealed fixture metadata needs a content hash.'
        Assert-Matches $sealed.path '^evals/fixtures/synthetic-corpus/sealed/' 'Reviewer metadata may identify only the sealed fixture directory.'
        $sealedPath = Join-Path $repoRoot ([string] $sealed.path)
        Assert-True (Test-Path -LiteralPath $sealedPath -PathType Leaf) 'Reviewer metadata points at a missing sealed file.'
        Assert-Equal ([string] $sealed.sha256) ((Get-FileHash -LiteralPath $sealedPath -Algorithm SHA256).Hash.ToLowerInvariant()) 'Reviewer metadata sealed hash does not match the actual file.'
    }

    $baselineSource = Get-Content -LiteralPath (Join-Path $repoRoot 'evals/scripts/Invoke-Baseline.ps1') -Raw -Encoding UTF8
    Assert-Matches $baselineSource '\$realProfileUnchanged\s*=\s*Add-MeechoRealProfileTerminalEvidence' 'Terminal profile evidence must affect the returned status.'
    Assert-Matches $baselineSource 'if\s*\(-not\s+\$realProfileUnchanged\)\s*\{\s*\$manifest\.status\s*=\s*''BLOCKED_NOT_RUN''' 'A changed real profile must override AUTH_REQUIRED.'
    Assert-Matches $baselineSource 'SUMMARY_VALIDATION_FAILED''\)\s*\r?\n\s*\$manifest\.status\s*=\s*''BLOCKED_NOT_RUN''' 'A summary failure must override AUTH_REQUIRED.'
    Assert-False ($baselineSource.Contains('/$($scenario.id)/$invocationId')) 'Case infrastructure failure codes must not use path-like slash separators.'

    $collisionRunId = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $collisionRoot = Join-Path $repoRoot "evals/logs/$collisionRunId/task1-tests"
    New-Item -ItemType Directory -Path $collisionRoot -Force | Out-Null
    $collisionSentinel = Join-Path $collisionRoot 'sentinel.txt'
    [IO.File]::WriteAllText($collisionSentinel, 'must-survive', [Text.UTF8Encoding]::new($false))
    $collisionSentinelHash = (Get-FileHash -LiteralPath $collisionSentinel -Algorithm SHA256).Hash
    $runnerStartInfo = [Diagnostics.ProcessStartInfo]::new()
    $runnerStartInfo.FileName = Join-Path $PSHOME 'pwsh.exe'
    $runnerStartInfo.UseShellExecute = $false
    $runnerStartInfo.RedirectStandardOutput = $true
    $runnerStartInfo.RedirectStandardError = $true
    foreach ($argument in @(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-File',
        (Join-Path $repoRoot 'evals/scripts/Invoke-Task1Tests.ps1'),
        '-RunId',
        $collisionRunId
    )) {
        [void] $runnerStartInfo.ArgumentList.Add($argument)
    }
    $runnerProcess = [Diagnostics.Process]::Start($runnerStartInfo)
    $runnerStdoutTask = $runnerProcess.StandardOutput.ReadToEndAsync()
    $runnerStderrTask = $runnerProcess.StandardError.ReadToEndAsync()
    $runnerTimedOut = -not $runnerProcess.WaitForExit(30000)
    if ($runnerTimedOut) {
        $runnerProcess.Kill($true)
        $runnerProcess.WaitForExit()
    }
    $runnerStdout = $runnerStdoutTask.GetAwaiter().GetResult()
    $runnerStderr = $runnerStderrTask.GetAwaiter().GetResult()
    $runnerExitCode = if ($runnerTimedOut) { 124 } else { $runnerProcess.ExitCode }
    $runnerProcess.Dispose()
    Assert-False $runnerTimedOut 'A colliding Task 1 test run must fail immediately.'
    Assert-True ($runnerExitCode -ne 0) 'A colliding Task 1 test run must be rejected.'
    Assert-Equal $collisionSentinelHash (Get-FileHash -LiteralPath $collisionSentinel -Algorithm SHA256).Hash 'A colliding test run overwrote existing evidence.'
    Assert-Matches ($runnerStdout + $runnerStderr) 'TASK1_TEST_RUN_ALREADY_EXISTS' 'A colliding test run must report the exact refusal reason.'
}
finally {
    $env:LOCALAPPDATA = $previousLocalAppData
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Output 'PASS Test-ReviewFixes'
