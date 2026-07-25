Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'TestSupport.psm1') -Force
$repoRoot = Get-MeechoRepoRoot
$pairRunner = Join-Path $repoRoot 'evals/scripts/Invoke-PairedEvaluation.ps1'
$validator = Join-Path $repoRoot 'evals/scripts/Invoke-EvalValidation.ps1'

function Invoke-JsonScript {
    param(
        [string] $ScriptPath,
        [string[]] $Arguments,
        [string] $LocalAppData,
        [switch] $RemoveLocalAppData
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Join-Path $PSHOME 'pwsh.exe'
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    if ($RemoveLocalAppData) {
        [void]$startInfo.Environment.Remove('LOCALAPPDATA')
    }
    else {
        $startInfo.Environment['LOCALAPPDATA'] = $LocalAppData
    }
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $ScriptPath) + $Arguments) {
        [void] $startInfo.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($startInfo)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $timedOut = -not $process.WaitForExit(90000)
    if ($timedOut) {
        $process.Kill($true)
        $process.WaitForExit()
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $exitCode = if ($timedOut) { 124 } else { $process.ExitCode }
    if ($timedOut) {
        $stderr = ($stderr.TrimEnd() + "`nChild script timed out after 90 seconds.").TrimStart()
    }
    $process.Dispose()
    return [pscustomobject]@{
        ExitCode = $exitCode
        Stdout = $stdout
        Stderr = $stderr
        TimedOut = $timedOut
        Json = if ($stdout.Trim()) { $stdout.Trim() | ConvertFrom-Json -Depth 50 } else { $null }
    }
}

$testRoot = New-MeechoTestRoot
try {
    $missingLocalAppData = Invoke-JsonScript `
        -ScriptPath $pairRunner `
        -Arguments @('-Model', 'gpt-test', '-ReasoningEffort', 'high', '-PreflightOnly') `
        -RemoveLocalAppData
    Assert-True ($missingLocalAppData.ExitCode -ne 0) 'Missing LOCALAPPDATA must block paired evaluation.'
    Assert-Equal 'BLOCKED_NOT_RUN' $missingLocalAppData.Json.Status 'Paired bootstrap failure needs a structured blocked result.'
    Assert-True (Test-Path -LiteralPath $missingLocalAppData.Json.ComparisonManifestPath -PathType Leaf) 'Paired bootstrap failure must persist a local manifest.'
    Assert-Equal 'meecho-eval-comparison-bootstrap' (Read-MeechoJson -Path $missingLocalAppData.Json.ComparisonManifestPath).kind 'Paired bootstrap failure must not impersonate a standard comparison.'
    Assert-True ([string]::IsNullOrWhiteSpace($missingLocalAppData.Stderr)) 'Paired bootstrap failure must not leak as raw stderr.'

    $unsafeRunId = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $unsafeLocalAppData = Join-Path $repoRoot "evals/logs/$unsafeRunId/unsafe-localappdata"
    New-Item -ItemType Directory -Path $unsafeLocalAppData -Force | Out-Null
    $unsafePair = Invoke-JsonScript `
        -ScriptPath $pairRunner `
        -Arguments @('-Model', 'gpt-test', '-ReasoningEffort', 'high', '-PreflightOnly') `
        -LocalAppData $unsafeLocalAppData
    Assert-Equal 'BLOCKED_NOT_RUN' $unsafePair.Json.Status 'Repository-overlapping pair capsule roots must be blocked.'
    Assert-False (Test-Path -LiteralPath (Join-Path $unsafeLocalAppData 'MeechoDev')) 'Pair allocation must reject unsafe roots before creating capsule state.'

    $invalidCandidate = Invoke-JsonScript `
        -ScriptPath $pairRunner `
        -Arguments @(
            '-Model', 'gpt-test',
            '-ReasoningEffort', 'high',
            '-PreflightOnly',
            '-CandidateRunIdsJson', '["not-a-run-id"]'
        ) `
        -LocalAppData $testRoot
    Assert-True ($invalidCandidate.ExitCode -ne 0) 'Invalid candidate ids must fail through the bootstrap contract.'
    Assert-Equal 'BLOCKED_NOT_RUN' $invalidCandidate.Json.Status 'Invalid candidate ids need a structured blocked result.'
    $invalidCandidateManifest = Read-MeechoJson -Path $invalidCandidate.Json.ComparisonManifestPath
    Assert-Equal 'meecho-eval-comparison-bootstrap' $invalidCandidateManifest.kind 'Invalid candidates belong to the explicit comparison bootstrap kind.'
    Assert-True (@($invalidCandidateManifest.failures) -contains 'INVALID_CANDIDATE_RUN_ID') 'Invalid candidate failure was not recorded.'

    $first = Invoke-JsonScript -ScriptPath $pairRunner -Arguments @('-Model', 'gpt-test', '-ReasoningEffort', 'high', '-PreflightOnly') -LocalAppData $testRoot
    $second = Invoke-JsonScript -ScriptPath $pairRunner -Arguments @('-Model', 'gpt-test', '-ReasoningEffort', 'high', '-PreflightOnly') -LocalAppData $testRoot

    Assert-True ($null -ne $first.Json) 'Paired runner must emit one JSON result even when preflight is not ready.'
    Assert-True ($first.Json.Status -in @('AUTH_REQUIRED', 'BLOCKED_NOT_RUN')) 'Fresh paired capsule must stop at a precise non-ready status.'
    Assert-Matches $first.Json.PairRunId '^\d{8}T\d{9}Z-[0-9a-f]{8}$' 'Pair run id format changed.'
    Assert-True ($first.Json.PairRunId -ne $second.Json.PairRunId) 'Fresh paired invocations must never reuse a run id.'
    Assert-Equal $first.Json.PairRunId $first.Json.ControlRunId 'ControlRunId identifies the shared pair run id.'
    Assert-Equal $first.Json.PairRunId $first.Json.TreatmentRunId 'TreatmentRunId identifies the shared pair run id.'

    $lockPath = Join-Path $testRoot "MeechoDev/eval/runs/$($first.Json.PairRunId)/.pair.lock"
    Assert-True (Test-Path -LiteralPath $lockPath -PathType Leaf) 'Atomic pair lock must exist before preflight output.'
    $lockText = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8
    Assert-True ($lockText.Contains($first.Json.PairRunId)) 'Pair lock was empty or overwritten.'

    $firstManifest = Read-MeechoJson -Path $first.Json.ComparisonManifestPath
    if (@($firstManifest.comparisons).Count -eq 0) {
        Assert-False ($firstManifest.status -eq 'COMPLETE') 'Preflight-only output with no comparisons must never claim COMPLETE.'
    }
    Assert-Equal 2 @($firstManifest.sideRuns).Count 'A terminal pair must reference both audited side run manifests.'
    $firstValidation = Invoke-JsonScript `
        -ScriptPath $validator `
        -Arguments @('-ManifestPath', $first.Json.ComparisonManifestPath) `
        -LocalAppData $testRoot
    Assert-Equal 0 $firstValidation.ExitCode 'The paired runner emitted a terminal comparison rejected by its validator.'
    Assert-True $firstValidation.Json.Valid 'The paired runner terminal manifest must be structurally valid.'
    Assert-False $firstValidation.Json.Complete 'A preflight-only comparison cannot be complete.'
    $preflightKeys = @(
        $firstManifest.checks |
            ForEach-Object { "$($_.mode)/$($_.permissionMode)" }
    )
    Assert-SequenceEqual @(
        'control/read',
        'control/allow',
        'control/deny',
        'treatment/read',
        'treatment/allow',
        'treatment/deny'
    ) $preflightKeys 'Paired evaluation must preflight all permission modes on both sides.'

    $collisionId = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    Start-Sleep -Milliseconds 2
    $freshId = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $collisionRoot = Join-Path $testRoot "MeechoDev/eval/runs/$collisionId"
    New-Item -ItemType Directory -Path $collisionRoot -Force | Out-Null
    $sentinelPath = Join-Path $collisionRoot 'sentinel.txt'
    Set-Content -LiteralPath $sentinelPath -Value 'do-not-reuse' -Encoding UTF8
    $sentinelHash = (Get-FileHash -LiteralPath $sentinelPath -Algorithm SHA256).Hash
    $candidateJson = ConvertTo-Json @($collisionId, $freshId) -Compress
    $collisionRun = Invoke-JsonScript -ScriptPath $pairRunner -Arguments @('-Model', 'gpt-test', '-ReasoningEffort', 'high', '-PreflightOnly', '-CandidateRunIdsJson', $candidateJson) -LocalAppData $testRoot
    Assert-Equal $freshId $collisionRun.Json.PairRunId 'An existing candidate directory, even without a lock, must be rejected and never reused.'
    Assert-Equal $sentinelHash (Get-FileHash -LiteralPath $sentinelPath -Algorithm SHA256).Hash 'Collision handling modified an existing run directory.'

    $comparisonPath = Join-Path $testRoot 'comparison-mismatch.json'
    $same = [ordered]@{
        codexBinarySha256 = ('a' * 64)
        codexVersion = '0.145.0'
        model = 'gpt-test'
        reasoningEffort = 'high'
        serviceTier = ''
        configSha256 = ('b' * 64)
        permissionMode = 'read'
        approvalPolicy = 'never'
        environmentNames = @('CODEX_HOME', 'HOME')
        caseInputSha256 = ('c' * 64)
        rubricSha256 = ('d' * 64)
        initialProfileSha256 = ('e' * 64)
    }
    $different = [ordered]@{}
    foreach ($entry in $same.GetEnumerator()) {
        $different[$entry.Key] = $entry.Value
    }
    $different.model = 'gpt-other'

    [ordered]@{
        schemaVersion = 1
        kind = 'meecho-eval-comparison'
        pairRunId = '20260725T040000000Z-1234abcd'
        status = 'COMPLETE'
        controlRunId = '20260725T040000000Z-1234abcd'
        treatmentRunId = '20260725T040000000Z-1234abcd'
        comparisons = @(
            [ordered]@{
                caseId = 'case-01'
                scenarioId = 'read'
                permissionMode = 'read'
                control = $same
                treatment = $different
            }
        )
        failures = @()
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $comparisonPath -Encoding UTF8

    $invalidComplete = Invoke-JsonScript -ScriptPath $validator -Arguments @('-ManifestPath', $comparisonPath) -LocalAppData $testRoot
    Assert-True ($invalidComplete.ExitCode -ne 0) 'A COMPLETE comparison with a model mismatch must be invalid.'
    Assert-Equal 'INVALID_COMPARISON' $invalidComplete.Json.RecommendedStatus 'Validator must classify comparable-field mismatches precisely.'

    $comparison = Read-MeechoJson -Path $comparisonPath
    $comparison.status = 'INVALID_COMPARISON'
    $comparison.failures = @('model')
    $comparison | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $comparisonPath -Encoding UTF8
    $validInvalid = Invoke-JsonScript -ScriptPath $validator -Arguments @('-ManifestPath', $comparisonPath) -LocalAppData $testRoot
    Assert-Equal 0 $validInvalid.ExitCode 'A correctly labelled INVALID_COMPARISON manifest must be structurally valid.'
    Assert-True $validInvalid.Json.Valid 'Validator rejected a correctly labelled mismatch.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Output 'PASS Test-PairedEvaluation'
