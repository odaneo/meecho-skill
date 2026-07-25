[CmdletBinding()]
param(
    [string] $Model,

    [string] $ReasoningEffort,

    [switch] $PreflightOnly,

    [string] $SummaryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Mode = 'control'
Import-Module (Join-Path $PSScriptRoot 'EvalAudit.psm1') -Force

function New-MeechoBootstrapRunId {
    return (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ') +
        '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
}

function Get-MeechoStableFailureCode {
    param([Parameter(Mandatory)][Exception] $Exception)

    $message = ([string]$Exception.Message).Trim()
    if ($message -match '^[A-Z][A-Z0-9_:-]*$' -and
        $message -notmatch '(?i)(KEY|SECRET|TOKEN|CREDENTIAL|AUTH\.JSON)') {
        return $message
    }
    return "HARNESS_EXCEPTION:$($Exception.GetType().Name)"
}

function Get-MeechoRealProfileRoot {
    $realUserHome = @($env:USERPROFILE, $env:HOME) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($realUserHome)) {
        $realUserHome = [Environment]::GetFolderPath(
            [Environment+SpecialFolder]::UserProfile
        )
    }
    if ([string]::IsNullOrWhiteSpace($realUserHome)) {
        throw 'REAL_USER_HOME_REQUIRED'
    }
    return Join-Path $realUserHome '.meecho'
}

function ConvertTo-MeechoInventoryReference {
    param([Parameter(Mandatory)][object] $Evidence)

    return [ordered]@{
        path = [string]$Evidence.Path
        sha256 = [string]$Evidence.Sha256
        inventorySha256 = [string]$Evidence.InventorySha256
    }
}

function Add-MeechoImmediateRealProfileEvidence {
    param(
        [Parameter(Mandatory)]
        [Collections.IDictionary] $TargetManifest,

        [Parameter(Mandatory)]
        [string] $LogRoot
    )

    $realProfileRoot = Get-MeechoRealProfileRoot
    $before = @(Get-MeechoFileInventory -Path $realProfileRoot)
    $beforeEvidence = Write-MeechoInventoryEvidence `
        -Inventory $before `
        -Path (Join-Path $LogRoot 'real-profile-before-inventory.json')
    $after = @(Get-MeechoFileInventory -Path $realProfileRoot)
    $afterEvidence = Write-MeechoInventoryEvidence `
        -Inventory $after `
        -Path (Join-Path $LogRoot 'real-profile-after-inventory.json')

    $TargetManifest.realProfileBeforeSha256 = $beforeEvidence.InventorySha256
    $TargetManifest.realProfileAfterSha256 = $afterEvidence.InventorySha256
    $TargetManifest.realProfileBeforeInventory = ConvertTo-MeechoInventoryReference `
        -Evidence $beforeEvidence
    $TargetManifest.realProfileAfterInventory = ConvertTo-MeechoInventoryReference `
        -Evidence $afterEvidence
    if (-not (Compare-MeechoFileInventory -Before $before -After $after).Equal) {
        $TargetManifest.failures = @($TargetManifest.failures) + @('REAL_PROFILE_CHANGED')
        return $false
    }
    return $true
}

function Stop-MeechoBaselineBootstrap {
    param([Parameter(Mandatory)][string] $FailureCode)

    $bootstrapRunId = New-MeechoBootstrapRunId
    $bootstrapRoot = Join-Path $repoRoot "evals/logs/$bootstrapRunId/control/preflight/read"
    [void][IO.Directory]::CreateDirectory($bootstrapRoot)
    $bootstrapManifestPath = Join-Path $bootstrapRoot 'run-manifest.json'
    $bootstrapManifest = [ordered]@{
        schemaVersion = 1
        kind = 'meecho-eval-bootstrap'
        runId = $bootstrapRunId
        mode = $Mode
        status = 'BLOCKED_NOT_RUN'
        model = if ($Model) { $Model } else { '' }
        reasoningEffort = if ($ReasoningEffort) { $ReasoningEffort } else { '' }
        steps = @()
        cases = @()
        failures = @($FailureCode)
    }
    try {
        [void](Add-MeechoImmediateRealProfileEvidence `
            -TargetManifest $bootstrapManifest `
            -LogRoot $bootstrapRoot)
    }
    catch {
        $bootstrapManifest.failures = @($bootstrapManifest.failures) + @(
            Get-MeechoStableFailureCode -Exception $_.Exception
        )
    }
    $bootstrapManifest.failures = @($bootstrapManifest.failures | Sort-Object -Unique)
    Write-MeechoRunManifest -Manifest $bootstrapManifest -Path $bootstrapManifestPath
    [ordered]@{
        RunId = $bootstrapRunId
        Status = 'BLOCKED_NOT_RUN'
        ManifestPath = $bootstrapManifestPath
    } | ConvertTo-Json -Compress
    exit 3
}

if ([string]::IsNullOrWhiteSpace($SummaryPath)) {
    $SummaryPath = Join-Path $repoRoot 'evals/results/baseline-summary.md'
}

try {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw 'LOCALAPPDATA_REQUIRED'
    }
    $capsuleRootForAllocation = Join-Path $env:LOCALAPPDATA 'MeechoDev/eval'
    $capsuleRootForAllocation = Get-MeechoNormalizedPath -Path $capsuleRootForAllocation
    if ((Test-MeechoPathUnder -Child $capsuleRootForAllocation -Parent $repoRoot -AllowEqual) -or
        (Test-MeechoPathUnder -Child $repoRoot -Parent $capsuleRootForAllocation -AllowEqual)) {
        throw 'CAPSULE_ROOT_MUST_BE_OUTSIDE_REPOSITORY'
    }
    Assert-MeechoNoReparsePoint -Path $capsuleRootForAllocation
    $runsRootForAllocation = Join-Path $capsuleRootForAllocation 'runs'
    $locksRootForAllocation = Join-Path $capsuleRootForAllocation 'locks'
    foreach ($directory in $capsuleRootForAllocation, $runsRootForAllocation, $locksRootForAllocation) {
        Assert-MeechoNoReparsePoint -Path $directory
        [void] [IO.Directory]::CreateDirectory($directory)
        Assert-MeechoNoReparsePoint -Path $directory
    }

    $RunId = $null
    for ($attempt = 0; $attempt -lt 32; $attempt++) {
        $candidate = New-MeechoBootstrapRunId
        $candidateRunRoot = Join-Path $runsRootForAllocation $candidate
        $candidateLogRoot = Join-Path $repoRoot "evals/logs/$candidate"
        if ((Test-Path -LiteralPath $candidateRunRoot) -or (Test-Path -LiteralPath $candidateLogRoot)) {
            continue
        }

        $allocationLock = Join-Path $locksRootForAllocation "$candidate.run.lock"
        try {
            $lockStream = [IO.File]::Open(
                $allocationLock,
                [IO.FileMode]::CreateNew,
                [IO.FileAccess]::Write,
                [IO.FileShare]::None
            )
            try {
                if ((Test-Path -LiteralPath $candidateRunRoot) -or (Test-Path -LiteralPath $candidateLogRoot)) {
                    continue
                }
                [void] [IO.Directory]::CreateDirectory($candidateRunRoot)
                [void] [IO.Directory]::CreateDirectory($candidateLogRoot)
                $bytes = [Text.Encoding]::UTF8.GetBytes($candidate)
                $lockStream.Write($bytes, 0, $bytes.Length)
                $lockStream.Flush($true)
                $RunId = $candidate
                break
            }
            finally {
                $lockStream.Dispose()
            }
        }
        catch [IO.IOException] {
            continue
        }
    }
    if (-not $RunId) {
        throw 'BASELINE_RUN_ID_ALLOCATION_FAILED'
    }
}
catch {
    Stop-MeechoBaselineBootstrap -FailureCode (
        Get-MeechoStableFailureCode -Exception $_.Exception
    )
}

