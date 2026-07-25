[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ManifestPath,

    [string] $OutputPath = (
        Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path 'results/baseline-summary.md'
    )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'EvalAudit.psm1') -Force

function Invoke-FullManifestValidation {
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $validatorPath = Join-Path $PSScriptRoot 'Invoke-EvalValidation.ps1'
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Join-Path $PSHOME 'pwsh.exe'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @(
        '-NoLogo', '-NoProfile', '-NonInteractive',
        '-File', $validatorPath,
        '-ManifestPath', $Path
    )) {
        [void] $startInfo.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::Start($startInfo)
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw 'Full manifest validation timed out.'
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            $detail = if ($stdout.Trim()) { $stdout.Trim() } else { $stderr.Trim() }
            throw "Full manifest validation failed: $detail"
        }
        return $stdout.Trim() | ConvertFrom-Json -Depth 50
    }
    finally {
        $process.Dispose()
    }
}

function Get-PropertyValue {
    param(
        [Parameter(Mandatory)]
        [object] $InputObject,

        [Parameter(Mandatory)]
        [string] $Name,

        [AllowNull()]
        [object] $DefaultValue = $null
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $DefaultValue
    }
    return $property.Value
}

function ConvertTo-SafeSummaryCell {
    param(
        [AllowNull()]
        [object] $Value,

        [string] $Fallback = '—'
    )

    if ($null -eq $Value) {
        return $Fallback
    }
    $text = ([string] $Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $Fallback
    }

    $text = $text -replace '[\r\n\t]+', ' '
    $text = $text -replace '(?i)[A-Z]:[\\/][^\s|`]+', '[redacted-path]'
    $text = $text -replace '(?i)\\\\[^\\\s]+\\[^\s|`]+', '[redacted-path]'
    $text = $text -replace '(?i)/(?:Users|home|mnt)/[^\s|`]+', '[redacted-path]'
    $text = $text -replace '(?i)auth\.json', '[redacted]'
    $text = $text.Replace('|', '\|').Replace('`', "'")
    if ($text.Length -gt 160) {
        $text = $text.Substring(0, 157) + '...'
    }
    return $text
}

function Get-SafeFailureSummary {
    param(
        [AllowEmptyCollection()]
        [object[]] $Failures
    )

    $safe = [System.Collections.Generic.List[string]]::new()
    foreach ($failure in @($Failures)) {
        $value = [string] $failure
        if ($value -match '^[A-Za-z0-9_.:-]+$' -and
            $value -notmatch '(?i)(KEY|SECRET|TOKEN|CREDENTIAL|AUTH\.JSON)') {
            $safe.Add($value)
        }
        else {
            $safe.Add('[redacted]')
        }
    }
    if ($safe.Count -eq 0) {
        return '—'
    }
    return ConvertTo-SafeSummaryCell -Value (($safe | Sort-Object -Unique) -join ', ')
}

function Get-LocalScenarioLogPath {
    param(
        [Parameter(Mandatory)]
        [string] $RunId,

        [Parameter(Mandatory)]
        [string] $Mode,

        [Parameter(Mandatory)]
        [string] $CaseId,

        [Parameter(Mandatory)]
        [string] $ScenarioId
    )

    foreach ($value in $RunId, $Mode, $CaseId, $ScenarioId) {
        if ($value -notmatch '^[A-Za-z0-9-]+$') {
            return 'logs/[redacted]/'
        }
    }
    return "logs/$RunId/$Mode/$CaseId/$ScenarioId/"
}

$fullManifestPath = [System.IO.Path]::GetFullPath($ManifestPath)
$contract = Test-MeechoRunLogContract -ManifestPath $fullManifestPath
if (-not $contract.Valid) {
    throw "Cannot summarize an invalid run manifest: $($contract.Failures -join ', ')"
}
$fullValidation = Invoke-FullManifestValidation -Path $fullManifestPath
if (-not $fullValidation.Valid) {
    throw "Cannot summarize a run rejected by the full validator: $($fullValidation.Failures -join ', ')"
}

$manifest = Get-Content -LiteralPath $fullManifestPath -Raw -Encoding UTF8 |
    ConvertFrom-Json -Depth 50
