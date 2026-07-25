[CmdletBinding()]
param(
    [string] $Model,

    [string] $ReasoningEffort,

    [switch] $PreflightOnly,

    [Parameter(DontShow)]
    [string] $CandidateRunIdsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Import-Module (Join-Path $PSScriptRoot 'EvalAudit.psm1') -Force

function New-MeechoPairBootstrapRunId {
    return (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ') +
        '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
}

function Get-MeechoPairStableFailureCode {
    param([Parameter(Mandatory)][Exception] $Exception)

    $message = ([string]$Exception.Message).Trim()
    if ($message -match '^[A-Z][A-Z0-9_:-]*$' -and
        $message -notmatch '(?i)(KEY|SECRET|TOKEN|CREDENTIAL|AUTH\.JSON)') {
        return $message
    }
    return "HARNESS_EXCEPTION:$($Exception.GetType().Name)"
}

function Stop-MeechoPairBootstrap {
    param([Parameter(Mandatory)][string] $FailureCode)

    $bootstrapRunId = New-MeechoPairBootstrapRunId
    $bootstrapRoot = Join-Path $repoRoot "evals/logs/$bootstrapRunId"
    [void][IO.Directory]::CreateDirectory($bootstrapRoot)
    $bootstrapManifestPath = Join-Path $bootstrapRoot 'comparison-manifest.json'
    $bootstrapManifest = [ordered]@{
        schemaVersion = 1
        kind = 'meecho-eval-comparison-bootstrap'
        pairRunId = $bootstrapRunId
        status = 'BLOCKED_NOT_RUN'
        controlRunId = $bootstrapRunId
        treatmentRunId = $bootstrapRunId
        model = if ($Model) { $Model } else { '' }
        reasoningEffort = if ($ReasoningEffort) { $ReasoningEffort } else { '' }
        checks = @()
        comparisons = @()
        failures = @($FailureCode)
    }
    [IO.File]::WriteAllText(
        $bootstrapManifestPath,
        ($bootstrapManifest | ConvertTo-Json -Depth 20),
        [Text.UTF8Encoding]::new($false)
    )
    [ordered]@{
        PairRunId = $bootstrapRunId
        Status = 'BLOCKED_NOT_RUN'
        ControlRunId = $bootstrapRunId
        TreatmentRunId = $bootstrapRunId
        ComparisonManifestPath = $bootstrapManifestPath
    } | ConvertTo-Json -Compress
    exit 3
}

try {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw 'LOCALAPPDATA_REQUIRED'
    }
    $capsuleRoot = Join-Path $env:LOCALAPPDATA 'MeechoDev/eval'
    $capsuleRoot = Get-MeechoNormalizedPath -Path $capsuleRoot
    if ((Test-MeechoPathUnder -Child $capsuleRoot -Parent $repoRoot -AllowEqual) -or
        (Test-MeechoPathUnder -Child $repoRoot -Parent $capsuleRoot -AllowEqual)) {
        throw 'CAPSULE_ROOT_MUST_BE_OUTSIDE_REPOSITORY'
    }
    Assert-MeechoNoReparsePoint -Path $capsuleRoot
    $runsRoot = Join-Path $capsuleRoot 'runs'
    $locksRoot = Join-Path $capsuleRoot 'locks'
    foreach ($directory in $capsuleRoot, $runsRoot, $locksRoot) {
        Assert-MeechoNoReparsePoint -Path $directory
        [void][IO.Directory]::CreateDirectory($directory)
        Assert-MeechoNoReparsePoint -Path $directory
    }
}
catch {
    Stop-MeechoPairBootstrap -FailureCode (
        Get-MeechoPairStableFailureCode -Exception $_.Exception
    )
}

try {
    $candidateRunIds = [Collections.Generic.Queue[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($CandidateRunIdsJson)) {
        $decodedCandidates = @($CandidateRunIdsJson | ConvertFrom-Json -Depth 5)
        foreach ($candidateId in $decodedCandidates) {
            $candidateText = [string] $candidateId
            if ($candidateText -cnotmatch '^\d{8}T\d{9}Z-[0-9a-f]{8}$') {
                throw 'INVALID_CANDIDATE_RUN_ID'
            }
            $candidateRunIds.Enqueue($candidateText)
        }
        if ($candidateRunIds.Count -eq 0) {
            throw 'CANDIDATE_RUN_IDS_REQUIRED'
        }
    }

    $pairRunId = $null
    $lockPath = $null
    for ($attempt = 0; $attempt -lt 32; $attempt++) {
        if ($candidateRunIds.Count -gt 0) {
            $candidate = $candidateRunIds.Dequeue()
        }
        elseif (-not [string]::IsNullOrWhiteSpace($CandidateRunIdsJson)) {
            break
        }
        else {
            $candidate = New-MeechoPairBootstrapRunId
        }
        $candidateRoot = Join-Path $runsRoot $candidate
        $candidateLogRoot = Join-Path $repoRoot "evals/logs/$candidate"
        $allocationLock = Join-Path $locksRoot "$candidate.run.lock"
        try {
            $allocationStream = [IO.File]::Open(
                $allocationLock,
                [IO.FileMode]::CreateNew,
                [IO.FileAccess]::Write,
                [IO.FileShare]::None
            )
            try {
                if ((Test-Path -LiteralPath $candidateRoot) -or
                    (Test-Path -LiteralPath $candidateLogRoot)) {
                    continue
                }
                [void] [IO.Directory]::CreateDirectory($candidateRoot)
                [void] [IO.Directory]::CreateDirectory($candidateLogRoot)
                $candidateLock = Join-Path $candidateRoot '.pair.lock'
                $stream = [IO.File]::Open(
                    $candidateLock,
                    [IO.FileMode]::CreateNew,
                    [IO.FileAccess]::Write,
                    [IO.FileShare]::None
                )
                try {
                    $bytes = [Text.Encoding]::UTF8.GetBytes($candidate)
                    $stream.Write($bytes, 0, $bytes.Length)
                    $stream.Flush($true)
                    $allocationStream.Write($bytes, 0, $bytes.Length)
                    $allocationStream.Flush($true)
                }
                finally {
                    $stream.Dispose()
                }
            }
            finally {
                $allocationStream.Dispose()
            }
            $pairRunId = $candidate
            $lockPath = $candidateLock
            break
        }
        catch [IO.IOException] {
            continue
        }
    }

    if (-not $pairRunId) {
        throw 'PAIR_RUN_ID_ALLOCATION_FAILED'
    }
}
catch {
    Stop-MeechoPairBootstrap -FailureCode (
        Get-MeechoPairStableFailureCode -Exception $_.Exception
    )
}

$comparisonLogRoot = Join-Path $repoRoot "evals/logs/$pairRunId"
$comparisonManifestPath = Join-Path $comparisonLogRoot 'comparison-manifest.json'
$pairSideRuns = [Collections.Generic.List[object]]::new()

trap {
    $failureCode = Get-MeechoPairStableFailureCode -Exception $_.Exception
    $terminal = [ordered]@{
        schemaVersion = 1
        kind = 'meecho-eval-comparison-bootstrap'
        pairRunId = $pairRunId
        status = 'BLOCKED_NOT_RUN'
        controlRunId = $pairRunId
        treatmentRunId = $pairRunId
        model = if ($Model) { $Model } else { '' }
        reasoningEffort = if ($ReasoningEffort) { $ReasoningEffort } else { '' }
        checks = @()
        comparisons = @()
        failures = @($failureCode)
    }
    [IO.File]::WriteAllText(
        $comparisonManifestPath,
        ($terminal | ConvertTo-Json -Depth 20),
        [Text.UTF8Encoding]::new($false)
    )
    [ordered]@{
        PairRunId = $pairRunId
        Status = 'BLOCKED_NOT_RUN'
        ControlRunId = $pairRunId
        TreatmentRunId = $pairRunId
        ComparisonManifestPath = $comparisonManifestPath
    } | ConvertTo-Json -Compress
    exit 3
}

function Get-MeechoPairStepReferences {
    param([Parameter(Mandatory)][string] $Root)

    return @(
        Get-ChildItem -LiteralPath $Root -Filter '*.record.json' -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object FullName |
            ForEach-Object {
                [ordered]@{
                    name = $_.BaseName
                    recordPath = $_.FullName
                    recordSha256 = (
                        Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256
                    ).Hash.ToLowerInvariant()
                }
            }
    )
}

function Write-MeechoPairSideRun {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('control', 'treatment')]
        [string] $Mode,

        [Parameter(Mandatory)]
        [object[]] $ModeChecks,

        [Parameter(Mandatory)]
        [string[]] $ModeStatuses,

        [Parameter(Mandatory)]
        [object] $Context
    )

    $sideStatus = if ($ModeStatuses -contains 'BLOCKED_NOT_RUN') {
        'BLOCKED_NOT_RUN'
    }
    elseif ($ModeStatuses -contains 'AUTH_REQUIRED') {
        'AUTH_REQUIRED'
    }
    else {
        'BLOCKED_NOT_RUN'
    }
    $sideFailures = @(
        $ModeChecks |
            ForEach-Object { @($_.failures) } |
            Sort-Object -Unique
    )
    if ($sideFailures.Count -eq 0) {
        $sideFailures = @('PAIR_SIDE_BEHAVIOR_NOT_EXECUTED')
    }

    $capsuleModule = Get-Module EvalCapsule -ErrorAction Stop
    $environmentNames = @(
        & $capsuleModule {
            param($EvalContext)
            Get-MeechoChildEnvironmentNames -Context $EvalContext
        } $Context
    )
    $rubricSha256 = (
        Get-FileHash -LiteralPath (Join-Path $repoRoot 'evals/rubric.md') -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    $codexCommand = Get-Command codex -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    $codexBinarySha256 = ''
    if ($codexCommand -and (Test-Path -LiteralPath $codexCommand.Source -PathType Leaf)) {
        try {
            $codexBinarySha256 = (
                Get-FileHash -LiteralPath $codexCommand.Source -Algorithm SHA256
            ).Hash.ToLowerInvariant()
        }
        catch {
            $codexBinarySha256 = ''
        }
    }

    $sideManifestPath = Join-Path $repoRoot (
        "evals/logs/$pairRunId/$Mode/preflight/read/run-manifest.json"
    )
    $sideManifest = [ordered]@{
        schemaVersion = 1
        kind = 'meecho-eval-run'
        runId = $pairRunId
        mode = $Mode
        status = $sideStatus
        model = $Model
        reasoningEffort = $ReasoningEffort
        capsuleRoot = $Context.CapsuleRoot
        repoRoot = $repoRoot
        configSha256 = $Context.ConfigSha256
        rubricSha256 = $rubricSha256
        codexBinary = if ($codexCommand) {
            [IO.Path]::GetFileName($codexCommand.Source)
        }
        else {
            ''
        }
        codexBinarySha256 = $codexBinarySha256
        approvalPolicy = 'never'
        environmentNames = @($environmentNames)
        permissionPreflights = @($ModeChecks)
        checks = @($ModeChecks)
        steps = @(Get-MeechoPairStepReferences -Root (
            Join-Path $repoRoot "evals/logs/$pairRunId/$Mode"
        ))
        cases = @()
        failures = @($sideFailures)
    }
    Write-MeechoRunManifest -Manifest $sideManifest -Path $sideManifestPath
    return [ordered]@{
        mode = $Mode
        runId = $pairRunId
        status = $sideStatus
        manifestPath = $sideManifestPath
        manifestSha256 = (
            Get-FileHash -LiteralPath $sideManifestPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
    }
}

function Write-ComparisonAndExit {
    param(
        [string] $Status,
        [string[]] $Failures,
        [int] $ExitCode,
        [object[]] $Checks = @()
    )

    $manifest = [ordered]@{
        schemaVersion = 1
        kind = if ($pairSideRuns.Count -eq 2) {
            'meecho-eval-comparison'
        }
        else {
            'meecho-eval-comparison-bootstrap'
        }
        pairRunId = $pairRunId
        status = $Status
        controlRunId = $pairRunId
        treatmentRunId = $pairRunId
        model = if ($Model) { $Model } else { '' }
        reasoningEffort = if ($ReasoningEffort) { $ReasoningEffort } else { '' }
        lockPath = $lockPath
        checks = @($Checks)
        sideRuns = @($pairSideRuns)
        comparisons = @()
        failures = @($Failures)
    }
    $manifest | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $comparisonManifestPath -Encoding UTF8

    [ordered]@{
        PairRunId = $pairRunId
        Status = $Status
        ControlRunId = $pairRunId
        TreatmentRunId = $pairRunId
        ComparisonManifestPath = $comparisonManifestPath
    } | ConvertTo-Json -Compress
    exit $ExitCode
}

$failures = [Collections.Generic.List[string]]::new()
if ([string]::IsNullOrWhiteSpace($Model)) {
    $failures.Add('MODEL_REQUIRED')
}
if ([string]::IsNullOrWhiteSpace($ReasoningEffort)) {
    $failures.Add('REASONING_REQUIRED')
}
elseif ($ReasoningEffort -cne 'high') {
    $failures.Add('REASONING_MUST_BE_HIGH')
}
if ($failures.Count -gt 0) {
    Write-ComparisonAndExit -Status 'BLOCKED_NOT_RUN' -Failures @($failures) -ExitCode 64
}

Import-Module (Join-Path $PSScriptRoot 'EvalCapsule.psm1') -Force

$checks = [Collections.Generic.List[object]]::new()
$statuses = [Collections.Generic.List[string]]::new()
foreach ($mode in 'control', 'treatment') {
    $modeChecks = [Collections.Generic.List[object]]::new()
    $modeStatuses = [Collections.Generic.List[string]]::new()
    $modeContexts = [Collections.Generic.List[object]]::new()
    foreach ($permissionMode in 'read', 'allow', 'deny') {
        $context = New-MeechoEvalContext `
            -Mode $mode `
            -RunId $pairRunId `
            -CaseId preflight `
            -ScenarioId $permissionMode `
            -Model $Model `
            -ReasoningEffort $ReasoningEffort `
            -PermissionMode $permissionMode
        $modeContexts.Add($context)
        $preflight = Test-MeechoEvalPreflight -Context $context
        $statuses.Add($preflight.Status)
        $modeStatuses.Add($preflight.Status)
        $check = [ordered]@{
            mode = $mode
            permissionMode = $permissionMode
            status = $preflight.Status
            passed = $preflight.Passed
            checks = @($preflight.Checks)
            failures = @($preflight.Failures)
            configSha256 = $context.ConfigSha256
        }
        $checks.Add($check)
        $modeChecks.Add($check)
    }
    $pairSideRuns.Add(
        (Write-MeechoPairSideRun `
            -Mode $mode `
            -ModeChecks @($modeChecks) `
            -ModeStatuses @($modeStatuses) `
            -Context $modeContexts[0])
    )
}

if ($statuses -contains 'BLOCKED_NOT_RUN') {
    Write-ComparisonAndExit -Status 'BLOCKED_NOT_RUN' -Failures @('CAPSULE_PREFLIGHT_BLOCKED') -ExitCode 3 -Checks @($checks)
}
if ($statuses -contains 'AUTH_REQUIRED') {
    Write-ComparisonAndExit -Status 'AUTH_REQUIRED' -Failures @('CAPSULE_AUTH_REQUIRED') -ExitCode 2 -Checks @($checks)
}

if ($PreflightOnly) {
    Write-ComparisonAndExit -Status 'BLOCKED_NOT_RUN' -Failures @('PREFLIGHT_ONLY_NO_COMPARISON') -ExitCode 3 -Checks @($checks)
}

# Task 7 replaces this guard with the real back-to-back case executor after the
# treatment plugin exists. Keeping the guard explicit prevents a control-only
# run from being misrepresented as comparison evidence.
Write-ComparisonAndExit -Status 'BLOCKED_NOT_RUN' -Failures @('TREATMENT_EXECUTOR_NOT_AVAILABLE_UNTIL_TASK_7') -ExitCode 3 -Checks @($checks)