$preflightLogRoot = Join-Path $repoRoot "evals/logs/$RunId/$Mode/preflight/read"
$manifestPath = Join-Path $preflightLogRoot 'run-manifest.json'
$script:realProfileRoot = $null
$script:realProfileBefore = @()
$script:realProfileBeforeEvidence = $null
$script:realProfileAfter = @()
$script:realProfileAfterEvidence = $null

function Initialize-MeechoRealProfileEvidence {
    if ($null -ne $script:realProfileBeforeEvidence) {
        return
    }

    $script:realProfileRoot = Get-MeechoRealProfileRoot
    $script:realProfileBefore = @(
        Get-MeechoFileInventory -Path $script:realProfileRoot
    )
    $script:realProfileBeforeEvidence = Write-MeechoInventoryEvidence `
        -Inventory $script:realProfileBefore `
        -Path (Join-Path $preflightLogRoot 'real-profile-before-inventory.json')
}

function Add-MeechoRealProfileTerminalEvidence {
    param([Parameter(Mandatory)][Collections.IDictionary] $TargetManifest)

    Initialize-MeechoRealProfileEvidence
    if ($null -eq $script:realProfileAfterEvidence) {
        $script:realProfileAfter = @(
            Get-MeechoFileInventory -Path $script:realProfileRoot
        )
        $script:realProfileAfterEvidence = Write-MeechoInventoryEvidence `
            -Inventory $script:realProfileAfter `
            -Path (Join-Path $preflightLogRoot 'real-profile-after-inventory.json')
    }

    $TargetManifest.realProfileBeforeSha256 = (
        $script:realProfileBeforeEvidence.InventorySha256
    )
    $TargetManifest.realProfileAfterSha256 = (
        $script:realProfileAfterEvidence.InventorySha256
    )
    $TargetManifest.realProfileBeforeInventory = ConvertTo-MeechoInventoryReference `
        -Evidence $script:realProfileBeforeEvidence
    $TargetManifest.realProfileAfterInventory = ConvertTo-MeechoInventoryReference `
        -Evidence $script:realProfileAfterEvidence
    if (-not (Compare-MeechoFileInventory `
        -Before $script:realProfileBefore `
        -After $script:realProfileAfter
    ).Equal) {
        if (@($TargetManifest.failures) -notcontains 'REAL_PROFILE_CHANGED') {
            $TargetManifest.failures = @($TargetManifest.failures) + @(
                'REAL_PROFILE_CHANGED'
            )
        }
        return $false
    }
    return $true
}