if ([string] $manifest.kind -cne 'meecho-eval-run') {
    throw 'Baseline summary accepts only meecho-eval-run manifests.'
}
if ([string] $manifest.mode -cne 'control') {
    throw 'Meecho-off baseline summary accepts only control runs.'
}

$runId = ConvertTo-SafeSummaryCell -Value $manifest.runId
$mode = ConvertTo-SafeSummaryCell -Value $manifest.mode
$status = ConvertTo-SafeSummaryCell -Value $manifest.status
$model = ConvertTo-SafeSummaryCell -Value $manifest.model
$reasoning = ConvertTo-SafeSummaryCell -Value $manifest.reasoningEffort
$cases = @(
    Get-PropertyValue -InputObject $manifest -Name 'cases' -DefaultValue @()
)

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('# Meecho-off baseline summary')
$lines.Add('')
$lines.Add("Status: ``$status``")
$lines.Add('')
$lines.Add("Run ID: ``$runId``")
$lines.Add('')
$lines.Add("Mode: ``$mode``")
$lines.Add('')
$lines.Add("Model: ``$model``")
$lines.Add('')
$lines.Add("Reasoning effort: ``$reasoning``")
$lines.Add('')
$runFailures = @(
    Get-PropertyValue -InputObject $manifest -Name 'failures' -DefaultValue @()
)
$lines.Add("Run failures: $(Get-SafeFailureSummary -Failures $runFailures)")
$lines.Add('')
$lines.Add('| Case | Scenario | Permission | Status | Failed items | Local log path |')
$lines.Add('| --- | --- | --- | --- | --- | --- |')

if ($cases.Count -eq 0) {
    $failures = @(
        Get-PropertyValue -InputObject $manifest -Name 'failures' -DefaultValue @()
    )
    $failureSummary = Get-SafeFailureSummary -Failures $failures
    $localPath = Get-LocalScenarioLogPath `
        -RunId ([string] $manifest.runId) `
        -Mode ([string] $manifest.mode) `
        -CaseId 'preflight' `
        -ScenarioId 'read'
    $lines.Add("| preflight | read | read | ``$status`` | $failureSummary | ``$localPath`` |")
}
else {
    foreach ($case in $cases | Sort-Object caseId, scenarioId) {
        $caseId = ConvertTo-SafeSummaryCell -Value (
            Get-PropertyValue -InputObject $case -Name 'caseId' -DefaultValue 'unknown'
        )
        $scenarioId = ConvertTo-SafeSummaryCell -Value (
            Get-PropertyValue -InputObject $case -Name 'scenarioId' -DefaultValue 'unknown'
        )
        $permissionMode = ConvertTo-SafeSummaryCell -Value (
            Get-PropertyValue -InputObject $case -Name 'permissionMode' -DefaultValue 'unknown'
        )
        $caseStatus = ConvertTo-SafeSummaryCell -Value (
            Get-PropertyValue -InputObject $case -Name 'status' -DefaultValue $manifest.status
        )
        $caseFailures = @(
            Get-PropertyValue -InputObject $case -Name 'failures' -DefaultValue @()
        )
        if ($caseFailures.Count -eq 0) {
            $caseFailures = @(
                Get-PropertyValue -InputObject $case -Name 'failedItems' -DefaultValue @()
            )
        }
        $failureSummary = Get-SafeFailureSummary -Failures $caseFailures
        $localPath = Get-LocalScenarioLogPath `
            -RunId ([string] $manifest.runId) `
            -Mode ([string] $manifest.mode) `
            -CaseId ([string] (
                Get-PropertyValue -InputObject $case -Name 'caseId' -DefaultValue 'unknown'
            )) `
            -ScenarioId ([string] (
                Get-PropertyValue -InputObject $case -Name 'scenarioId' -DefaultValue 'unknown'
            ))
        $lines.Add(
            "| $caseId | $scenarioId | $permissionMode | ``$caseStatus`` | " +
            "$failureSummary | ``$localPath`` |"
        )
    }
}

$fullOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$outputRoot = Split-Path -Parent $fullOutputPath
if (-not (Test-Path -LiteralPath $outputRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $outputRoot -Force -ErrorAction Stop | Out-Null
}
$content = ($lines -join "`n") + "`n"
[System.IO.File]::WriteAllText(
    $fullOutputPath,
    $content,
    [System.Text.UTF8Encoding]::new($false)
)
