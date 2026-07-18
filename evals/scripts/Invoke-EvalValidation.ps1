[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [string]$VerifyRunDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'EvalAudit.psm1') -Force

function Save-Json([object]$Value, [string]$Path) {
    $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Get-GitCommit {
    $result = Invoke-EvalProcess -FilePath 'git' -ArgumentList @('-C', $RepositoryRoot, 'rev-parse', 'HEAD')
    if ($result.ExitCode -ne 0) { return 'unavailable' }
    return (($result.Stdout -join "`n").Trim())
}

function ConvertFrom-ManifestUtc([string]$Value, [string]$FieldName) {
    $parsed = [datetimeoffset]::MinValue
    if ([string]::IsNullOrWhiteSpace($Value) -or -not [datetimeoffset]::TryParse(
        $Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$parsed
    ) -or $parsed.Offset -ne [timespan]::Zero) {
        throw "Manifest $FieldName must be an ISO UTC timestamp."
    }
    return $parsed
}

function Get-RequiredProperty([object]$Value, [string]$Name, [string]$Context) {
    $property = $Value.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { throw "$Context is missing $Name." }
    return $property.Value
}

function Resolve-RunFile([string]$RunDirectory, [string]$RelativePath) {
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [System.IO.Path]::IsPathFullyQualified($RelativePath)) {
        throw 'Run-relative path is invalid.'
    }
    $runRoot = [System.IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
    $fullPath = Resolve-EvalRepositoryPath -RepositoryRoot $RepositoryRoot -Path (Join-Path $runRoot $RelativePath)
    if (-not $fullPath.StartsWith($runRoot + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Declared run file escapes the run directory.'
    }
    return $fullPath
}

function Test-CompleteRunLogs([string]$RunDirectory) {
    $runRoot = Resolve-EvalRepositoryPath -RepositoryRoot $RepositoryRoot -Path $RunDirectory
    $manifestPath = Join-Path $runRoot 'run-manifest.json'
    $checksumPath = Join-Path $runRoot 'checksums.sha256'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Complete run is missing run-manifest.json.' }
    if (-not (Test-Path -LiteralPath $checksumPath -PathType Leaf)) { throw 'Complete run is missing checksums.sha256.' }
    $completeManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -DateKind String

    foreach ($field in 'runId','startedAtUtc','endedAtUtc','executionUser','gitCommit','commandVersions','isolationPrecheck','status','exitCode','steps','cases') {
        [void](Get-RequiredProperty -Value $completeManifest -Name $field -Context 'Manifest')
    }
    if ([string]$completeManifest.runId -notmatch '^\d{8}T\d{6}Z$') { throw 'Manifest runId is invalid.' }
    $startedAt = ConvertFrom-ManifestUtc -Value ([string]$completeManifest.startedAtUtc) -FieldName 'startedAtUtc'
    $endedAt = ConvertFrom-ManifestUtc -Value ([string]$completeManifest.endedAtUtc) -FieldName 'endedAtUtc'
    if ($endedAt -lt $startedAt) { throw 'Manifest endedAtUtc precedes startedAtUtc.' }
    if ([string]::IsNullOrWhiteSpace([string]$completeManifest.executionUser)) { throw 'Manifest executionUser is empty.' }
    if ([string]::IsNullOrWhiteSpace([string]$completeManifest.gitCommit)) { throw 'Manifest gitCommit is empty.' }
    if ($completeManifest.commandVersions -is [string] -or $completeManifest.isolationPrecheck -is [string]) { throw 'Manifest object fields are invalid.' }
    if ([string]$completeManifest.isolationPrecheck.status -notin 'passed','failed','not-applicable') { throw 'Manifest isolationPrecheck status is invalid.' }
    if ([string]$completeManifest.status -notin 'passed','failed','BLOCKED_NOT_RUN','completed-needs-human-review') { throw 'Manifest status is invalid.' }
    $manifestExitCode = 0
    if (-not [int]::TryParse([string]$completeManifest.exitCode, [ref]$manifestExitCode)) { throw 'Manifest exitCode is not numeric.' }
    if (($manifestExitCode -eq 0) -ne ([string]$completeManifest.status -in 'passed','completed-needs-human-review')) {
        throw 'Manifest status does not match exitCode.'
    }

    if (@($completeManifest.steps).Count -eq 0) { throw 'Complete run manifest has no steps.' }
    $stepNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $stepLogs = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($step in @($completeManifest.steps)) {
        foreach ($field in 'name','log','exitCode','status','conclusion') { [void](Get-RequiredProperty -Value $step -Name $field -Context 'Manifest step') }
        if ([string]::IsNullOrWhiteSpace([string]$step.name) -or -not $stepNames.Add([string]$step.name)) { throw 'Manifest step name is empty or duplicated.' }
        if (-not $stepLogs.Add([string]$step.log)) { throw 'Manifest step log is duplicated.' }
        $declaredLog = Resolve-RunFile -RunDirectory $runRoot -RelativePath ([string]$step.log)
        if (-not (Test-Path -LiteralPath $declaredLog -PathType Leaf)) { throw "Run step '$($step.name)' is missing its declared log." }
        $logged = Read-EvalStepLog -Path $declaredLog
        $declaredExitCode = 0
        if (-not [int]::TryParse([string]$step.exitCode, [ref]$declaredExitCode)) { throw "Run step '$($step.name)' has a nonnumeric exitCode." }
        if ([string]$step.status -notin 'passed','failed' -or [string]$step.conclusion -notin 'passed','failed') { throw "Run step '$($step.name)' has an invalid status or conclusion." }
        if ($declaredExitCode -ne $logged.ExitCode -or [string]$step.status -ne $logged.Conclusion -or [string]$step.conclusion -ne $logged.Conclusion) {
            throw "Run step '$($step.name)' manifest fields do not match its log."
        }
    }

    $caseIds = @($completeManifest.cases | ForEach-Object { [string]$_.caseId })
    if (($caseIds | Sort-Object) -join ',' -ne '01,02,03,04,05,06,07,08,09') { throw 'Complete run must record exactly unique case IDs 01..09.' }
    foreach ($case in @($completeManifest.cases)) {
        foreach ($field in 'caseId','status','exitCode') { [void](Get-RequiredProperty -Value $case -Name $field -Context 'Manifest case') }
        $caseId = [string]$case.caseId
        $caseExitCode = 0
        if (-not [int]::TryParse([string]$case.exitCode, [ref]$caseExitCode)) { throw "Case $caseId exitCode is not numeric." }
        if ([string]$case.status -notin 'failed','completed-needs-human-review') { throw "Case $caseId status is invalid." }
        if (($caseExitCode -eq 0) -ne ([string]$case.status -eq 'completed-needs-human-review')) { throw "Case $caseId status does not match exitCode." }
        $caseDirectory = Join-Path $runRoot "cases/$caseId"
        foreach ($name in 'events.jsonl','stderr.log','final.md','result.json') {
            if (-not (Test-Path -LiteralPath (Join-Path $caseDirectory $name) -PathType Leaf)) { throw "Case $caseId is missing $name." }
        }
        $result = Get-Content -LiteralPath (Join-Path $caseDirectory 'result.json') -Raw | ConvertFrom-Json
        if ([string]$result.caseId -ne $caseId) { throw "Case $caseId result has a mismatched caseId." }
        $assertions = @($result.observableAssertions)
        if ($assertions.Count -lt 1) { throw "Case $caseId has no observable assertions." }
        $assertionIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($assertion in $assertions) {
            if ([string]$assertion.id -notmatch "^case-$caseId-observable-\d+$" -or
                [string]$assertion.status -notin 'pass','fail','needs-human-review' -or
                -not $assertionIds.Add([string]$assertion.id)) { throw "Case $caseId has invalid observable assertions." }
        }
        $rubricIds = @($result.rubric | ForEach-Object { [int]$_.id })
        if (($rubricIds | Sort-Object) -join ',' -ne '1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17' -or
            @($result.rubric | Where-Object { $_.score -notin 0,1,'needs-human-review' }).Count -ne 0) {
            throw "Case $caseId has invalid rubric results."
        }
    }

    $expectedFiles = @(Get-EvalChecksumExpectedFiles -RepositoryRoot $RepositoryRoot -RunDirectory $runRoot)
    $expected = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $expectedFiles) { [void]$expected.Add([System.IO.Path]::GetFullPath($file.FullName)) }
    $checksumLines = @(Get-Content -LiteralPath $checksumPath)
    if ($checksumLines.Count -eq 0) { throw 'Checksum file is empty.' }
    $covered = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in $checksumLines) {
        if ($line -notmatch '^([a-f0-9]{64})  (.+)$') { throw 'Checksum format is invalid.' }
        $declaredHash = $Matches[1]
        $relativePath = $Matches[2]
        if ([System.IO.Path]::IsPathFullyQualified($relativePath)) { throw 'Checksum path must be repository-relative.' }
        $fullPath = Resolve-EvalRepositoryPath -RepositoryRoot $RepositoryRoot -Path (Join-Path $RepositoryRoot $relativePath)
        $canonicalRelative = [System.IO.Path]::GetRelativePath([System.IO.Path]::GetFullPath($RepositoryRoot), $fullPath) -replace '\\','/'
        if ($canonicalRelative -cne $relativePath) { throw 'Checksum path is not canonically normalized.' }
        if (-not $covered.Add($fullPath)) { throw 'Checksum path is duplicated.' }
        if (-not $expected.Contains($fullPath)) { throw 'Checksum set contains an unexpected file.' }
        if ((Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $declaredHash) { throw 'Checksum does not match file.' }
    }
    if ($covered.Count -ne $expected.Count) { throw 'Checksum set omits required files.' }
    foreach ($file in $expected) { if (-not $covered.Contains($file)) { throw 'Checksum set omits required files.' } }
}

$run = New-EvalRunDirectory -RepositoryRoot $RepositoryRoot
$manifestPath = Join-Path $run.Path 'run-manifest.json'
$manifest = [ordered]@{
    runId = $run.Id
    startedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
    endedAtUtc = $null
    executionUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    gitCommit = Get-GitCommit
    commandVersions = [ordered]@{ powershell = $PSVersionTable.PSVersion.ToString(); codex = 'not-needed-for-structure-validation' }
    isolationPrecheck = [ordered]@{ status = 'not-applicable'; detail = 'This command only validates repository structure.' }
    status = 'running'
    exitCode = $null
    steps = @()
    cases = @()
}
Save-Json $manifest $manifestPath

$structure = Invoke-EvalProcess -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @(
    '-NoProfile', '-File', (Join-Path $RepositoryRoot 'evals/tests/Test-EvalStructure.ps1'), '-RepositoryRoot', $RepositoryRoot
)
$structureConclusion = if ($structure.ExitCode -eq 0) { 'passed' } else { 'failed' }
Write-EvalStepLog -Path (Join-Path $run.Path 'steps/01-structure-validation.log') -Action 'pwsh -NoProfile -File evals/tests/Test-EvalStructure.ps1' -Stdout $structure.Stdout -Stderr $structure.Stderr -ExitCode $structure.ExitCode -Conclusion $structureConclusion -StartedAtUtc $structure.StartedAtUtc -EndedAtUtc $structure.EndedAtUtc
$manifest.steps = @([ordered]@{ name = 'structure-validation'; log = 'steps/01-structure-validation.log'; status = $structureConclusion; conclusion = $structureConclusion; exitCode = $structure.ExitCode })
$exitCode = $structure.ExitCode

if ($exitCode -eq 0 -and $VerifyRunDirectory) {
    $verifyStart = [datetimeoffset]::UtcNow
    try {
        Test-CompleteRunLogs (Resolve-Path -LiteralPath $VerifyRunDirectory).Path
        $verifyEnd = [datetimeoffset]::UtcNow
        Write-EvalStepLog -Path (Join-Path $run.Path 'steps/02-complete-run-log-contract.log') -Action "Validate $VerifyRunDirectory" -Stdout @('Complete run satisfies the strict manifest, step, case, and checksum contract.') -Stderr @() -ExitCode 0 -Conclusion 'passed' -StartedAtUtc $verifyStart -EndedAtUtc $verifyEnd
        $manifest.steps += [ordered]@{ name = 'complete-run-log-contract'; log = 'steps/02-complete-run-log-contract.log'; status = 'passed'; conclusion = 'passed'; exitCode = 0 }
    } catch {
        $verifyEnd = [datetimeoffset]::UtcNow
        Write-EvalStepLog -Path (Join-Path $run.Path 'steps/02-complete-run-log-contract.log') -Action "Validate $VerifyRunDirectory" -Stdout @() -Stderr @($_.Exception.Message) -ExitCode 1 -Conclusion 'failed' -StartedAtUtc $verifyStart -EndedAtUtc $verifyEnd
        $manifest.steps += [ordered]@{ name = 'complete-run-log-contract'; log = 'steps/02-complete-run-log-contract.log'; status = 'failed'; conclusion = 'failed'; exitCode = 1 }
        $exitCode = 1
    }
}

$manifest.status = if ($exitCode -eq 0) { 'passed' } else { 'failed' }
$manifest.exitCode = $exitCode
$manifest.endedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
Save-Json $manifest $manifestPath
Write-EvalChecksums -RepositoryRoot $RepositoryRoot -RunDirectory $run.Path
Write-Output "VALIDATION_RUN_ID=$($run.Id)"
exit $exitCode