trap {
    $failureCode = Get-MeechoStableFailureCode -Exception $_.Exception
    try {
        $emergencyScenarioRoot = Join-Path $candidateRunRoot 'control/preflight/read'
        $emergencyEnvironment = [ordered]@{
            SystemRoot = $env:SystemRoot
            WINDIR = $env:WINDIR
            PATH = $env:PATH
            TEMP = (Join-Path $emergencyScenarioRoot 'temp')
            TMP = (Join-Path $emergencyScenarioRoot 'temp')
            LOCALAPPDATA = (Join-Path $emergencyScenarioRoot 'local-appdata')
            APPDATA = (Join-Path $emergencyScenarioRoot 'appdata')
            USERPROFILE = (Join-Path $emergencyScenarioRoot 'user-home')
            HOME = (Join-Path $emergencyScenarioRoot 'user-home')
            CODEX_HOME = (Join-Path $capsuleRootForAllocation 'control/codex-home')
            CODEX_SQLITE_HOME = (Join-Path $emergencyScenarioRoot 'state')
        }
        foreach ($directory in @(
            $emergencyEnvironment.TEMP,
            $emergencyEnvironment.LOCALAPPDATA,
            $emergencyEnvironment.APPDATA,
            $emergencyEnvironment.USERPROFILE,
            $emergencyEnvironment.CODEX_HOME,
            $emergencyEnvironment.CODEX_SQLITE_HOME
        )) {
            Assert-MeechoNoReparsePoint -Path $directory
            [void][IO.Directory]::CreateDirectory($directory)
            Assert-MeechoNoReparsePoint -Path $directory
        }
        $step = Invoke-MeechoAuditedProcess `
            -FilePath (Join-Path $PSHOME 'pwsh.exe') `
            -ArgumentList @(
                '-NoLogo', '-NoProfile', '-NonInteractive',
                '-Command', '[Console]::Error.Write("blocked"); exit 7'
            ) `
            -Environment $emergencyEnvironment `
            -StepLogRoot $preflightLogRoot `
            -StepName 'harness-exception' `
            -TimeoutSeconds 30

        $existingManifest = Get-Variable -Name manifest -Scope Script -ErrorAction SilentlyContinue
        if ($existingManifest -and $existingManifest.Value -is [Collections.IDictionary]) {
            $terminalManifest = $existingManifest.Value
            $terminalManifest.status = 'BLOCKED_NOT_RUN'
            $terminalManifest.failures = @($terminalManifest.failures) + @($failureCode)
            $terminalManifest.steps = @(Get-MeechoStepReferences -Root (Join-Path $repoRoot "evals/logs/$RunId"))
            if (-not $terminalManifest.Contains('cases')) {
                $terminalManifest.cases = @()
            }
        }
        else {
            $terminalManifest = [ordered]@{
                schemaVersion = 1
                kind = 'meecho-eval-run'
                runId = $RunId
                mode = $Mode
                status = 'BLOCKED_NOT_RUN'
                model = if ($Model) { $Model } else { '' }
                reasoningEffort = if ($ReasoningEffort) { $ReasoningEffort } else { '' }
                capsuleRoot = $capsuleRootForAllocation
                repoRoot = $repoRoot
                configSha256 = (
                    Get-FileHash -LiteralPath (Join-Path $repoRoot 'evals/capsule/config.toml') -Algorithm SHA256
                ).Hash.ToLowerInvariant()
                approvalPolicy = 'never'
                environmentNames = @($emergencyEnvironment.Keys | Sort-Object)
                checks = @()
                steps = @(
                    [ordered]@{
                        name = 'harness-exception'
                        recordPath = $step.RecordPath
                        recordSha256 = (
                            Get-FileHash -LiteralPath $step.RecordPath -Algorithm SHA256
                        ).Hash.ToLowerInvariant()
                    }
                )
                cases = @()
                failures = @($failureCode)
            }
        }
        $terminalManifest.failures = @($terminalManifest.failures | Sort-Object -Unique)
        try {
            [void](Add-MeechoRealProfileTerminalEvidence -TargetManifest $terminalManifest)
        }
        catch {
            $terminalManifest.failures = @($terminalManifest.failures) + @(
                Get-MeechoStableFailureCode -Exception $_.Exception
            )
            $terminalManifest.failures = @(
                $terminalManifest.failures | Sort-Object -Unique
            )
        }
        Write-MeechoRunManifest -Manifest $terminalManifest -Path $manifestPath
    }
    catch {
        $fallback = [ordered]@{
            schemaVersion = 1
            kind = 'meecho-eval-bootstrap'
            runId = $RunId
            mode = $Mode
            status = 'BLOCKED_NOT_RUN'
            failures = @($failureCode, 'TERMINAL_LOG_WRITE_DEGRADED')
        }
        [IO.File]::WriteAllText(
            $manifestPath,
            ($fallback | ConvertTo-Json -Depth 10),
            [Text.UTF8Encoding]::new($false)
        )
    }
    [ordered]@{
        RunId = $RunId
        Status = 'BLOCKED_NOT_RUN'
        ManifestPath = $manifestPath
    } | ConvertTo-Json -Compress
    exit 3
}

