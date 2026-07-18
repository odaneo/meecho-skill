[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [string[]]$TestFiles
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'EvalAudit.psm1') -Force

function Save-Manifest {
    $manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $manifestPath -Encoding utf8
}

$run = New-EvalRunDirectory -RepositoryRoot $RepositoryRoot
$git = Invoke-EvalProcess -FilePath 'git' -ArgumentList @('-C', $RepositoryRoot, 'rev-parse', 'HEAD')
$gitCommit = if ($git.ExitCode -eq 0) { ($git.Stdout -join "`n").Trim() } else { 'unavailable' }
$manifestPath = Join-Path $run.Path 'run-manifest.json'
$manifest = [ordered]@{
    runId = $run.Id
    startedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
    endedAtUtc = $null
    executionUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    gitCommit = $gitCommit
    commandVersions = [ordered]@{ powershell = $PSVersionTable.PSVersion.ToString() }
    isolationPrecheck = [ordered]@{ status = 'not-applicable' }
    status = 'running'
    exitCode = $null
    steps = @()
    cases = @()
}
Save-Manifest

if ($null -eq $TestFiles -or $TestFiles.Count -eq 0) {
    $TestFiles = @(
        'Test-EvalStructure.ps1',
        'Test-ReviewFixes.ps1',
        'Test-RunLogContract.ps1',
        'Test-BaselinePreflight.ps1',
        'Test-CompleteRunValidation.ps1',
        'Test-AuditInfrastructure.ps1'
    ) | ForEach-Object { Join-Path $RepositoryRoot "evals/tests/$_" }
}

$failed = 0
$index = 0
foreach ($testFile in $TestFiles) {
    $index++
    $resolvedTest = (Resolve-Path -LiteralPath $testFile).Path
    $result = Invoke-EvalProcess -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @(
        '-NoProfile', '-File', $resolvedTest, '-RepositoryRoot', $RepositoryRoot
    )
    $conclusion = if ($result.ExitCode -eq 0) { 'passed' } else { 'failed' }
    $safeName = ([System.IO.Path]::GetFileNameWithoutExtension($resolvedTest) -replace '[^A-Za-z0-9._-]', '-')
    $log = 'steps/{0:D2}-{1}.log' -f $index, $safeName
    $action = "pwsh -NoProfile -File $([System.IO.Path]::GetFileName($resolvedTest)) -RepositoryRoot <repository-root>"
    Write-EvalStepLog -Path (Join-Path $run.Path $log) -Action $action -Stdout $result.Stdout -Stderr $result.Stderr -ExitCode $result.ExitCode -Conclusion $conclusion -StartedAtUtc $result.StartedAtUtc -EndedAtUtc $result.EndedAtUtc
    $manifest.steps += [ordered]@{
        name = [System.IO.Path]::GetFileName($resolvedTest)
        log = $log
        exitCode = $result.ExitCode
        status = $conclusion
        conclusion = $conclusion
    }
    if ($result.ExitCode -ne 0) { $failed++ }
    Save-Manifest
}

$manifest.status = if ($failed -eq 0) { 'passed' } else { 'failed' }
$manifest.exitCode = if ($failed -eq 0) { 0 } else { 1 }
$manifest.endedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
Save-Manifest
Write-EvalChecksums -RepositoryRoot $RepositoryRoot -RunDirectory $run.Path
Write-Output "TASK1_TEST_RUN_ID=$($run.Id)"
exit $manifest.exitCode
