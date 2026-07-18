[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$runner = Join-Path $RepositoryRoot 'evals/scripts/Invoke-Baseline.ps1'
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
    throw 'Invoke-Baseline.ps1 is required to log an isolation-preflight failure.'
}

& pwsh -NoProfile -File $runner -RepositoryRoot $RepositoryRoot
$exitCode = $LASTEXITCODE
if ($exitCode -eq 0) { throw 'Baseline runner must not succeed when the dedicated account is unavailable.' }

$latest = Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot 'evals/logs') -Directory |
    Sort-Object Name -Descending | Select-Object -First 1
if ($null -eq $latest) { throw 'Baseline runner did not create a run directory.' }
$manifest = Get-Content -LiteralPath (Join-Path $latest.FullName 'run-manifest.json') -Raw | ConvertFrom-Json
if ($manifest.status -ne 'BLOCKED_NOT_RUN') { throw "Expected BLOCKED_NOT_RUN, got $($manifest.status)." }
if ($manifest.isolationPrecheck.status -ne 'failed') { throw 'Manifest does not record a failed isolation precheck.' }
if (-not (Test-Path -LiteralPath (Join-Path $latest.FullName 'steps/01-isolation-preflight.log') -PathType Leaf)) {
    throw 'Preflight failure did not leave a step log.'
}
if (@(Get-ChildItem -LiteralPath $latest.FullName -Directory -Filter 'cases' -ErrorAction SilentlyContinue).Count -ne 0) {
    throw 'Baseline runner must stop before creating case artifacts when isolation fails.'
}
Write-Output 'Baseline preflight failure contract passed.'