New-Item -ItemType Directory -Path $preflightLogRoot -Force | Out-Null
Initialize-MeechoRealProfileEvidence

function Write-BaselineResultAndExit {
    param(
        [string] $Status,
        [int] $ExitCode
    )

    [ordered]@{
        RunId = $RunId
        Status = $Status
        ManifestPath = $manifestPath
    } | ConvertTo-Json -Compress
    exit $ExitCode
}

function Update-BaselineSummary {
    try {
        & (Join-Path $PSScriptRoot 'Update-BaselineSummary.ps1') `
            -ManifestPath $manifestPath `
            -OutputPath $SummaryPath
        return $true
    }
    catch {
        return $false
    }
}

function Get-MeechoInventoryDigest {
    param(
        [AllowEmptyCollection()]
        [object[]] $Inventory = @()
    )

    $json = ConvertTo-Json @($Inventory) -Compress -Depth 30
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Get-MeechoStepReferences {
    param(
        [Parameter(Mandatory)]
        [string] $Root
    )

    return @(
        Get-ChildItem -LiteralPath $Root -Filter '*.record.json' -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object FullName |
            ForEach-Object {
                [ordered]@{
                    name = $_.BaseName
                    recordPath = $_.FullName
                    recordSha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                }
            }
    )
}

function Test-MeechoInvocationEvidence {
    param(
        [Parameter(Mandatory)]
        [string] $JsonlPath,

        [Parameter(Mandatory)]
        [string] $FinalPath
    )

    $jsonlValid = Test-Path -LiteralPath $JsonlPath -PathType Leaf
    $turnCompleted = $false
    if ($jsonlValid) {
        $eventCount = 0
        foreach ($line in Get-Content -LiteralPath $JsonlPath -Encoding UTF8) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }
            $eventCount++
            try {
                $event = $line | ConvertFrom-Json -Depth 50 -ErrorAction Stop
                if ([string]$event.type -ceq 'turn.completed') {
                    $turnCompleted = $true
                }
            }
            catch {
                $jsonlValid = $false
                break
            }
        }
        if ($eventCount -eq 0) {
            $jsonlValid = $false
        }
    }
    $finalValid = (
        (Test-Path -LiteralPath $FinalPath -PathType Leaf) -and
        -not [string]::IsNullOrWhiteSpace(
            (Get-Content -LiteralPath $FinalPath -Raw -Encoding UTF8)
        )
    )
    return [pscustomobject][ordered]@{
        JsonlValid = $jsonlValid
        TurnCompleted = $turnCompleted
        FinalValid = $finalValid
    }
}

$inputFailures = [Collections.Generic.List[string]]::new()
if ([string]::IsNullOrWhiteSpace($Model)) {
    $inputFailures.Add('MODEL_REQUIRED')
}
if ([string]::IsNullOrWhiteSpace($ReasoningEffort)) {
    $inputFailures.Add('REASONING_REQUIRED')
}
elseif ($ReasoningEffort -cne 'high') {
    $inputFailures.Add('REASONING_MUST_BE_HIGH')
}

