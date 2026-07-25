[CmdletBinding()]
param(
    [ValidatePattern('^\d{8}T\d{9}Z-[0-9a-f]{8}$')]
    [string] $RunId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $RunId) {
    $RunId = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
}

$logRoot = Join-Path $repoRoot "evals/logs/$RunId/task1-tests"
$lockRoot = Join-Path $repoRoot 'evals/logs/.locks'
[void][IO.Directory]::CreateDirectory($lockRoot)
$lockPath = Join-Path $lockRoot "$RunId.task1-tests.lock"
$lockStream = $null
try {
    $lockStream = [IO.File]::Open(
        $lockPath,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None
    )
    if (Test-Path -LiteralPath $logRoot) {
        throw 'TASK1_TEST_RUN_ALREADY_EXISTS'
    }
    [void][IO.Directory]::CreateDirectory($logRoot)
    $lockBytes = [Text.Encoding]::UTF8.GetBytes($RunId)
    $lockStream.Write($lockBytes, 0, $lockBytes.Length)
    $lockStream.Flush($true)
}
finally {
    if ($null -ne $lockStream) {
        $lockStream.Dispose()
    }
}

$testNames = @(
    'Test-EvalCapsule.ps1',
    'Test-CaseIsolation.ps1',
    'Test-AuditInfrastructure.ps1',
    'Test-PairedEvaluation.ps1',
    'Test-BaselinePreflight.ps1',
    'Test-CompleteRunValidation.ps1',
    'Test-RunLogContract.ps1',
    'Test-EvalStructure.ps1',
    'Test-ReviewFixes.ps1'
)

$results = [Collections.Generic.List[object]]::new()
$testTimeoutSeconds = 300
foreach ($testName in $testNames) {
    $testPath = Join-Path $repoRoot "evals/tests/$testName"
    $stepName = [IO.Path]::GetFileNameWithoutExtension($testName)
    $stdoutPath = Join-Path $logRoot "$stepName.stdout.log"
    $stderrPath = Join-Path $logRoot "$stepName.stderr.log"
    $recordPath = Join-Path $logRoot "$stepName.result.json"

    $startedAt = (Get-Date).ToUniversalTime()
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Join-Path $PSHOME 'pwsh.exe'
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $testPath)) {
        [void] $startInfo.ArgumentList.Add($argument)
    }

    try {
        $process = [Diagnostics.Process]::Start($startInfo)
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $timedOut = -not $process.WaitForExit($testTimeoutSeconds * 1000)
        if ($timedOut) {
            $process.Kill($true)
            $process.WaitForExit()
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($timedOut) {
            $stderr = ($stderr.TrimEnd() + "`nTest timed out after $testTimeoutSeconds seconds.").TrimStart()
            $exitCode = 124
        }
        else {
            $exitCode = $process.ExitCode
        }
        $process.Dispose()
    }
    catch {
        $stdout = ''
        $stderr = $_.Exception.ToString()
        $exitCode = 255
        $timedOut = $false
    }
    $endedAt = (Get-Date).ToUniversalTime()
    Set-Content -LiteralPath $stdoutPath -Value $stdout -Encoding UTF8
    Set-Content -LiteralPath $stderrPath -Value $stderr -Encoding UTF8

    $record = [ordered]@{
        test = $testName
        exitCode = $exitCode
        timedOut = $timedOut
        startedAtUtc = $startedAt.ToString('o')
        endedAtUtc = $endedAt.ToString('o')
        stdoutPath = (Resolve-Path -Relative $stdoutPath).Replace('\', '/')
        stderrPath = (Resolve-Path -Relative $stderrPath).Replace('\', '/')
        stdoutSha256 = (Get-FileHash -LiteralPath $stdoutPath -Algorithm SHA256).Hash.ToLowerInvariant()
        stderrSha256 = (Get-FileHash -LiteralPath $stderrPath -Algorithm SHA256).Hash.ToLowerInvariant()
        passed = ($exitCode -eq 0)
    }
    $record | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $recordPath -Encoding UTF8
    $results.Add([pscustomobject]$record)
}

$manifestPath = Join-Path $logRoot 'run-manifest.json'
$manifest = [ordered]@{
    schemaVersion = 1
    kind = 'meecho-task1-test-run'
    runId = $RunId
    status = if (@($results | Where-Object { -not $_.passed }).Count -eq 0) { 'PASS' } else { 'FAIL' }
    testNames = $testNames
    passed = @($results | Where-Object passed).Count
    failed = @($results | Where-Object { -not $_.passed }).Count
    results = @($results)
}
$manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

[ordered]@{
    RunId = $RunId
    Status = $manifest.status
    Passed = $manifest.passed
    Failed = $manifest.failed
    ManifestPath = $manifestPath
} | ConvertTo-Json -Compress

if ($manifest.status -ne 'PASS') {
    exit 1
}
