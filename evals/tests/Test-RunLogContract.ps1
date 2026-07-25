Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'TestSupport.psm1') -Force
$repoRoot = Get-MeechoRepoRoot
Import-Module (Join-Path $repoRoot 'evals/scripts/EvalAudit.psm1') -Force

$testRoot = New-MeechoTestRoot
$secretMarker = 'never-log-' + [guid]::NewGuid().ToString('N')
try {
    $runId = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $capsuleRoot = Join-Path $testRoot 'capsule'
    New-Item -ItemType Directory -Path $capsuleRoot -Force | Out-Null
    $logRoot = Join-Path $repoRoot "evals/logs/$runId/control/preflight/read"
    New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
    $environment = [ordered]@{
        SystemRoot = $env:SystemRoot
        WINDIR = $env:WINDIR
        PATH = $env:PATH
        TEMP = $testRoot
        TMP = $testRoot
        LOCALAPPDATA = $testRoot
        APPDATA = $testRoot
        USERPROFILE = $testRoot
        HOME = $testRoot
        CODEX_HOME = (Join-Path $testRoot 'codex-home')
        CODEX_SQLITE_HOME = (Join-Path $testRoot 'state')
    }
    $stepResult = Invoke-MeechoAuditedProcess `
        -FilePath (Join-Path $PSHOME 'pwsh.exe') `
        -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', '[Console]::Out.WriteLine("probe-ok")') `
        -Environment $environment `
        -StepLogRoot $logRoot `
        -StepName 'preflight-probe'

    $manifestPath = Join-Path $logRoot 'run-manifest.json'
    $manifest = [ordered]@{
        schemaVersion = 1
        kind = 'meecho-eval-run'
        runId = $runId
        mode = 'control'
        status = 'AUTH_REQUIRED'
        model = 'gpt-test'
        reasoningEffort = 'high'
        capsuleRoot = $capsuleRoot
        repoRoot = $repoRoot
        configSha256 = ('a' * 64)
        environmentNames = @($environment.Keys | Sort-Object)
        steps = @(
            [ordered]@{
                name = 'preflight-probe'
                recordPath = $stepResult.RecordPath
                recordSha256 = (Get-FileHash -LiteralPath $stepResult.RecordPath -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        )
        cases = @()
        failures = @('AUTH_REQUIRED')
    }
    Write-MeechoRunManifest -Manifest $manifest -Path $manifestPath

    $contract = Test-MeechoRunLogContract -ManifestPath $manifestPath
    Assert-True $contract.Valid 'A complete preflight log contract should validate.'
    Assert-Equal 'AUTH_REQUIRED' $contract.Status 'Log validator changed the terminal status.'

    $serialized = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8
    Assert-False ($serialized.Contains($secretMarker)) 'Secret marker appeared in the run manifest.'
    Assert-False ($serialized -match '(?i)"environment"\s*:\s*\{') 'Manifest must record environment names, never an environment value map.'
    Assert-False ($serialized -match '(?i)auth\.json') 'Auth file names must not enter run manifests.'

    $summaryPath = Join-Path $testRoot 'baseline-summary.md'
    & (Join-Path $repoRoot 'evals/scripts/Update-BaselineSummary.ps1') -ManifestPath $manifestPath -OutputPath $summaryPath
    Assert-True (Test-Path -LiteralPath $summaryPath -PathType Leaf) 'Summary updater did not write output.'
    $summary = Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8
    foreach ($required in $runId, 'AUTH_REQUIRED', 'gpt-test', 'high') {
        Assert-True ($summary.Contains($required)) "Summary is missing '$required'."
    }
    Assert-True ($summary.Contains('Run failures: AUTH_REQUIRED')) 'Summary must expose the redacted top-level terminal reason.'
    Assert-False ($summary.Contains($testRoot)) 'Committed-style summary must not contain absolute local paths.'
    Assert-False ($summary.Contains('probe-ok')) 'Summary must not copy raw stdout.'

    $stableCaseFailure = 'CASE_INFRASTRUCTURE_EXIT:case-01:read:main:17'
    $manifest.status = 'BLOCKED_NOT_RUN'
    $manifest.failures = @($stableCaseFailure)
    Write-MeechoRunManifest -Manifest $manifest -Path $manifestPath
    $diagnosticSummaryPath = Join-Path $testRoot 'diagnostic-summary.md'
    & (Join-Path $repoRoot 'evals/scripts/Update-BaselineSummary.ps1') `
        -ManifestPath $manifestPath `
        -OutputPath $diagnosticSummaryPath
    $diagnosticSummary = Get-Content -LiteralPath $diagnosticSummaryPath -Raw -Encoding UTF8
    Assert-True ($diagnosticSummary.Contains("Run failures: $stableCaseFailure")) 'A stable case failure code must remain diagnosable in the safe summary.'
    Assert-False ($diagnosticSummary.Contains('[redacted]')) 'A stable case failure code must not be mistaken for a path or secret.'

    $treatmentRunId = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $treatmentLogRoot = Join-Path $repoRoot "evals/logs/$treatmentRunId/treatment/preflight/read"
    New-Item -ItemType Directory -Path $treatmentLogRoot -Force | Out-Null
    $treatmentStep = Invoke-MeechoAuditedProcess `
        -FilePath (Join-Path $PSHOME 'pwsh.exe') `
        -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', 'exit 3') `
        -Environment $environment `
        -StepLogRoot $treatmentLogRoot `
        -StepName 'preflight-probe'
    $treatmentManifest = Read-MeechoJson -Path $manifestPath
    $treatmentManifest.runId = $treatmentRunId
    $treatmentManifest.mode = 'treatment'
    $treatmentManifest.status = 'BLOCKED_NOT_RUN'
    $treatmentManifest.failures = @('HARNESS_EXCEPTION:IOException')
    $treatmentManifest.steps = @(
        [ordered]@{
            name = 'preflight-probe'
            recordPath = $treatmentStep.RecordPath
            recordSha256 = (
                Get-FileHash -LiteralPath $treatmentStep.RecordPath -Algorithm SHA256
            ).Hash.ToLowerInvariant()
        }
    )
    $treatmentManifestPath = Join-Path $treatmentLogRoot 'run-manifest.json'
    Write-MeechoRunManifest -Manifest $treatmentManifest -Path $treatmentManifestPath
    Assert-Throws {
        & (Join-Path $repoRoot 'evals/scripts/Update-BaselineSummary.ps1') `
            -ManifestPath $treatmentManifestPath `
            -OutputPath (Join-Path $testRoot 'treatment-must-not-be-baseline.md')
    } 'A treatment run must never be labelled as a Meecho-off baseline.'

    $invalidManifestPath = Join-Path $testRoot 'invalid-reasoning-manifest.json'
    $invalidManifest = Read-MeechoJson -Path $manifestPath
    $invalidManifest.reasoningEffort = 'medium'
    $invalidManifest | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $invalidManifestPath -Encoding UTF8
    Assert-Throws {
        & (Join-Path $repoRoot 'evals/scripts/Update-BaselineSummary.ps1') -ManifestPath $invalidManifestPath -OutputPath (Join-Path $testRoot 'must-not-write.md')
    } 'Summary updater must call the full evaluation validator and reject a run that only the weaker log contract accepts.'

    Add-Content -LiteralPath $stepResult.StdoutPath -Value 'tamper' -Encoding UTF8
    $tampered = Test-MeechoRunLogContract -ManifestPath $manifestPath
    Assert-False $tampered.Valid 'Log contract must reject a tampered nested step artifact.'

    $readme = Get-Content -LiteralPath (Join-Path $repoRoot 'evals/logs/README.md') -Raw -Encoding UTF8
    Assert-True ($readme.Contains('mode/case/scenario')) 'Log README must document the mode/case/scenario hierarchy.'
    Assert-False ($readme -match 'meecho-eval|second Windows|第二个 Windows') 'Log README still documents the legacy dedicated-user design.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Output 'PASS Test-RunLogContract'