if ($inputFailures.Count -gt 0) {
    $inputFailureManifest = [ordered]@{
        schemaVersion = 1
        kind = 'meecho-eval-bootstrap'
        runId = $RunId
        mode = $Mode
        status = 'BLOCKED_NOT_RUN'
        model = if ($Model) { $Model } else { '' }
        reasoningEffort = if ($ReasoningEffort) { $ReasoningEffort } else { '' }
        configSha256 = ''
        environmentNames = @()
        steps = @()
        cases = @()
        failures = @($inputFailures)
    }
    [void](Add-MeechoRealProfileTerminalEvidence -TargetManifest $inputFailureManifest)
    Write-MeechoRunManifest `
        -Manifest $inputFailureManifest `
        -Path $manifestPath
    Write-BaselineResultAndExit -Status 'BLOCKED_NOT_RUN' -ExitCode 64
}

Import-Module (Join-Path $PSScriptRoot 'EvalCapsule.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CaseStaging.psm1') -Force

$permissionPreflights = [Collections.Generic.List[object]]::new()
$preflightContexts = [Collections.Generic.List[object]]::new()
foreach ($permissionMode in 'read', 'allow', 'deny') {
    $context = New-MeechoEvalContext `
        -Mode $Mode `
        -RunId $RunId `
        -CaseId preflight `
        -ScenarioId $permissionMode `
        -Model $Model `
        -ReasoningEffort $ReasoningEffort `
        -PermissionMode $permissionMode
    $preflightContexts.Add($context)
    $result = Test-MeechoEvalPreflight -Context $context
    $permissionPreflights.Add([ordered]@{
        permissionMode = $permissionMode
        status = $result.Status
        passed = $result.Passed
        checks = @($result.Checks)
        failures = @($result.Failures)
        configSha256 = $context.ConfigSha256
    })
}
$preflightContext = $preflightContexts[0]
$preflightFailures = @(
    $permissionPreflights |
        ForEach-Object failures |
        Sort-Object -Unique
)
$preflightStatus = if (@(
    $permissionPreflights | Where-Object status -EQ 'BLOCKED_NOT_RUN'
).Count -gt 0) {
    'BLOCKED_NOT_RUN'
}
elseif (@(
    $permissionPreflights | Where-Object status -EQ 'AUTH_REQUIRED'
).Count -gt 0) {
    'AUTH_REQUIRED'
}
else {
    'ready'
}
$readyCodexVersions = @(
    @(
        foreach ($permissionPreflight in $permissionPreflights) {
            if ([string]$permissionPreflight.status -cne 'ready') {
                continue
            }
            foreach ($check in @($permissionPreflight.checks)) {
                if ([string]$check.Name -ceq 'codex-version' -and
                    $check.Passed -is [bool] -and
                    [bool]$check.Passed) {
                    [string]$check.Detail
                }
            }
        }
    ) | Sort-Object -Unique
)
$codexVersion = if ($readyCodexVersions.Count -eq 1) {
    [string]$readyCodexVersions[0]
}
else {
    ''
}
if ($preflightStatus -ceq 'ready' -and
    $readyCodexVersions.Count -ne 1) {
    $preflightStatus = 'BLOCKED_NOT_RUN'
    $preflightFailures = @($preflightFailures) + @(
        'CODEX_VERSION_EVIDENCE_INVALID'
    )
}
$preflight = [pscustomobject][ordered]@{
    Passed = ($preflightStatus -ceq 'ready')
    Status = $preflightStatus
    Checks = @($permissionPreflights)
    Failures = @($preflightFailures)
}
$capsuleModule = Get-Module EvalCapsule -ErrorAction Stop
$effectiveEnvironmentNames = @(
    & $capsuleModule {
        param($EvalContext)
        Get-MeechoChildEnvironmentNames -Context $EvalContext
    } $preflightContext
)
$rubricPath = Join-Path $repoRoot 'evals/rubric.md'
$rubricSha256 = (Get-FileHash -LiteralPath $rubricPath -Algorithm SHA256).Hash.ToLowerInvariant()
$codexCommand = Get-Command codex -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$codexBinarySha256 = ''
if ($codexCommand -and (Test-Path -LiteralPath $codexCommand.Source -PathType Leaf)) {
    try {
        $codexBinarySha256 = (Get-FileHash -LiteralPath $codexCommand.Source -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    catch {
        $codexBinarySha256 = ''
    }
}
$manifest = [ordered]@{
    schemaVersion = 1
    kind = 'meecho-eval-run'
    runId = $RunId
    mode = $Mode
    status = if ($preflight.Status -eq 'ready') { 'READY' } else { $preflight.Status }
    model = $Model
    reasoningEffort = $ReasoningEffort
    capsuleRoot = $preflightContext.CapsuleRoot
    repoRoot = $repoRoot
    configSha256 = $preflightContext.ConfigSha256
    rubricSha256 = $rubricSha256
    codexVersion = $codexVersion
    codexBinary = if ($codexCommand) { [IO.Path]::GetFileName($codexCommand.Source) } else { '' }
    codexBinarySha256 = $codexBinarySha256
    approvalPolicy = 'never'
    environmentNames = @($effectiveEnvironmentNames)
    realProfileBeforeSha256 = $script:realProfileBeforeEvidence.InventorySha256
    realProfileBeforeInventory = ConvertTo-MeechoInventoryReference `
        -Evidence $script:realProfileBeforeEvidence
    permissionPreflights = @($permissionPreflights)
    checks = @($preflight.Checks)
    steps = @(Get-MeechoStepReferences -Root (Join-Path $repoRoot "evals/logs/$RunId"))
    cases = @()
    failures = @($preflight.Failures)
}

