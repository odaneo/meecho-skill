[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$runner = Join-Path $RepositoryRoot 'evals/scripts/Invoke-EvalValidation.ps1'
$fixture = Join-Path ([System.IO.Path]::GetTempPath()) ("meecho-complete-run-$([guid]::NewGuid().ToString('N'))")
try {
    New-Item -ItemType Directory -Force -Path (Join-Path $fixture 'steps'), (Join-Path $fixture 'cases') | Out-Null
    $steps = @(1..9 | ForEach-Object { @{ name = ('case-{0:D2}' -f $_); log = ('steps/case-{0:D2}.log' -f $_); exitCode = 0 } })
    $cases = @(1..9 | ForEach-Object { @{ caseId = ('{0:D2}' -f $_); exitCode = 0 } })
    @{ runId = '20990101T000000Z'; steps = $steps; cases = $cases } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $fixture 'run-manifest.json') -Encoding utf8
    1..9 | ForEach-Object {
        $id = '{0:D2}' -f $_
        New-Item -ItemType Directory -Force -Path (Join-Path $fixture "cases/$id") | Out-Null
        Set-Content -LiteralPath (Join-Path $fixture "steps/case-$id.log") -Value 'test step log'
        Set-Content -LiteralPath (Join-Path $fixture "cases/$id/events.jsonl") -Value '{}'
        Set-Content -LiteralPath (Join-Path $fixture "cases/$id/stderr.log") -Value ''
        Set-Content -LiteralPath (Join-Path $fixture "cases/$id/final.md") -Value 'final'
        @{ rubric = @(1..17 | ForEach-Object { @{ id = $_; score = 'needs-human-review' } }) } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $fixture "cases/$id/result.json") -Encoding utf8
    }
    Set-Content -LiteralPath (Join-Path $fixture 'checksums.sha256') -Value 'fixture'
    & pwsh -NoProfile -File $runner -RepositoryRoot $RepositoryRoot -VerifyRunDirectory $fixture
    if ($LASTEXITCODE -ne 0) { throw "Complete-run validation exited with $LASTEXITCODE." }
    Write-Output 'Complete run log validation contract passed.'
} finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}
