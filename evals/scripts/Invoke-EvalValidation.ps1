[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [string]$VerifyRunDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-UtcRunId { (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') }
function Get-GitCommit {
    try { return ((& git -C $RepositoryRoot rev-parse HEAD 2>$null).Trim()) } catch { return 'unavailable' }
}
function Save-Json([object]$Value, [string]$Path) {
    $Value | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding utf8
}
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
function Test-CompleteRunLogs([string]$RunDirectory) {
    $manifestPath = Join-Path $RunDirectory 'run-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Complete run is missing run-manifest.json.' }
    if (-not (Test-Path -LiteralPath (Join-Path $RunDirectory 'checksums.sha256') -PathType Leaf)) { throw 'Complete run is missing checksums.sha256.' }
    $completeManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    foreach($field in 'runId','startedAtUtc','endedAtUtc','executionUser','gitCommit','commandVersions','isolationPrecheck','status','exitCode','steps','cases') { if($null -eq $completeManifest.$field){throw "Manifest is missing $field."} }
    if($completeManifest.runId -notmatch '^\d{8}T\d{6}Z$'){throw 'Manifest runId is invalid.'}
    if($completeManifest.status -notin 'passed','failed','BLOCKED_NOT_RUN','completed-needs-human-review'){throw 'Manifest status is invalid.'}
    if (@($completeManifest.steps).Count -eq 0) { throw 'Complete run manifest has no steps.' }
    foreach ($step in @($completeManifest.steps)) {
        if ([string]::IsNullOrWhiteSpace($step.log) -or -not (Test-Path -LiteralPath (Join-Path $RunDirectory $step.log) -PathType Leaf)) {
            throw "Run step '$($step.name)' is missing its declared log."
        }
    }
    if ((@($completeManifest.cases.caseId) | Sort-Object) -join ',' -ne '01,02,03,04,05,06,07,08,09') { throw 'Complete run must record exactly unique case IDs 01..09.' }
    foreach ($case in @($completeManifest.cases)) {
        $caseDirectory = Join-Path $RunDirectory "cases/$($case.caseId)"
        @('events.jsonl', 'stderr.log', 'final.md', 'result.json') | ForEach-Object {
            if (-not (Test-Path -LiteralPath (Join-Path $caseDirectory $_) -PathType Leaf)) { throw "Case $($case.caseId) is missing $_." }
        }
        $result = Get-Content -LiteralPath (Join-Path $caseDirectory 'result.json') -Raw | ConvertFrom-Json
        if(@($result.observableAssertions).Count -lt 1 -or @($result.observableAssertions|Where-Object{$_.id -notmatch '^case-\d{2}-observable-\d+$' -or $_.status -notin 'pass','fail','needs-human-review'}).Count){throw "Case $($case.caseId) has invalid observable assertions."}
        if ((@($result.rubric.id)|Sort-Object) -join ',' -ne '1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17' -or @($result.rubric|Where-Object{$_.score -notin 0,1,'needs-human-review'}).Count) { throw "Case $($case.caseId) has invalid rubric results." }
    }
    $checksumLines=Get-Content -LiteralPath (Join-Path $RunDirectory 'checksums.sha256');if($checksumLines.Count -lt 1){throw 'Checksum file is empty.'};foreach($line in $checksumLines){if($line -notmatch '^([a-f0-9]{64})\s\s(.+)$'){throw 'Checksum format is invalid.'};$path=Join-Path $RepositoryRoot $Matches[2];if(-not(Test-Path $path)){throw 'Checksum path is not covered by repository.'};if((Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Matches[1]){throw 'Checksum does not match file.'}}
}

$runId = Get-UtcRunId
$runDirectory = Join-Path $RepositoryRoot "evals/logs/$runId"
if (Test-Path -LiteralPath $runDirectory) { throw "UTC run ID collision: $runId. Retry the command." }
New-Item -ItemType Directory -Force -Path (Join-Path $runDirectory 'steps') | Out-Null
$manifestPath = Join-Path $runDirectory 'run-manifest.json'
$manifest = [ordered]@{
    runId = $runId
    startedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    endedAtUtc = $null
    executionUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    gitCommit = Get-GitCommit
    commandVersions = [ordered]@{ powershell = $PSVersionTable.PSVersion.ToString(); codex = 'not-needed-for-structure-validation' }
    isolationPrecheck = [ordered]@{ status = 'not-applicable'; detail = 'This command only validates repository structure.' }
    status = 'running'
    exitCode = $null
    steps = @()
}
Save-Json $manifest $manifestPath

$test = Join-Path $RepositoryRoot 'evals/tests/Test-EvalStructure.ps1'
$output = @(& pwsh -NoProfile -File $test -RepositoryRoot $RepositoryRoot 2>&1 | ForEach-Object { $_.ToString() })
$exitCode = $LASTEXITCODE
$stderr = @($output | Where-Object { $_ -match '(^|\s)(Exception|Error|FAIL:)' })
$stdout = @($output | Where-Object { $_ -notmatch '(^|\s)(Exception|Error|FAIL:)' })
$conclusion = if ($exitCode -eq 0) { 'passed' } else { 'failed' }
Write-StepLog (Join-Path $runDirectory 'steps/01-structure-validation.log') 'pwsh -NoProfile -File evals/tests/Test-EvalStructure.ps1' $stdout $stderr $exitCode $conclusion
$manifest.steps = @([ordered]@{ name = 'structure-validation'; log = 'steps/01-structure-validation.log'; status = $conclusion; exitCode = $exitCode })
if ($exitCode -eq 0 -and $VerifyRunDirectory) {
    try {
        Test-CompleteRunLogs (Resolve-Path -LiteralPath $VerifyRunDirectory).Path
        Write-StepLog (Join-Path $runDirectory 'steps/02-complete-run-log-contract.log') "Validate $VerifyRunDirectory" @('Complete run contains all declared step and case logs.') @() 0 'passed'
        $manifest.steps += [ordered]@{ name = 'complete-run-log-contract'; log = 'steps/02-complete-run-log-contract.log'; status = 'passed'; exitCode = 0 }
    } catch {
        Write-StepLog (Join-Path $runDirectory 'steps/02-complete-run-log-contract.log') "Validate $VerifyRunDirectory" @() @($_.Exception.Message) 1 'failed'
        $manifest.steps += [ordered]@{ name = 'complete-run-log-contract'; log = 'steps/02-complete-run-log-contract.log'; status = 'failed'; exitCode = 1 }
        $exitCode = 1
    }
}
$manifest.status = if ($exitCode -eq 0) { 'passed' } else { 'failed' }
$manifest.exitCode = $exitCode
$manifest.endedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
Save-Json $manifest $manifestPath

$checksumPaths = @(
    Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot 'evals/fixtures/synthetic-corpus') -Recurse -File
    Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot 'evals/cases') -File
    Get-Item -LiteralPath (Join-Path $RepositoryRoot 'evals/rubric.md')
    Get-ChildItem -LiteralPath $runDirectory -Recurse -File | Where-Object { $_.Name -ne 'checksums.sha256' }
)
$checksumPaths | Sort-Object FullName | ForEach-Object {
    $relative = $_.FullName.Substring($RepositoryRoot.Length).TrimStart('\', '/') -replace '\\', '/'
    "$(($_ | Get-FileHash -Algorithm SHA256).Hash.ToLowerInvariant())  $relative"
} | Set-Content -LiteralPath (Join-Path $runDirectory 'checksums.sha256') -Encoding utf8

Write-Output "VALIDATION_RUN_ID=$runId"
exit $exitCode