if (-not $preflight.Passed) {
    $realProfileUnchanged = Add-MeechoRealProfileTerminalEvidence -TargetManifest $manifest
    if (-not $realProfileUnchanged) {
        $manifest.status = 'BLOCKED_NOT_RUN'
    }
    Write-MeechoRunManifest -Manifest $manifest -Path $manifestPath
    if (-not (Update-BaselineSummary)) {
        $manifest.failures = @($manifest.failures) + @('SUMMARY_VALIDATION_FAILED')
        $manifest.status = 'BLOCKED_NOT_RUN'
        Write-MeechoRunManifest -Manifest $manifest -Path $manifestPath
    }
    $terminalStatus = [string] $manifest.status
    $exitCode = if ($terminalStatus -eq 'AUTH_REQUIRED') { 2 } else { 3 }
    Write-BaselineResultAndExit -Status $terminalStatus -ExitCode $exitCode
}

if ($PreflightOnly) {
    $manifest.status = 'BLOCKED_NOT_RUN'
    $manifest.failures = @('PREFLIGHT_ONLY_NO_BEHAVIOR')
    [void](Add-MeechoRealProfileTerminalEvidence -TargetManifest $manifest)
    Write-MeechoRunManifest -Manifest $manifest -Path $manifestPath
    if (-not (Update-BaselineSummary)) {
        $manifest.failures = @($manifest.failures) + @('SUMMARY_VALIDATION_FAILED')
        Write-MeechoRunManifest -Manifest $manifest -Path $manifestPath
    }
    Write-BaselineResultAndExit -Status 'BLOCKED_NOT_RUN' -ExitCode 3
}

$casePaths = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'evals/cases') -Filter '*.md' -File | Sort-Object Name | ForEach-Object FullName)
Test-MeechoEvalCaseRegistry -Paths $casePaths | Out-Null

$caseResults = [Collections.Generic.List[object]]::new()
$terminalFailures = [Collections.Generic.List[string]]::new()

