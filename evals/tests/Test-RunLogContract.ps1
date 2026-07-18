[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$runner = Join-Path $RepositoryRoot 'evals/scripts/Invoke-EvalValidation.ps1'
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
    throw 'Invoke-EvalValidation.ps1 is required to create auditable validation-run logs.'
}

& pwsh -NoProfile -File $runner -RepositoryRoot $RepositoryRoot
if ($LASTEXITCODE -ne 0) { throw "Validation runner exited with $LASTEXITCODE." }

$latest = Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot 'evals/logs') -Directory |
    Sort-Object Name -Descending | Select-Object -First 1
if ($null -eq $latest) { throw 'Validation runner did not create a run directory.' }

@('run-manifest.json', 'checksums.sha256', 'steps/01-structure-validation.log') | ForEach-Object {
    if (-not (Test-Path -LiteralPath (Join-Path $latest.FullName $_) -PathType Leaf)) {
        throw "Validation run is missing required log: $_"
    }
}

$manifest = Get-Content -LiteralPath (Join-Path $latest.FullName 'run-manifest.json') -Raw | ConvertFrom-Json
if ($manifest.runId -notmatch '^\d{8}T\d{6}Z$') { throw 'Manifest runId is not a UTC run ID.' }
if ($manifest.steps.Count -lt 1 -or $manifest.steps[0].exitCode -ne 0) { throw 'Manifest does not record a successful validation step.' }
Write-Output 'Validation run log contract passed.'