try {
    foreach ($casePath in $casePaths) {
        $definition = Get-MeechoEvalCaseDefinition -Path $casePath
        foreach ($scenario in $definition.Scenarios) {
            $context = New-MeechoEvalContext `
                -Mode $Mode `
                -RunId $RunId `
                -CaseId $definition.CaseId `
                -ScenarioId $scenario.id `
                -Model $Model `
                -ReasoningEffort $ReasoningEffort `
                -PermissionMode $scenario.permissionMode

            $stage = Initialize-MeechoEvalScenario -Context $context -CasePath $casePath
            $workspaceBefore = @(Get-MeechoFileInventory -Path $context.ScenarioWorkspace)
            $profilePath = Join-Path $context.ScenarioUserHome '.meecho'
            $profileBefore = @(Get-MeechoFileInventory -Path $profilePath)
            $profileBeforeEvidence = Write-MeechoInventoryEvidence `
                -Inventory $profileBefore `
                -Path (Join-Path $context.StepLogRoot 'profile-before-inventory.json')
            $inputEvidence = @(
                $stage.AccessibleFiles | ForEach-Object {
                    [ordered]@{
                        source = $_.Source
                        destination = $_.Destination
                        sha256 = $_.Sha256
                    }
                }
            )
            $caseInputSha256 = Get-MeechoInventoryDigest -Inventory @(
                [ordered]@{
                    casePathSha256 = (Get-FileHash -LiteralPath $casePath -Algorithm SHA256).Hash.ToLowerInvariant()
                    accessibleFiles = $inputEvidence
                }
            )

            $invocations = @($stage.Invocations)
            if ($invocations.Count -eq 0) {
                $invocations = @(
                    [pscustomobject]@{
                        Id = 'main'
                        PromptPath = $stage.PromptPath
                        WorkingDirectory = $context.ScenarioWorkspace
                    }
                )
            }

            $eventBuilder = [Text.StringBuilder]::new()
            $stderrBuilder = [Text.StringBuilder]::new()
            $finalBuilder = [Text.StringBuilder]::new()
            $invocationResults = [Collections.Generic.List[object]]::new()
            $infrastructureFailure = $null

            foreach ($invocation in $invocations) {
                $invocationId = [string] $invocation.Id
                $invocationLogRoot = Join-Path $context.StepLogRoot "invocations/$invocationId"
                if (-not (Test-Path -LiteralPath $invocationLogRoot -PathType Container)) {
                    New-Item -ItemType Directory -Path $invocationLogRoot -Force | Out-Null
                }
                $invocationFinal = Join-Path $invocationLogRoot 'final.md'
                $invocationJsonl = Join-Path $invocationLogRoot 'events.jsonl'
                $invocationStderr = Join-Path $invocationLogRoot 'codex.stderr.log'
                $workingDirectory = [string] $invocation.WorkingDirectory
                $workingBefore = @(Get-MeechoFileInventory -Path $workingDirectory)
                $startedAtUtc = (Get-Date).ToUniversalTime().ToString('o')

                $execution = Invoke-MeechoEvalCase `
                    -Context $context `
                    -PromptPath $invocation.PromptPath `
                    -FinalPath $invocationFinal `
                    -JsonlPath $invocationJsonl `
                    -StderrPath $invocationStderr `
                    -WorkingDirectory $workingDirectory

                $evidence = Test-MeechoInvocationEvidence `
                    -JsonlPath $invocationJsonl `
                    -FinalPath $invocationFinal
                $workingAfter = @(Get-MeechoFileInventory -Path $workingDirectory)
                $endedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
                [void] $eventBuilder.AppendLine((ConvertTo-Json ([ordered]@{
                    type = 'meecho-eval-invocation'
                    id = $invocationId
                }) -Compress))
                [void] $eventBuilder.AppendLine((Get-Content -LiteralPath $invocationJsonl -Raw -Encoding UTF8))
                [void] $stderrBuilder.AppendLine("[$invocationId]")
                [void] $stderrBuilder.AppendLine((Get-Content -LiteralPath $invocationStderr -Raw -Encoding UTF8))
                [void] $finalBuilder.AppendLine("## $invocationId")
                [void] $finalBuilder.AppendLine()
                [void] $finalBuilder.AppendLine((Get-Content -LiteralPath $invocationFinal -Raw -Encoding UTF8))
                [void] $finalBuilder.AppendLine()

                $invocationResults.Add([ordered]@{
                    id = $invocationId
                    workingDirectory = $workingDirectory
                    workspaceRoots = if ($scenario.permissionMode -eq 'allow') {
                        @($workingDirectory, $context.ScenarioUserHome)
                    }
                    else {
                        @($workingDirectory)
                    }
                    exitCode = $execution.ExitCode
                    startedAtUtc = $startedAtUtc
                    endedAtUtc = $endedAtUtc
                    workspaceBeforeSha256 = Get-MeechoInventoryDigest -Inventory $workingBefore
                    workspaceAfterSha256 = Get-MeechoInventoryDigest -Inventory $workingAfter
                    finalPath = $invocationFinal
                    jsonlPath = $invocationJsonl
                    stderrPath = $invocationStderr
                    jsonlValid = $evidence.JsonlValid
                    turnCompleted = $evidence.TurnCompleted
                    finalValid = $evidence.FinalValid
                })
                if ($execution.ExitCode -ne 0) {
                    $infrastructureFailure = "CASE_INFRASTRUCTURE_EXIT:$($definition.CaseId):$($scenario.id):${invocationId}:$($execution.ExitCode)"
                    break
                }
                if (-not $evidence.JsonlValid) {
                    $infrastructureFailure = "CASE_INVALID_JSONL:$($definition.CaseId):$($scenario.id):${invocationId}"
                    break
                }
                if (-not $evidence.TurnCompleted) {
                    $infrastructureFailure = "CASE_TURN_NOT_COMPLETED:$($definition.CaseId):$($scenario.id):${invocationId}"
                    break
                }
                if (-not $evidence.FinalValid) {
                    $infrastructureFailure = "CASE_FINAL_MISSING:$($definition.CaseId):$($scenario.id):${invocationId}"
                    break
                }
            }

            $jsonlPath = Join-Path $context.StepLogRoot 'events.jsonl'
            $stderrPath = Join-Path $context.StepLogRoot 'codex.stderr.log'
            $finalPath = Join-Path $context.StepLogRoot 'final.md'
            [IO.File]::WriteAllText($jsonlPath, $eventBuilder.ToString(), [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($stderrPath, $stderrBuilder.ToString(), [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($finalPath, $finalBuilder.ToString(), [Text.UTF8Encoding]::new($false))

            $workspaceAfter = @(Get-MeechoFileInventory -Path $context.ScenarioWorkspace)
            $profileAfter = @(Get-MeechoFileInventory -Path $profilePath)
            $profileAfterEvidence = Write-MeechoInventoryEvidence `
                -Inventory $profileAfter `
                -Path (Join-Path $context.StepLogRoot 'profile-after-inventory.json')
            $resultPath = Join-Path $context.StepLogRoot 'result.json'
            $resultRecord = [ordered]@{
                caseId = $definition.CaseId
                scenarioId = $scenario.id
                permissionMode = $scenario.permissionMode
                status = 'BLOCKED_NOT_RUN'
                caseInputSha256 = $caseInputSha256
                rubricSha256 = $rubricSha256
                failedItems = @()
                rubric = @(
                    1..17 | ForEach-Object {
                        [ordered]@{
                            item = $_
                            score = 'needs-human-review'
                            evidence = @()
                        }
                    }
                )
                invocations = @($invocationResults)
                workspaceBeforeSha256 = Get-MeechoInventoryDigest -Inventory $workspaceBefore
                workspaceAfterSha256 = Get-MeechoInventoryDigest -Inventory $workspaceAfter
                profileBeforeSha256 = $profileBeforeEvidence.InventorySha256
                profileAfterSha256 = $profileAfterEvidence.InventorySha256
            }
            $resultRecord | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $resultPath -Encoding UTF8

            $artifacts = [Collections.Generic.List[object]]::new()
            foreach ($artifact in ([ordered]@{
                jsonl = $jsonlPath
                stderr = $stderrPath
                final = $finalPath
                result = $resultPath
                'profile-before-inventory' = $profileBeforeEvidence.Path
                'profile-after-inventory' = $profileAfterEvidence.Path
            }).GetEnumerator()) {
                $artifacts.Add([ordered]@{
                    kind = $artifact.Key
                    path = $artifact.Value
                    sha256 = (Get-FileHash -LiteralPath $artifact.Value -Algorithm SHA256).Hash.ToLowerInvariant()
                })
            }

            $caseResults.Add([ordered]@{
                caseId = $definition.CaseId
                scenarioId = $scenario.id
                permissionMode = $scenario.permissionMode
                status = 'BLOCKED_NOT_RUN'
                failures = if ($infrastructureFailure) {
                    @($infrastructureFailure)
                }
                else {
                    @('RUBRIC_HUMAN_REVIEW_REQUIRED')
                }
                scenarioRoot = $context.ScenarioRoot
                scenarioUserHome = $context.ScenarioUserHome
                scenarioWorkspace = $context.ScenarioWorkspace
                scenarioTemp = $context.ScenarioTemp
                codexSqliteHome = $context.CodexSqliteHome
                stepLogRoot = $context.StepLogRoot
                environmentNames = @($effectiveEnvironmentNames)
                caseInputSha256 = $caseInputSha256
                rubricSha256 = $rubricSha256
                initialProfileSha256 = $profileBeforeEvidence.InventorySha256
                finalProfileSha256 = $profileAfterEvidence.InventorySha256
                invocations = @($invocationResults)
                artifacts = @($artifacts)
            })

            if ($infrastructureFailure) {
                throw $infrastructureFailure
            }
        }
    }
    $terminalFailures.Add('RUBRIC_HUMAN_REVIEW_REQUIRED')
}
catch {
    $safeFailureCode = Get-MeechoStableFailureCode -Exception $_.Exception
    if ($safeFailureCode -match '^CASE_(?:INFRASTRUCTURE_EXIT|INVALID_JSONL|TURN_NOT_COMPLETED|FINAL_MISSING):[A-Za-z0-9-]+:[A-Za-z0-9-]+:[A-Za-z0-9-]+(?::[0-9]+)?$') {
        $terminalFailures.Add($safeFailureCode)
    }
    elseif ($safeFailureCode -match '^INVENTORY_EVIDENCE_[A-Z0-9_]+$') {
        $terminalFailures.Add($safeFailureCode)
    }
    else {
        $terminalFailures.Add("HARNESS_EXCEPTION:$($_.Exception.GetType().Name)")
    }
}

[void](Add-MeechoRealProfileTerminalEvidence -TargetManifest $manifest)
if (@($manifest.failures) -contains 'REAL_PROFILE_CHANGED') {
    $terminalFailures.Add('REAL_PROFILE_CHANGED')
}
$manifest.status = 'BLOCKED_NOT_RUN'
$manifest.failures = @($terminalFailures | Sort-Object -Unique)
$manifest.cases = @($caseResults)
$manifest.steps = @(Get-MeechoStepReferences -Root (Join-Path $repoRoot "evals/logs/$RunId"))
Write-MeechoRunManifest -Manifest $manifest -Path $manifestPath
if (-not (Update-BaselineSummary)) {
    $manifest.failures = @($manifest.failures) + @('SUMMARY_VALIDATION_FAILED')
    Write-MeechoRunManifest -Manifest $manifest -Path $manifestPath
}
Write-BaselineResultAndExit -Status 'BLOCKED_NOT_RUN' -ExitCode 3
