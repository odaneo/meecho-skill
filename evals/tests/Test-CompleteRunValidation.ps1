Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'TestSupport.psm1') -Force
$repoRoot = Get-MeechoRepoRoot
$validator = Join-Path $repoRoot 'evals/scripts/Invoke-EvalValidation.ps1'
Import-Module (Join-Path $repoRoot 'evals/scripts/EvalAudit.psm1') -Force
Import-Module (Join-Path $repoRoot 'evals/scripts/CaseStaging.psm1') -Force

function Invoke-Validator {
    param([string] $ManifestPath)

    $stderr = ''
    $stdout = @(
        . $validator -ManifestPath $ManifestPath -PassThru 2>&1
    ) -join [Environment]::NewLine
    $json = if ($stdout.Trim()) {
        $stdout.Trim() | ConvertFrom-Json -Depth 50
    }
    else {
        $null
    }
    return [pscustomobject]@{
        ExitCode = if ($null -ne $json -and $json.Valid) { 0 } else { 1 }
        Stderr = $stderr
        Json = $json
    }
}

function Copy-JsonObject {
    param([Parameter(Mandatory)][object] $InputObject)
    return $InputObject | ConvertTo-Json -Depth 50 | ConvertFrom-Json -Depth 50
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)][object] $InputObject,
        [Parameter(Mandatory)][string] $Path
    )
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $InputObject | ConvertTo-Json -Depth 50 |
        Set-Content -LiteralPath $Path -Encoding UTF8
}

function Write-CaseMetadata {
    param(
        [Parameter(Mandatory)][string] $CasesRoot,
        [Parameter(Mandatory)][string] $CaseId,
        [Parameter(Mandatory)][object[]] $Scenarios,
        [object[]] $Invocations = @()
    )

    $metadata = [ordered]@{
        caseId = $CaseId
        scenarios = @($Scenarios)
        accessibleFiles = @()
    }
    if (@($Invocations).Count -gt 0) {
        $metadata.invocations = @($Invocations)
    }
    $metadata = $metadata | ConvertTo-Json -Depth 10 -Compress
    @"
# $CaseId
<!-- meecho-eval
$metadata
-->

## User request
x

## Accessible files
x

## Forbidden state
x

## Observable assertions
x
"@ | Set-Content -LiteralPath (Join-Path $CasesRoot "$CaseId.md") -Encoding UTF8
}

function Get-StringSha256 {
    param([AllowEmptyString()][string] $Value)

    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Value)
    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($bytes)
    ).ToLowerInvariant()
}

function Copy-AccessibleFixtureFiles {
    param(
        [Parameter(Mandatory)][object] $CaseDefinition,
        [Parameter(Mandatory)][string] $ScenarioWorkspace
    )

    foreach ($file in @($CaseDefinition.AccessibleFiles)) {
        $destination = Join-Path $ScenarioWorkspace ([string]$file.Destination)
        $destinationParent = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
            New-Item -ItemType Directory -Path $destinationParent -Force |
                Out-Null
        }
        Copy-Item -LiteralPath ([string]$file.SourcePath) -Destination $destination
    }
}

function Get-FixtureCaseInputSha256 {
    param(
        [Parameter(Mandatory)][object] $CaseDefinition,
        [Parameter(Mandatory)][string] $ScenarioWorkspace
    )

    $accessibleFiles = @(
        foreach ($file in @($CaseDefinition.AccessibleFiles)) {
            $destination = Join-Path $ScenarioWorkspace ([string]$file.Destination)
            [ordered]@{
                source = [string]$file.Source
                destination = [string]$file.Destination
                sha256 = (
                    Get-FileHash -LiteralPath $destination -Algorithm SHA256
                ).Hash.ToLowerInvariant()
            }
        }
    )
    $payload = @(
        [ordered]@{
            casePathSha256 = (
                Get-FileHash `
                    -LiteralPath ([string]$CaseDefinition.Path) `
                    -Algorithm SHA256
            ).Hash.ToLowerInvariant()
            accessibleFiles = $accessibleFiles
        }
    )
    return Get-StringSha256 -Value (
        ConvertTo-Json @($payload) -Compress -Depth 30
    )
}

function Get-FixtureInvocationDefinitions {
    param(
        [Parameter(Mandatory)][object] $CaseDefinition,
        [Parameter(Mandatory)][object] $Scenario
    )

    if (@($CaseDefinition.Invocations).Count -gt 0) {
        return @($CaseDefinition.Invocations)
    }
    $prompt = if (-not [string]::IsNullOrWhiteSpace([string]$Scenario.Prompt)) {
        [string]$Scenario.Prompt
    }
    else {
        [string]$CaseDefinition.UserRequest
    }
    return @(
        [pscustomobject]@{
            Id = 'main'
            Prompt = $prompt
            ProjectRoot = ''
        }
    )
}

function New-StepRecordFixture {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $StepName,
        [Parameter(Mandatory)][string] $Command,
        [Parameter(Mandatory)][string[]] $Arguments,
        [Parameter(Mandatory)][string[]] $EnvironmentNames,
        [AllowEmptyString()][string] $CommandSha256 = '',
        [AllowEmptyString()][string] $StdoutText = '',
        [AllowEmptyString()][string] $StderrText = '',
        [int] $ExitCode = 0
    )

    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    $stdoutPath = Join-Path $Root "$StepName.stdout.log"
    $stderrPath = Join-Path $Root "$StepName.stderr.log"
    $exitCodePath = Join-Path $Root "$StepName.exit-code.txt"
    [IO.File]::WriteAllText($stdoutPath, $StdoutText, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($stderrPath, $StderrText, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($exitCodePath, [string]$ExitCode, [Text.UTF8Encoding]::new($false))
    $artifactPaths = @($stdoutPath, $stderrPath, $exitCodePath)
    $checksumsPath = Join-Path $Root "$StepName.sha256"
    $checksumLines = @(
        $artifactPaths | ForEach-Object {
            '{0}  {1}' -f (
                Get-FileHash -LiteralPath $_ -Algorithm SHA256
            ).Hash.ToLowerInvariant(), (Split-Path -Leaf $_)
        }
    )
    [IO.File]::WriteAllText(
        $checksumsPath,
        (($checksumLines -join "`n") + "`n"),
        [Text.UTF8Encoding]::new($false)
    )
    $record = [ordered]@{
        schemaVersion = 1
        kind = 'meecho-eval-step'
        stepName = $StepName
        started = $true
        timedOut = $false
        exitCode = $ExitCode
        startedAtUtc = '2026-07-25T05:00:00.0000000Z'
        endedAtUtc = '2026-07-25T05:00:01.0000000Z'
        failureCode = ''
        command = $Command
        commandSha256 = $CommandSha256
        arguments = @($Arguments)
        environmentNames = @($EnvironmentNames)
        stdout = [ordered]@{
            path = Split-Path -Leaf $stdoutPath
            sha256 = (Get-FileHash -LiteralPath $stdoutPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        stderr = [ordered]@{
            path = Split-Path -Leaf $stderrPath
            sha256 = (Get-FileHash -LiteralPath $stderrPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        exitCodeArtifact = [ordered]@{
            path = Split-Path -Leaf $exitCodePath
            sha256 = (Get-FileHash -LiteralPath $exitCodePath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        checksums = [ordered]@{
            path = Split-Path -Leaf $checksumsPath
            sha256 = (Get-FileHash -LiteralPath $checksumsPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    $recordPath = Join-Path $Root "$StepName.record.json"
    Write-JsonFile -InputObject $record -Path $recordPath
    return [pscustomobject]@{
        RecordPath = $recordPath
        Step = [ordered]@{
            name = $StepName
            recordPath = $recordPath
            recordSha256 = (
                Get-FileHash -LiteralPath $recordPath -Algorithm SHA256
            ).Hash.ToLowerInvariant()
        }
    }
}

function New-InvocationFixture {
    param(
        [Parameter(Mandatory)][string] $StepLogRoot,
        [Parameter(Mandatory)][string] $ScenarioWorkspace,
        [Parameter(Mandatory)][string] $ScenarioUserHome,
        [Parameter(Mandatory)][ValidateSet('read', 'allow', 'deny')][string] $PermissionMode,
        [Parameter(Mandatory)][string] $InvocationId,
        [Parameter(Mandatory)][string] $Prompt,
        [Parameter(Mandatory)][string] $PromptPath,
        [AllowEmptyString()][string] $ProjectRoot = '',
        [Parameter(Mandatory)][string] $Model,
        [Parameter(Mandatory)][string] $CodexBinary,
        [Parameter(Mandatory)][string] $CodexBinarySha256,
        [Parameter(Mandatory)][string[]] $EnvironmentNames
    )

    $workingDirectory = if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
        $ScenarioWorkspace
    }
    else {
        Join-Path $ScenarioWorkspace $ProjectRoot
    }
    New-Item -ItemType Directory -Path $workingDirectory -Force | Out-Null
    $invocationRoot = Join-Path $StepLogRoot "invocations/$InvocationId"
    New-Item -ItemType Directory -Path $invocationRoot -Force | Out-Null
    $promptParent = Split-Path -Parent $PromptPath
    if (-not (Test-Path -LiteralPath $promptParent -PathType Container)) {
        New-Item -ItemType Directory -Path $promptParent -Force | Out-Null
    }
    [IO.File]::WriteAllText(
        $PromptPath,
        $Prompt,
        [Text.UTF8Encoding]::new($false)
    )
    $finalPath = Join-Path $invocationRoot 'final.md'
    $jsonlPath = Join-Path $invocationRoot 'events.jsonl'
    $stderrPath = Join-Path $invocationRoot 'codex.stderr.log'
    $jsonlText = [ordered]@{
        type = 'turn.completed'
        invocationId = $InvocationId
    } | ConvertTo-Json -Compress
    $finalText = "final-$InvocationId"
    [IO.File]::WriteAllText($finalPath, $finalText, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($jsonlPath, $jsonlText, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($stderrPath, '', [Text.UTF8Encoding]::new($false))

    $arguments = [Collections.Generic.List[string]]::new()
    $arguments.Add('--strict-config')
    if ($PermissionMode -ceq 'allow') {
        $arguments.Add('--add-dir')
        $arguments.Add($ScenarioUserHome)
    }
    foreach ($argument in @(
        'exec',
        '--ephemeral',
        '--ignore-rules',
        '--json',
        '--model',
        $Model,
        '-c',
        'approval_policy="never"',
        '-c',
        "default_permissions=`"meecho-capsule-$PermissionMode`"",
        '-C',
        $workingDirectory,
        '--output-last-message',
        $finalPath,
        (
            '<prompt sha256=' +
            (Get-StringSha256 -Value $Prompt) +
            " length=$($Prompt.Length)>"
        )
    )) {
        $arguments.Add([string]$argument)
    }
    $stepName = 'codex-exec-' + (Get-StringSha256 -Value (
        [IO.Path]::GetFullPath($jsonlPath)
    )).Substring(0, 12)
    $stepFixture = New-StepRecordFixture `
        -Root $StepLogRoot `
        -StepName $stepName `
        -Command $CodexBinary `
        -CommandSha256 $CodexBinarySha256 `
        -Arguments @($arguments) `
        -EnvironmentNames $EnvironmentNames `
        -StdoutText $jsonlText `
        -StderrText ''
    $invocation = [ordered]@{
        id = $InvocationId
        workingDirectory = $workingDirectory
        workspaceRoots = if ($PermissionMode -ceq 'allow') {
            @($workingDirectory, $ScenarioUserHome)
        }
        else {
            @($workingDirectory)
        }
        exitCode = 0
        startedAtUtc = '2026-07-25T05:00:00.0000000Z'
        endedAtUtc = '2026-07-25T05:00:01.0000000Z'
        workspaceBeforeSha256 = ('2' * 64)
        workspaceAfterSha256 = ('3' * 64)
        finalPath = $finalPath
        jsonlPath = $jsonlPath
        stderrPath = $stderrPath
        jsonlValid = $true
        turnCompleted = $true
        finalValid = $true
    }
    return [pscustomobject]@{
        Invocation = $invocation
        Step = $stepFixture.Step
        JsonlText = $jsonlText
        FinalText = $finalText
    }
}

function Update-ResultArtifactHash {
    param(
        [Parameter(Mandatory)][object] $Manifest,
        [Parameter(Mandatory)][int] $CaseIndex
    )
    $artifact = @(
        $Manifest.cases[$CaseIndex].artifacts |
            Where-Object { [string]$_.kind -ceq 'result' }
    )[0]
    $artifact.sha256 = (
        Get-FileHash -LiteralPath ([string]$artifact.path) -Algorithm SHA256
    ).Hash.ToLowerInvariant()
}

function Update-StepReferenceHash {
    param(
        [Parameter(Mandatory)][object] $Manifest,
        [Parameter(Mandatory)][string] $RecordPath
    )

    $fullRecordPath = [IO.Path]::GetFullPath($RecordPath)
    $matches = @(
        $Manifest.steps | Where-Object {
            [IO.Path]::GetFullPath([string]$_.recordPath).Equals(
                $fullRecordPath,
                [StringComparison]::OrdinalIgnoreCase
            )
        }
    )
    Assert-Equal 1 $matches.Count "Fixture must contain one step reference for $RecordPath."
    $matches[0].recordSha256 = (
        Get-FileHash -LiteralPath $RecordPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
}

function Update-CanaryReferenceHash {
    param(
        [Parameter(Mandatory)][object] $Manifest,
        [Parameter(Mandatory)][string] $RecordPath
    )

    $fullRecordPath = [IO.Path]::GetFullPath($RecordPath)
    $matches = @(
        $Manifest.canaryRefs | Where-Object {
            [IO.Path]::GetFullPath([string]$_.recordPath).Equals(
                $fullRecordPath,
                [StringComparison]::OrdinalIgnoreCase
            )
        }
    )
    Assert-Equal 1 $matches.Count "Fixture must contain one canary reference for $RecordPath."
    $matches[0].recordSha256 = (
        Get-FileHash -LiteralPath $RecordPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
}

function New-ComparisonSide {
    param(
        [Parameter(Mandatory)][object] $RunManifest,
        [Parameter(Mandatory)][object] $Case,
        [Parameter(Mandatory)][string] $ManifestPath
    )

    return [ordered]@{
        mode = [string]$RunManifest.mode
        runId = [string]$RunManifest.runId
        manifestPath = $ManifestPath
        manifestSha256 = (
            Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        codexBinarySha256 = [string]$RunManifest.codexBinarySha256
        codexVersion = [string]$RunManifest.codexVersion
        model = [string]$RunManifest.model
        reasoningEffort = [string]$RunManifest.reasoningEffort
        serviceTier = [string]$RunManifest.serviceTier
        configSha256 = [string]$RunManifest.configSha256
        permissionMode = [string]$Case.permissionMode
        approvalPolicy = [string]$RunManifest.approvalPolicy
        environmentNames = @($RunManifest.environmentNames)
        caseInputSha256 = [string]$Case.caseInputSha256
        rubricSha256 = [string]$Case.rubricSha256
        initialProfileSha256 = [string]$Case.initialProfileSha256
    }
}

function New-CanaryEvidence {
    param(
        [Parameter(Mandatory)][string] $FixtureRepoRoot,
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][ValidateSet('control', 'treatment')][string] $Mode,
        [Parameter(Mandatory)][ValidateSet('read', 'allow', 'deny')][string] $PermissionMode,
        [Parameter(Mandatory)][string] $CodexBinary,
        [Parameter(Mandatory)][string] $CodexBinarySha256,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Environment
    )

    $canaryRoot = Join-Path $FixtureRepoRoot (
        "evals/logs/$RunId/$Mode/preflight/$PermissionMode"
    )
    New-Item -ItemType Directory -Path $canaryRoot -Force | Out-Null
    $suffixes = @{
        'control/read' = '000000000001'
        'control/allow' = '000000000002'
        'control/deny' = '000000000003'
        'treatment/read' = '000000000004'
        'treatment/allow' = '000000000005'
        'treatment/deny' = '000000000006'
    }
    $stepName = 'codex-exec-' + $suffixes["$Mode/$PermissionMode"]
    $stepFixture = New-StepRecordFixture `
        -Root $canaryRoot `
        -StepName $stepName `
        -Command $CodexBinary `
        -CommandSha256 $CodexBinarySha256 `
        -Arguments @(
            '--strict-config',
            'exec',
            '--ephemeral',
            '--ignore-rules',
            '--json'
        ) `
        -EnvironmentNames @($Environment.Keys) `
        -StdoutText '{"type":"turn.completed"}'
    Set-Content -LiteralPath (Join-Path $canaryRoot 'canary-prompt.md') -Value 'probe' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $canaryRoot 'canary-final.md') -Value 'ok' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $canaryRoot 'canary-events.jsonl') -Value '{"type":"turn.completed"}' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $canaryRoot 'canary-stderr.log') -Value '' -Encoding UTF8

    $canaryPath = Join-Path $canaryRoot 'canary-result.json'
    Write-JsonFile -InputObject ([ordered]@{
        schemaVersion = 1
        kind = 'meecho-eval-permission-canary'
        mode = $Mode
        runId = $RunId
        caseId = 'preflight'
        scenarioId = $PermissionMode
        permissionMode = $PermissionMode
        status = 'PASS'
        exitCode = 0
        capsuleForbiddenReadDenied = $true
        realHomeReadDenied = $true
        realHomeMarkerUnchanged = $true
        realHomeMarkerCleanupPassed = $true
        realHomeMarkerSha256 = ('9' * 64)
        artifacts = @(
            'canary-prompt.md',
            'canary-final.md',
            'canary-events.jsonl',
            'canary-stderr.log',
            [System.IO.Path]::GetFileName($stepFixture.RecordPath)
        )
    }) -Path $canaryPath

    return [pscustomobject]@{
        Ref = [ordered]@{
            permissionMode = $PermissionMode
            recordPath = $canaryPath
            recordSha256 = (
                Get-FileHash -LiteralPath $canaryPath -Algorithm SHA256
            ).Hash.ToLowerInvariant()
        }
        Step = [ordered]@{
            name = $stepName
            recordPath = $stepFixture.RecordPath
            recordSha256 = (
                Get-FileHash -LiteralPath $stepFixture.RecordPath -Algorithm SHA256
            ).Hash.ToLowerInvariant()
        }
    }
}

function New-PermissionPreflights {
    param(
        [Parameter(Mandatory)][string] $ConfigSha256,
        [string] $CodexVersion = '0.145.0'
    )

    $commonCheckNames = @(
        'context-shape-and-paths',
        'powershell-version',
        'reasoning-effort',
        'effective-config',
        'real-home-isolation',
        'control-meecho-off',
        'codex-command',
        'codex-version',
        'codex-capabilities',
        'isolated-authentication'
    )
    return @(
        foreach ($permissionMode in 'read', 'allow', 'deny') {
            $checks = @(
                foreach ($checkName in $commonCheckNames) {
                    [ordered]@{
                        Name = $checkName
                        Passed = $true
                        Detail = if ($checkName -ceq 'codex-version') {
                            $CodexVersion
                        }
                        else {
                            'fixture-pass'
                        }
                    }
                }
            )
            $checks += [ordered]@{
                Name = "permission-canary-$permissionMode"
                Passed = $true
                Detail = 'fixture-pass'
            }
            [ordered]@{
                permissionMode = $permissionMode
                status = 'ready'
                passed = $true
                checks = @($checks)
                failures = @()
                configSha256 = $ConfigSha256
            }
        }
    )
}

$allowedEnvironmentNames = @(
    'SystemRoot',
    'WINDIR',
    'COMSPEC',
    'PATHEXT',
    'PATH',
    'TEMP',
    'TMP',
    'LOCALAPPDATA',
    'APPDATA',
    'ProgramData',
    'ProgramFiles',
    'ProgramFiles(x86)',
    'CommonProgramFiles',
    'CommonProgramFiles(x86)',
    'USERNAME',
    'USERDOMAIN',
    'USERPROFILE',
    'HOME',
    'CODEX_HOME',
    'CODEX_SQLITE_HOME'
)
$requiredRewrittenEnvironmentNames = @(
    'TEMP',
    'TMP',
    'LOCALAPPDATA',
    'APPDATA',
    'USERPROFILE',
    'HOME',
    'CODEX_HOME',
    'CODEX_SQLITE_HOME'
)

$testRoot = New-MeechoTestRoot
$junctionPath = $null
$createdRunLogRoots = [Collections.Generic.List[string]]::new()
try {
    $runId = '{0}-{1}' -f (
        [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    ), ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $fixtureRepoRoot = $repoRoot
    $capsuleRoot = Join-Path $testRoot 'capsule'
    $casesRoot = Join-Path $fixtureRepoRoot 'evals/cases'
    New-Item -ItemType Directory -Path $capsuleRoot -Force | Out-Null
    $pairRunRoot = Join-Path $capsuleRoot "runs/$runId"
    $locksRoot = Join-Path $capsuleRoot 'locks'
    New-Item -ItemType Directory -Path $pairRunRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $locksRoot -Force | Out-Null
    $pairLockPath = Join-Path $pairRunRoot '.pair.lock'
    $allocationLockPath = Join-Path $locksRoot "$runId.run.lock"
    foreach ($markerPath in $pairLockPath, $allocationLockPath) {
        [IO.File]::WriteAllText(
            $markerPath,
            $runId,
            [Text.UTF8Encoding]::new($false)
        )
    }
    $createdRunLogRoots.Add(
        (Join-Path $fixtureRepoRoot "evals/logs/$runId")
    )

    $definitions = @(
        Get-ChildItem -LiteralPath $casesRoot -Filter '*.md' -File |
            Sort-Object Name |
            ForEach-Object {
                Get-MeechoEvalCaseDefinition -Path $_.FullName
            }
    )
    $definitionByCaseId = @{}
    foreach ($definition in $definitions) {
        $definitionByCaseId[[string]$definition.CaseId] = $definition
    }

    $model = 'gpt-test'
    $codexBinary = 'codex.exe'
    $fixtureBinaryPath = Join-Path $capsuleRoot $codexBinary
    [IO.File]::WriteAllText(
        $fixtureBinaryPath,
        'fixture-codex-binary',
        [Text.UTF8Encoding]::new($false)
    )
    $codexBinarySha256 = (
        Get-FileHash -LiteralPath $fixtureBinaryPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    $rubricSha256 = (
        Get-FileHash `
            -LiteralPath (Join-Path $fixtureRepoRoot 'evals/rubric.md') `
            -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    $cases = [Collections.Generic.List[object]]::new()
    $runSteps = [Collections.Generic.List[object]]::new()
    $caseIndex = 0
    foreach ($definition in $definitions) {
        foreach ($scenario in $definition.Scenarios) {
            $caseId = [string]$definition.CaseId
            $scenarioId = [string]$scenario.Id
            $scenarioRoot = Join-Path $capsuleRoot "runs/$runId/control/$caseId/$scenarioId"
            $stepLogRoot = Join-Path $fixtureRepoRoot "evals/logs/$runId/control/$caseId/$scenarioId"
            foreach ($directChild in 'user-home', 'workspace', 'state', 'temp') {
                New-Item -ItemType Directory -Path (Join-Path $scenarioRoot $directChild) -Force | Out-Null
            }
            New-Item -ItemType Directory -Path $stepLogRoot -Force | Out-Null

            $scenarioWorkspace = Join-Path $scenarioRoot 'workspace'
            $scenarioUserHome = Join-Path $scenarioRoot 'user-home'
            Copy-AccessibleFixtureFiles `
                -CaseDefinition $definition `
                -ScenarioWorkspace $scenarioWorkspace
            $invocationDefinitions = @(
                Get-FixtureInvocationDefinitions `
                    -CaseDefinition $definition `
                    -Scenario $scenario
            )
            $invocationResults = [Collections.Generic.List[object]]::new()
            $invocationJsonlTexts = [Collections.Generic.List[string]]::new()
            $invocationFinalTexts = [Collections.Generic.List[string]]::new()
            foreach ($invocationDefinition in $invocationDefinitions) {
                $projectRoot = [string]$invocationDefinition.ProjectRoot
                $promptPath = if (@($definition.Invocations).Count -gt 0) {
                    Join-Path $stepLogRoot (
                        "invocations/$([string]$invocationDefinition.Id)/prompt.md"
                    )
                }
                else {
                    Join-Path $stepLogRoot 'prompt.md'
                }
                $invocationFixture = New-InvocationFixture `
                    -StepLogRoot $stepLogRoot `
                    -ScenarioWorkspace $scenarioWorkspace `
                    -ScenarioUserHome $scenarioUserHome `
                    -PermissionMode ([string]$scenario.PermissionMode) `
                    -InvocationId ([string]$invocationDefinition.Id) `
                    -Prompt ([string]$invocationDefinition.Prompt) `
                    -PromptPath $promptPath `
                    -ProjectRoot $projectRoot `
                    -Model $model `
                    -CodexBinary $codexBinary `
                    -CodexBinarySha256 $codexBinarySha256 `
                    -EnvironmentNames $requiredRewrittenEnvironmentNames
                $invocationResults.Add($invocationFixture.Invocation)
                $invocationJsonlTexts.Add([string]$invocationFixture.JsonlText)
                $invocationFinalTexts.Add([string]$invocationFixture.FinalText)
                $runSteps.Add($invocationFixture.Step)
            }

            $failedItems = if ($caseIndex -eq 0) { @(1, 2, 3) } else { @() }
            $caseInputSha256 = Get-FixtureCaseInputSha256 `
                -CaseDefinition $definition `
                -ScenarioWorkspace $scenarioWorkspace
            $initialProfileSha256 = ('e' * 64)
            $resultRecord = [ordered]@{
                caseId = $caseId
                scenarioId = $scenarioId
                permissionMode = [string]$scenario.PermissionMode
                status = 'COMPLETE'
                caseInputSha256 = $caseInputSha256
                rubricSha256 = $rubricSha256
                profileBeforeSha256 = $initialProfileSha256
                rubric = @(
                    1..17 | ForEach-Object {
                        [ordered]@{
                            item = $_
                            score = if ($_ -in $failedItems) { 0 } else { 1 }
                        }
                    }
                )
                failedItems = @($failedItems)
                invocations = @($invocationResults)
            }

            $artifacts = [Collections.Generic.List[object]]::new()
            foreach ($kind in 'jsonl', 'stderr', 'final') {
                $artifactPath = Join-Path $stepLogRoot "$kind.txt"
                $artifactText = switch ($kind) {
                    'jsonl' { @($invocationJsonlTexts) -join "`n" }
                    'final' { @($invocationFinalTexts) -join "`n" }
                    default { '' }
                }
                Set-Content -LiteralPath $artifactPath -Value $artifactText -Encoding UTF8
                $artifacts.Add([ordered]@{
                    kind = $kind
                    path = $artifactPath
                    sha256 = (
                        Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256
                    ).Hash.ToLowerInvariant()
                })
            }
            $resultPath = Join-Path $stepLogRoot 'result.json'
            Write-JsonFile -InputObject $resultRecord -Path $resultPath
            $artifacts.Add([ordered]@{
                kind = 'result'
                path = $resultPath
                sha256 = (
                    Get-FileHash -LiteralPath $resultPath -Algorithm SHA256
                ).Hash.ToLowerInvariant()
            })

            $cases.Add([ordered]@{
                caseId = $caseId
                scenarioId = $scenarioId
                permissionMode = [string]$scenario.PermissionMode
                status = 'COMPLETE'
                failedItems = @($failedItems)
                caseInputSha256 = $caseInputSha256
                rubricSha256 = $rubricSha256
                initialProfileSha256 = $initialProfileSha256
                scenarioRoot = $scenarioRoot
                scenarioUserHome = (Join-Path $scenarioRoot 'user-home')
                scenarioWorkspace = $scenarioWorkspace
                scenarioTemp = (Join-Path $scenarioRoot 'temp')
                codexSqliteHome = (Join-Path $scenarioRoot 'state')
                stepLogRoot = $stepLogRoot
                environmentNames = @($requiredRewrittenEnvironmentNames)
                invocations = @($invocationResults)
                artifacts = @($artifacts)
            })
            $caseIndex++
        }
    }

    $stepEnvironment = [ordered]@{
        TEMP = (Join-Path $testRoot 'step-env/temp')
        TMP = (Join-Path $testRoot 'step-env/temp')
        LOCALAPPDATA = (Join-Path $testRoot 'step-env/local')
        APPDATA = (Join-Path $testRoot 'step-env/roaming')
        USERPROFILE = (Join-Path $testRoot 'step-env/home')
        HOME = (Join-Path $testRoot 'step-env/home')
        CODEX_HOME = (Join-Path $testRoot 'step-env/codex')
        CODEX_SQLITE_HOME = (Join-Path $testRoot 'step-env/state')
    }
    foreach ($path in $stepEnvironment.Values | Sort-Object -Unique) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
    $stepResult = Invoke-MeechoAuditedProcess `
        -FilePath (Join-Path $PSHOME 'pwsh.exe') `
        -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', 'exit 0') `
        -Environment $stepEnvironment `
        -StepLogRoot (Join-Path $fixtureRepoRoot "evals/logs/$runId/control/preflight/steps") `
        -StepName 'complete-run-probe'

    $canaryRefs = [Collections.Generic.List[object]]::new()
    $runSteps.Add([ordered]@{
        name = 'complete-run-probe'
        recordPath = $stepResult.RecordPath
        recordSha256 = (
            Get-FileHash -LiteralPath $stepResult.RecordPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
    })
    foreach ($codexProbe in @(
        [ordered]@{
            Name = 'codex-capabilities'
            Arguments = @('--strict-config', 'exec', '--help')
        }
        [ordered]@{
            Name = 'login'
            Arguments = @('--strict-config', 'login')
        }
        [ordered]@{
            Name = 'login-status'
            Arguments = @('--strict-config', 'login', 'status')
        }
    )) {
        $probeStep = New-StepRecordFixture `
            -Root (Join-Path $fixtureRepoRoot "evals/logs/$runId/control/preflight/steps") `
            -StepName ([string]$codexProbe.Name) `
            -Command $codexBinary `
            -CommandSha256 $codexBinarySha256 `
            -Arguments @($codexProbe.Arguments) `
            -EnvironmentNames $requiredRewrittenEnvironmentNames `
            -StdoutText 'ok'
        $runSteps.Add($probeStep.Step)
    }
    $templateConfigPath = Join-Path $fixtureRepoRoot 'evals/capsule/config.toml'
    $controlConfigPath = Join-Path $capsuleRoot 'control/codex-home/config.toml'
    New-Item -ItemType Directory -Path (Split-Path -Parent $controlConfigPath) -Force | Out-Null
    Copy-Item -LiteralPath $templateConfigPath -Destination $controlConfigPath
    $configSha256 = (
        Get-FileHash -LiteralPath $templateConfigPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    $permissionPreflights = New-PermissionPreflights `
        -ConfigSha256 $configSha256
    foreach ($permissionMode in 'read', 'allow', 'deny') {
        $versionStep = New-StepRecordFixture `
            -Root (Join-Path $fixtureRepoRoot "evals/logs/$runId/control/preflight/$permissionMode") `
            -StepName 'codex-version' `
            -Command $codexBinary `
            -CommandSha256 $codexBinarySha256 `
            -Arguments @('--version') `
            -EnvironmentNames $requiredRewrittenEnvironmentNames `
            -StdoutText 'codex-cli 0.145.0' `
            -StderrText ''
        $runSteps.Add($versionStep.Step)
        $canaryEvidence = New-CanaryEvidence `
            -FixtureRepoRoot $fixtureRepoRoot `
            -RunId $runId `
            -Mode control `
            -PermissionMode $permissionMode `
            -CodexBinary $codexBinary `
            -CodexBinarySha256 $codexBinarySha256 `
            -Environment $stepEnvironment
        $canaryRefs.Add($canaryEvidence.Ref)
        $runSteps.Add($canaryEvidence.Step)
    }

    $manifest = [ordered]@{
        schemaVersion = 1
        kind = 'meecho-eval-run'
        runId = $runId
        mode = 'control'
        status = 'COMPLETE'
        model = $model
        reasoningEffort = 'high'
        codexVersion = '0.145.0'
        codexBinary = $codexBinary
        codexBinarySha256 = $codexBinarySha256
        approvalPolicy = 'never'
        serviceTier = ''
        configSha256 = $configSha256
        rubricSha256 = $rubricSha256
        realProfileBeforeSha256 = ('f' * 64)
        realProfileAfterSha256 = ('f' * 64)
        capsuleRoot = $capsuleRoot
        repoRoot = $fixtureRepoRoot
        environmentNames = @($requiredRewrittenEnvironmentNames)
        permissionPreflights = @($permissionPreflights)
        canaryRefs = @($canaryRefs)
        steps = @($runSteps)
        cases = @($cases)
        failures = @()
    }
    $manifestPath = Join-Path $fixtureRepoRoot "evals/logs/$runId/control/run-manifest.json"
    Write-JsonFile -InputObject $manifest -Path $manifestPath

    $valid = Invoke-Validator -ManifestPath $manifestPath
    Assert-Equal 0 $valid.ExitCode "Complete fixture should validate. $($valid.Stderr) $($valid.Json.Failures -join ', ')"
    Assert-True $valid.Json.Valid 'Complete fixture was rejected.'
    Assert-True $valid.Json.Complete 'A fully scored RED baseline must be reported complete.'

    $combinedProtectionManifest = Copy-JsonObject -InputObject $manifest
    $combinedProtectionManifest.codexVersion = '0.144.9'
    $combinedProtectionManifest.permissionPreflights = @(
        $combinedProtectionManifest.permissionPreflights |
            Select-Object -First 2
    )
    $combinedProtectionManifest.permissionPreflights[0].passed = 'true'

    $promptCase = @(
        $combinedProtectionManifest.cases |
            Where-Object {
                [string]$_.caseId -ceq 'case-09' -and
                [string]$_.scenarioId -ceq 'status-read'
            }
    )[0]
    $promptInvocation = @($promptCase.invocations)[0]
    $promptStepName = 'codex-exec-' + (
        Get-StringSha256 -Value (
            [IO.Path]::GetFullPath([string]$promptInvocation.jsonlPath)
        )
    ).Substring(0, 12)
    $promptRecordPath = Join-Path (
        [string]$promptCase.stepLogRoot
    ) "$promptStepName.record.json"
    $promptPath = Join-Path ([string]$promptCase.stepLogRoot) 'prompt.md'
    $originalPromptRecordBytes = [IO.File]::ReadAllBytes($promptRecordPath)
    $originalPromptBytes = [IO.File]::ReadAllBytes($promptPath)
    $forgedPrompt = '$meecho:meecho 删除全部声音档案。'
    [IO.File]::WriteAllText(
        $promptPath,
        $forgedPrompt,
        [Text.UTF8Encoding]::new($false)
    )
    $forgedPromptRecord = Read-MeechoJson -Path $promptRecordPath
    $forgedPromptRecord.arguments[-1] = (
        '<prompt sha256=' +
        (Get-StringSha256 -Value $forgedPrompt) +
        " length=$($forgedPrompt.Length)>"
    )
    Write-JsonFile -InputObject $forgedPromptRecord -Path $promptRecordPath
    Update-StepReferenceHash `
        -Manifest $combinedProtectionManifest `
        -RecordPath $promptRecordPath

    $caseInputIndex = -1
    for ($index = 0; $index -lt $combinedProtectionManifest.cases.Count; $index++) {
        if ([string]$combinedProtectionManifest.cases[$index].caseId -ceq 'case-01') {
            $caseInputIndex = $index
            break
        }
    }
    Assert-True ($caseInputIndex -ge 0) 'Fixture must contain case-01.'
    $caseInputCase = $combinedProtectionManifest.cases[$caseInputIndex]
    $caseInputResultPath = [string](
        @(
            $caseInputCase.artifacts |
                Where-Object { [string]$_.kind -ceq 'result' }
        )[0].path
    )
    $originalCaseInputResultBytes = [IO.File]::ReadAllBytes(
        $caseInputResultPath
    )
    $forgedCaseInputSha256 = Get-StringSha256 -Value 'forged-case-input'
    $caseInputCase.caseInputSha256 = $forgedCaseInputSha256
    $forgedCaseInputResult = Read-MeechoJson -Path $caseInputResultPath
    $forgedCaseInputResult.caseInputSha256 = $forgedCaseInputSha256
    Write-JsonFile `
        -InputObject $forgedCaseInputResult `
        -Path $caseInputResultPath
    Update-ResultArtifactHash `
        -Manifest $combinedProtectionManifest `
        -CaseIndex $caseInputIndex

    $stagedInputCase = @(
        $combinedProtectionManifest.cases |
            Where-Object {
                [string]$_.caseId -ceq 'case-04' -and
                [string]$_.scenarioId -ceq 'read'
            }
    )[0]
    $stagedInputPath = Join-Path (
        [string]$stagedInputCase.scenarioWorkspace
    ) 'input.md'
    $originalStagedInputBytes = [IO.File]::ReadAllBytes($stagedInputPath)
    [IO.File]::WriteAllText(
        $stagedInputPath,
        'tampered staged input',
        [Text.UTF8Encoding]::new($false)
    )

    $bomPromptCase = @(
        $combinedProtectionManifest.cases |
            Where-Object {
                [string]$_.caseId -ceq 'case-05' -and
                [string]$_.scenarioId -ceq 'read'
            }
    )[0]
    $bomPromptPath = Join-Path ([string]$bomPromptCase.stepLogRoot) 'prompt.md'
    $originalBomPromptBytes = [IO.File]::ReadAllBytes($bomPromptPath)
    $bomAndTrailingNewline = [byte[]](
        @(0xEF, 0xBB, 0xBF) +
        @($originalBomPromptBytes) +
        @(0x0A)
    )
    [IO.File]::WriteAllBytes($bomPromptPath, $bomAndTrailingNewline)
    $originalCanaryBytesByPath = @{}
    $canaryPaths = @($manifest.canaryRefs | ForEach-Object {
        [string]$_.recordPath
    })
    for ($canaryIndex = 0; $canaryIndex -lt 3; $canaryIndex++) {
        $canaryPath = $canaryPaths[$canaryIndex]
        $originalCanaryBytesByPath[$canaryPath] = [IO.File]::ReadAllBytes(
            $canaryPath
        )
        $mutatedCanary = Read-MeechoJson -Path $canaryPath
        switch ($canaryIndex) {
            0 {
                $mutatedCanary.PSObject.Properties.Remove(
                    'realHomeReadDenied'
                )
            }
            1 {
                $mutatedCanary.capsuleForbiddenReadDenied = $false
            }
            2 {
                $mutatedCanary.realHomeMarkerSha256 = 'not-a-sha256'
            }
        }
        Write-JsonFile -InputObject $mutatedCanary -Path $canaryPath
        Update-CanaryReferenceHash `
            -Manifest $combinedProtectionManifest `
            -RecordPath $canaryPath
    }

    $canaryProcessPaths = @(
        $canaryPaths | ForEach-Object {
            $canaryPath = $_
            $canaryRecordName = @(
                (Read-MeechoJson -Path $canaryPath).artifacts |
                    Where-Object {
                        [string]$_ -cmatch
                            '^codex-exec-[a-f0-9]{12}\.record\.json$'
                    }
            )[0]
            Join-Path (
                Split-Path -Parent $canaryPath
            ) ([string]$canaryRecordName)
        }
    )
    $firstCaseProcessPath = [string](
        $manifest.steps |
            Where-Object {
                [string]$_.name -cmatch '^codex-exec-[a-f0-9]{12}$' -and
                [string]$_.recordPath -notmatch '[\\/]preflight[\\/]'
            } |
            Select-Object -First 1
    ).recordPath
    $codexStepRepresentatives = @(
        [ordered]@{
            Label = 'version'
            Path = [string](
                $manifest.steps |
                    Where-Object { [string]$_.name -ceq 'codex-version' } |
                    Select-Object -First 1
            ).recordPath
        }
        [ordered]@{
            Label = 'capability'
            Path = [string](
                $manifest.steps |
                    Where-Object { [string]$_.name -ceq 'codex-capabilities' } |
                    Select-Object -First 1
            ).recordPath
        }
        [ordered]@{
            Label = 'login'
            Path = [string](
                $manifest.steps |
                    Where-Object { [string]$_.name -ceq 'login' } |
                    Select-Object -First 1
            ).recordPath
        }
        [ordered]@{
            Label = 'login-status'
            Path = [string](
                $manifest.steps |
                    Where-Object { [string]$_.name -ceq 'login-status' } |
                    Select-Object -First 1
            ).recordPath
        }
        [ordered]@{ Label = 'canary'; Path = $canaryProcessPaths[0] }
        [ordered]@{ Label = 'case'; Path = $firstCaseProcessPath }
    )
    $originalStepBytesByPath = @{}
    foreach ($representative in $codexStepRepresentatives) {
        $recordPath = [string]$representative.Path
        Assert-True (
            -not [string]::IsNullOrWhiteSpace($recordPath)
        ) "Missing positive $($representative.Label) Codex step fixture."
        $originalStepBytesByPath[$recordPath] = [IO.File]::ReadAllBytes(
            $recordPath
        )
        $missingCommandHash = Read-MeechoJson -Path $recordPath
        $missingCommandHash.PSObject.Properties.Remove('commandSha256')
        Write-JsonFile -InputObject $missingCommandHash -Path $recordPath
        Update-StepReferenceHash `
            -Manifest $combinedProtectionManifest `
            -RecordPath $recordPath
    }

    $fakePwshCanaryPath = $canaryProcessPaths[1]
    $originalStepBytesByPath[$fakePwshCanaryPath] = [IO.File]::ReadAllBytes(
        $fakePwshCanaryPath
    )
    $fakePwshCanary = Read-MeechoJson -Path $fakePwshCanaryPath
    $fakePwshCanary.command = 'pwsh.exe'
    $fakePwshCanary.commandSha256 = (
        Get-FileHash -LiteralPath (Join-Path $PSHOME 'pwsh.exe') -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    Write-JsonFile -InputObject $fakePwshCanary -Path $fakePwshCanaryPath
    Update-StepReferenceHash `
        -Manifest $combinedProtectionManifest `
        -RecordPath $fakePwshCanaryPath
    $combinedProtectionManifestPath = Join-Path $testRoot (
        'combined-complete-protection-negatives.json'
    )
    Write-JsonFile `
        -InputObject $combinedProtectionManifest `
        -Path $combinedProtectionManifestPath
    $combinedProtectionResult = Invoke-Validator `
        -ManifestPath $combinedProtectionManifestPath
    Assert-True (
        $combinedProtectionResult.ExitCode -ne 0
    ) 'Combined COMPLETE protection and source-binding negatives must fail.'
    foreach ($expectedProtectionIssue in @(
        'invocation-prompt-binding',
        'invocation-prompt-file',
        'case-input-binding',
        'staged-input-content',
        'canary-boundary-evidence-realHomeReadDenied',
        'canary-boundary-evidence-capsuleForbiddenReadDenied',
        'canary-boundary-evidence-realHomeMarkerSha256',
        'codex-command-sha256-version',
        'codex-command-sha256-capability',
        'codex-command-sha256-login',
        'codex-command-sha256-canary',
        'codex-command-sha256-case',
        'codex-command-identity',
        'codexVersion',
        'permissionPreflights',
        'permissionPreflight-passed'
    )) {
        Assert-True (
            $combinedProtectionResult.Json.Failures -contains
                $expectedProtectionIssue
        ) "Combined COMPLETE negative did not report $expectedProtectionIssue."
    }
    foreach ($entry in $originalCanaryBytesByPath.GetEnumerator()) {
        [IO.File]::WriteAllBytes([string]$entry.Key, [byte[]]$entry.Value)
    }
    foreach ($entry in $originalStepBytesByPath.GetEnumerator()) {
        [IO.File]::WriteAllBytes([string]$entry.Key, [byte[]]$entry.Value)
    }
    [IO.File]::WriteAllBytes($promptRecordPath, $originalPromptRecordBytes)
    [IO.File]::WriteAllBytes($promptPath, $originalPromptBytes)
    [IO.File]::WriteAllBytes(
        $caseInputResultPath,
        $originalCaseInputResultBytes
    )
    [IO.File]::WriteAllBytes($stagedInputPath, $originalStagedInputBytes)
    [IO.File]::WriteAllBytes($bomPromptPath, $originalBomPromptBytes)

    $spoofedRepoRoot = Copy-JsonObject -InputObject $manifest
    $spoofedRepoRoot.repoRoot = Join-Path $testRoot 'spoofed-repo'
    $spoofedRepoRootPath = Join-Path $testRoot 'spoofed-repo-root.json'
    Write-JsonFile -InputObject $spoofedRepoRoot -Path $spoofedRepoRootPath
    $spoofedRepoRootResult = Invoke-Validator -ManifestPath $spoofedRepoRootPath
    Assert-True (
        $spoofedRepoRootResult.ExitCode -ne 0
    ) 'A COMPLETE manifest must not select an alternate repository root.'
    Assert-True (
        $spoofedRepoRootResult.Json.Failures -contains 'repoRoot'
    ) 'A spoofed repository root was not identified explicitly.'

    $missingEvidence = Copy-JsonObject -InputObject $manifest
    $missingEvidence.PSObject.Properties.Remove('codexVersion')
    $missingEvidence.PSObject.Properties.Remove('codexBinary')
    $missingEvidence.PSObject.Properties.Remove('codexBinarySha256')
    $missingEvidence.PSObject.Properties.Remove('approvalPolicy')
    $missingEvidence.PSObject.Properties.Remove('canaryRefs')
    $missingEvidence.PSObject.Properties.Remove('realProfileBeforeSha256')
    $missingEvidence.PSObject.Properties.Remove('realProfileAfterSha256')
    $missingEvidence.steps = @()
    $missingEvidence.cases[0].PSObject.Properties.Remove('caseInputSha256')
    $missingEvidence.cases[0].PSObject.Properties.Remove('rubricSha256')
    $missingEvidence.cases[0].PSObject.Properties.Remove('initialProfileSha256')
    $missingEvidencePath = Join-Path $testRoot 'missing-complete-evidence.json'
    Write-JsonFile -InputObject $missingEvidence -Path $missingEvidencePath
    $missingEvidenceResult = Invoke-Validator -ManifestPath $missingEvidencePath
    Assert-True ($missingEvidenceResult.ExitCode -ne 0) 'COMPLETE must require binary/version, policy, canaries, real-profile, steps, and case hashes.'
    foreach ($failure in @(
        'codexVersion',
        'codexBinary',
        'codexBinarySha256',
        'approvalPolicy',
        'canaryRefs',
        'realProfileBeforeSha256',
        'realProfileAfterSha256',
        'steps-evidence',
        'caseInputSha256',
        'rubricSha256',
        'initialProfileSha256'
    )) {
        Assert-True ($missingEvidenceResult.Json.Failures -contains $failure) "Missing COMPLETE evidence did not report $failure."
    }

    $firstJsonlArtifact = @(
        $manifest.cases[0].artifacts | Where-Object kind -ceq 'jsonl'
    )[0]
    $originalJsonl = Get-Content -LiteralPath $firstJsonlArtifact.path -Raw -Encoding UTF8
    Set-Content `
        -LiteralPath $firstJsonlArtifact.path `
        -Value '{"type":"turn.started"}' `
        -Encoding UTF8
    $missingTurnCompleted = Copy-JsonObject -InputObject $manifest
    $missingTurnJsonl = @(
        $missingTurnCompleted.cases[0].artifacts | Where-Object kind -ceq 'jsonl'
    )[0]
    $missingTurnJsonl.sha256 = (
        Get-FileHash -LiteralPath $missingTurnJsonl.path -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    $missingTurnCompletedPath = Join-Path $testRoot 'missing-turn-completed.json'
    Write-JsonFile -InputObject $missingTurnCompleted -Path $missingTurnCompletedPath
    $missingTurnResult = Invoke-Validator -ManifestPath $missingTurnCompletedPath
    Assert-True ($missingTurnResult.ExitCode -ne 0) 'Plain or partial JSONL must not satisfy COMPLETE evidence.'
    Assert-True ($missingTurnResult.Json.Failures -contains 'jsonl-turn-completed') 'Missing turn.completed was not identified.'
    [IO.File]::WriteAllText(
        [string]$firstJsonlArtifact.path,
        $originalJsonl,
        [Text.UTF8Encoding]::new($false)
    )

    $renamedScenario = @(
        $manifest.cases | Where-Object {
            [string]$_.scenarioId -cne [string]$_.permissionMode
        }
    )[0]
    Assert-True ($null -ne $renamedScenario) 'Real case registry must include a scenario id independent from permission mode.'

    $combinedLayoutNegative = Copy-JsonObject -InputObject $manifest
    $combinedLayoutNegative.cases[1].scenarioRoot = (
        $combinedLayoutNegative.cases[0].scenarioRoot
    )
    $combinedLayoutNegative.cases[2].scenarioRoot = Join-Path $testRoot (
        "spoof/$runId/control/case-02/outside"
    )
    $combinedLayoutNegative.cases[3].scenarioUserHome = Join-Path (
        $combinedLayoutNegative.cases[3].scenarioRoot
    ) 'nested/user-home'
    $combinedLayoutNegative.cases[4].stepLogRoot = Join-Path $testRoot (
        "spoof-logs/$runId/control/case-03/outside"
    )
    $combinedLayoutNegativePath = Join-Path $testRoot (
        'combined-layout-negatives.json'
    )
    Write-JsonFile `
        -InputObject $combinedLayoutNegative `
        -Path $combinedLayoutNegativePath
    $combinedLayoutResult = Invoke-Validator `
        -ManifestPath $combinedLayoutNegativePath
    foreach ($layoutIssue in @(
        'duplicate-mutable-path',
        'scenarioRoot-layout',
        'scenarioUserHome-layout',
        'stepLogRoot-layout'
    )) {
        Assert-True (
            $combinedLayoutResult.ExitCode -ne 0 -and
            $combinedLayoutResult.Json.Failures -contains $layoutIssue
        ) "Combined layout negative did not report $layoutIssue."
    }

    $extraEnvironment = Copy-JsonObject -InputObject $manifest
    $extraEnvironment.environmentNames = @($requiredRewrittenEnvironmentNames) + @('MEECHO_DEBUG')
    $extraEnvironment.cases[0].environmentNames = @($requiredRewrittenEnvironmentNames) + @('MEECHO_DEBUG')
    $extraEnvironmentPath = Join-Path $testRoot 'extra-environment.json'
    Write-JsonFile -InputObject $extraEnvironment -Path $extraEnvironmentPath
    Assert-True ((Invoke-Validator -ManifestPath $extraEnvironmentPath).ExitCode -ne 0) 'Validator must reject every environment name outside the plan allowlist.'

    $missingRewrite = Copy-JsonObject -InputObject $manifest
    $missingRewrite.environmentNames = @($requiredRewrittenEnvironmentNames | Where-Object { $_ -cne 'HOME' })
    $missingRewrite.cases[0].environmentNames = @($requiredRewrittenEnvironmentNames | Where-Object { $_ -cne 'HOME' })
    $missingRewritePath = Join-Path $testRoot 'missing-rewrite.json'
    Write-JsonFile -InputObject $missingRewrite -Path $missingRewritePath
    Assert-True ((Invoke-Validator -ManifestPath $missingRewritePath).ExitCode -ne 0) 'Validator must require every rewritten isolation environment name.'

    $outsideArtifact = Join-Path $testRoot 'outside-artifact.txt'
    Set-Content -LiteralPath $outsideArtifact -Value 'outside' -Encoding UTF8
    $outsideArtifactManifest = Copy-JsonObject -InputObject $manifest
    $outsideArtifactManifest.cases[0].artifacts[0].path = $outsideArtifact
    $outsideArtifactManifest.cases[0].artifacts[0].sha256 = (
        Get-FileHash -LiteralPath $outsideArtifact -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    $outsideArtifactManifestPath = Join-Path $testRoot 'outside-artifact.json'
    Write-JsonFile -InputObject $outsideArtifactManifest -Path $outsideArtifactManifestPath
    Assert-True ((Invoke-Validator -ManifestPath $outsideArtifactManifestPath).ExitCode -ne 0) 'Every case artifact must remain inside its own StepLogRoot.'

    $junctionTarget = Join-Path $testRoot 'junction-target'
    New-Item -ItemType Directory -Path $junctionTarget | Out-Null
    $junctionArtifact = Join-Path $junctionTarget 'artifact.txt'
    Set-Content -LiteralPath $junctionArtifact -Value 'through-junction' -Encoding UTF8
    $firstStepRoot = [string]$manifest.cases[0].stepLogRoot
    $junctionPath = Join-Path $firstStepRoot 'artifact-junction'
    New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget | Out-Null
    $reparseManifest = Copy-JsonObject -InputObject $manifest
    $reparseManifest.cases[0].artifacts[0].path = Join-Path $junctionPath 'artifact.txt'
    $reparseManifest.cases[0].artifacts[0].sha256 = (
        Get-FileHash -LiteralPath $junctionArtifact -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    $reparseManifestPath = Join-Path $testRoot 'reparse-artifact.json'
    Write-JsonFile -InputObject $reparseManifest -Path $reparseManifestPath
    Assert-True ((Invoke-Validator -ManifestPath $reparseManifestPath).ExitCode -ne 0) 'Reparse points in any manifest reference must fail.'
    Remove-Item -LiteralPath $junctionPath -Force
    $junctionPath = $null

    $firstResultPath = [string](
        @($manifest.cases[0].artifacts | Where-Object kind -ceq 'result')[0].path
    )
    $originalResult = Read-MeechoJson -Path $firstResultPath

    $combinedRubricNegative = Copy-JsonObject -InputObject $originalResult
    $combinedRubricNegative.rubric[0].score = 'needs-human-review'
    $combinedRubricNegative.rubric[2].score = 1
    $combinedRubricNegative.rubric[16].item = 16
    $combinedRubricNegative.failedItems = @(1, 2)
    Write-JsonFile `
        -InputObject $combinedRubricNegative `
        -Path $firstResultPath
    $combinedRubricManifest = Copy-JsonObject -InputObject $manifest
    $combinedRubricManifest.cases[0].failedItems = @(1, 2)
    Update-ResultArtifactHash `
        -Manifest $combinedRubricManifest `
        -CaseIndex 0
    $combinedRubricManifestPath = Join-Path $testRoot (
        'combined-rubric-negatives.json'
    )
    Write-JsonFile `
        -InputObject $combinedRubricManifest `
        -Path $combinedRubricManifestPath
    $combinedRubricResult = Invoke-Validator `
        -ManifestPath $combinedRubricManifestPath
    foreach ($rubricIssue in @(
        'rubric-score',
        'rubric-items',
        'failedItems',
        'control-red-failure-floor'
    )) {
        Assert-True (
            $combinedRubricResult.ExitCode -ne 0 -and
            $combinedRubricResult.Json.Failures -contains $rubricIssue
        ) "Combined rubric negative did not report $rubricIssue."
    }

    Write-JsonFile -InputObject $originalResult -Path $firstResultPath
    Update-ResultArtifactHash -Manifest $manifest -CaseIndex 0
    Write-JsonFile -InputObject $manifest -Path $manifestPath

    $treatmentManifest = Copy-JsonObject -InputObject $manifest
    $treatmentManifest.mode = 'treatment'
    $treatmentCases = [Collections.Generic.List[object]]::new()
    $treatmentSteps = [Collections.Generic.List[object]]::new()
    foreach ($controlCase in $manifest.cases) {
        $treatmentCase = Copy-JsonObject -InputObject $controlCase
        $caseId = [string]$controlCase.caseId
        $scenarioId = [string]$controlCase.scenarioId
        $treatmentScenarioRoot = Join-Path $capsuleRoot (
            "runs/$runId/treatment/$caseId/$scenarioId"
        )
        foreach ($directChild in 'user-home', 'workspace', 'state', 'temp') {
            New-Item `
                -ItemType Directory `
                -Path (Join-Path $treatmentScenarioRoot $directChild) `
                -Force |
                Out-Null
        }
        $caseDefinition = $definitionByCaseId[$caseId]
        $scenarioDefinition = @(
            $caseDefinition.Scenarios |
                Where-Object { [string]$_.Id -ceq $scenarioId }
        )[0]
        Copy-AccessibleFixtureFiles `
            -CaseDefinition $caseDefinition `
            -ScenarioWorkspace (Join-Path $treatmentScenarioRoot 'workspace')
        $expectedInvocationDefinitions = @(
            Get-FixtureInvocationDefinitions `
                -CaseDefinition $caseDefinition `
                -Scenario $scenarioDefinition
        )
        $treatmentStepLogRoot = Join-Path $fixtureRepoRoot (
            "evals/logs/$runId/treatment/$caseId/$scenarioId"
        )
        New-Item -ItemType Directory -Path $treatmentStepLogRoot -Force | Out-Null
        $treatmentArtifacts = [Collections.Generic.List[object]]::new()
        foreach ($controlArtifact in $controlCase.artifacts) {
            $destination = Join-Path $treatmentStepLogRoot (
                Split-Path -Leaf ([string]$controlArtifact.path)
            )
            Copy-Item -LiteralPath $controlArtifact.path -Destination $destination
            $treatmentArtifacts.Add([ordered]@{
                kind = [string]$controlArtifact.kind
                path = $destination
                sha256 = (
                    Get-FileHash -LiteralPath $destination -Algorithm SHA256
                ).Hash.ToLowerInvariant()
            })
        }
        $treatmentCase.scenarioRoot = $treatmentScenarioRoot
        $treatmentCase.scenarioUserHome = Join-Path $treatmentScenarioRoot 'user-home'
        $treatmentCase.scenarioWorkspace = Join-Path $treatmentScenarioRoot 'workspace'
        $treatmentCase.codexSqliteHome = Join-Path $treatmentScenarioRoot 'state'
        $treatmentCase.scenarioTemp = Join-Path $treatmentScenarioRoot 'temp'
        $treatmentCase.stepLogRoot = $treatmentStepLogRoot
        $treatmentInvocations = [Collections.Generic.List[object]]::new()
        foreach ($controlInvocation in @($controlCase.invocations)) {
            $expectedInvocation = @(
                $expectedInvocationDefinitions |
                    Where-Object {
                        [string]$_.Id -ceq [string]$controlInvocation.id
                    }
            )[0]
            $relativeProjectRoot = [IO.Path]::GetRelativePath(
                [string]$controlCase.scenarioWorkspace,
                [string]$controlInvocation.workingDirectory
            )
            if ($relativeProjectRoot -ceq '.') {
                $relativeProjectRoot = ''
            }
            $treatmentPromptPath = if (@($caseDefinition.Invocations).Count -gt 0) {
                Join-Path $treatmentStepLogRoot (
                    "invocations/$([string]$controlInvocation.id)/prompt.md"
                )
            }
            else {
                Join-Path $treatmentStepLogRoot 'prompt.md'
            }
            $treatmentInvocationFixture = New-InvocationFixture `
                -StepLogRoot $treatmentStepLogRoot `
                -ScenarioWorkspace ([string]$treatmentCase.scenarioWorkspace) `
                -ScenarioUserHome ([string]$treatmentCase.scenarioUserHome) `
                -PermissionMode ([string]$treatmentCase.permissionMode) `
                -InvocationId ([string]$controlInvocation.id) `
                -Prompt ([string]$expectedInvocation.Prompt) `
                -PromptPath $treatmentPromptPath `
                -ProjectRoot $relativeProjectRoot `
                -Model $model `
                -CodexBinary $codexBinary `
                -CodexBinarySha256 $codexBinarySha256 `
                -EnvironmentNames $requiredRewrittenEnvironmentNames
            $treatmentInvocations.Add($treatmentInvocationFixture.Invocation)
            $treatmentSteps.Add($treatmentInvocationFixture.Step)
        }
        $treatmentCase.invocations = @($treatmentInvocations)
        $treatmentResultArtifact = @(
            $treatmentArtifacts | Where-Object kind -ceq 'result'
        )[0]
        $treatmentResult = Read-MeechoJson -Path ([string]$treatmentResultArtifact.path)
        $treatmentResult.invocations = @($treatmentInvocations)
        Write-JsonFile `
            -InputObject $treatmentResult `
            -Path ([string]$treatmentResultArtifact.path)
        $treatmentResultArtifact.sha256 = (
            Get-FileHash `
                -LiteralPath ([string]$treatmentResultArtifact.path) `
                -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        $treatmentCase.artifacts = @($treatmentArtifacts)
        $treatmentCases.Add($treatmentCase)
    }
    $treatmentManifest.cases = @($treatmentCases)

    $treatmentStepResult = Invoke-MeechoAuditedProcess `
        -FilePath (Join-Path $PSHOME 'pwsh.exe') `
        -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', 'exit 0') `
        -Environment $stepEnvironment `
        -StepLogRoot (Join-Path $fixtureRepoRoot "evals/logs/$runId/treatment/preflight/steps") `
        -StepName 'complete-run-probe'
    $treatmentSteps.Add(
        [ordered]@{
            name = 'complete-run-probe'
            recordPath = $treatmentStepResult.RecordPath
            recordSha256 = (
                Get-FileHash -LiteralPath $treatmentStepResult.RecordPath -Algorithm SHA256
            ).Hash.ToLowerInvariant()
        }
    )
    $treatmentCanaryRefs = [Collections.Generic.List[object]]::new()
    $treatmentConfigPath = Join-Path $capsuleRoot 'treatment/codex-home/config.toml'
    New-Item -ItemType Directory -Path (Split-Path -Parent $treatmentConfigPath) -Force | Out-Null
    Copy-Item -LiteralPath $templateConfigPath -Destination $treatmentConfigPath
    foreach ($permissionMode in 'read', 'allow', 'deny') {
        $versionStep = New-StepRecordFixture `
            -Root (Join-Path $fixtureRepoRoot "evals/logs/$runId/treatment/preflight/$permissionMode") `
            -StepName 'codex-version' `
            -Command $codexBinary `
            -CommandSha256 $codexBinarySha256 `
            -Arguments @('--version') `
            -EnvironmentNames $requiredRewrittenEnvironmentNames `
            -StdoutText 'codex-cli 0.145.0' `
            -StderrText ''
        $treatmentSteps.Add($versionStep.Step)
        $canaryEvidence = New-CanaryEvidence `
            -FixtureRepoRoot $fixtureRepoRoot `
            -RunId $runId `
            -Mode treatment `
            -PermissionMode $permissionMode `
            -CodexBinary $codexBinary `
            -CodexBinarySha256 $codexBinarySha256 `
            -Environment $stepEnvironment
        $treatmentCanaryRefs.Add($canaryEvidence.Ref)
        $treatmentSteps.Add($canaryEvidence.Step)
    }
    $treatmentManifest.canaryRefs = @($treatmentCanaryRefs)
    $treatmentManifest.steps = @($treatmentSteps)
    $treatmentManifestPath = Join-Path $fixtureRepoRoot (
        "evals/logs/$runId/treatment/run-manifest.json"
    )
    Write-JsonFile -InputObject $treatmentManifest -Path $treatmentManifestPath
    $treatmentValidation = Invoke-Validator -ManifestPath $treatmentManifestPath
    Assert-Equal 0 $treatmentValidation.ExitCode "Treatment COMPLETE run fixture must validate: $($treatmentValidation.Json.Failures -join ', ')."

    $comparisonRecords = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $manifest.cases.Count; $index++) {
        $controlCase = $manifest.cases[$index]
        $treatmentCase = $treatmentManifest.cases[$index]
        $comparisonRecords.Add([ordered]@{
            caseId = [string]$controlCase.caseId
            scenarioId = [string]$controlCase.scenarioId
            permissionMode = [string]$controlCase.permissionMode
            control = New-ComparisonSide `
                -RunManifest $manifest `
                -Case $controlCase `
                -ManifestPath $manifestPath
            treatment = New-ComparisonSide `
                -RunManifest $treatmentManifest `
                -Case $treatmentCase `
                -ManifestPath $treatmentManifestPath
        })
    }
    $comparisonManifest = [ordered]@{
        schemaVersion = 1
        kind = 'meecho-eval-comparison'
        pairRunId = $runId
        status = 'COMPLETE'
        controlRunId = $runId
        treatmentRunId = $runId
        model = $model
        reasoningEffort = 'high'
        lockPath = $pairLockPath
        comparisons = @($comparisonRecords)
        failures = @()
    }
    $comparisonManifestPath = Join-Path $fixtureRepoRoot (
        "evals/logs/$runId/comparison-manifest.json"
    )
    Write-JsonFile -InputObject $comparisonManifest -Path $comparisonManifestPath
    $comparisonValidation = Invoke-Validator -ManifestPath $comparisonManifestPath
    Assert-Equal 0 $comparisonValidation.ExitCode "Full bound comparison fixture must validate: $($comparisonValidation.Json.Failures -join ', ')."
    Assert-True $comparisonValidation.Json.Complete 'Full side-run evidence did not produce a complete comparison.'

    $mismatchedCapsuleRoot = Join-Path $testRoot 'mismatched-capsule'
    New-Item -ItemType Directory -Path $mismatchedCapsuleRoot -Force |
        Out-Null
    $mismatchedCapsuleSide = Copy-JsonObject -InputObject $treatmentManifest
    $mismatchedCapsuleSide.capsuleRoot = $mismatchedCapsuleRoot
    $mismatchedCapsuleSidePath = Join-Path (
        Split-Path -Parent $treatmentManifestPath
    ) 'run-manifest-mismatched-capsule.json'
    Write-JsonFile `
        -InputObject $mismatchedCapsuleSide `
        -Path $mismatchedCapsuleSidePath
    $mismatchedCapsuleSideSha256 = (
        Get-FileHash `
            -LiteralPath $mismatchedCapsuleSidePath `
            -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    $combinedComparisonNegative = Copy-JsonObject `
        -InputObject $comparisonManifest
    $combinedComparisonNegative.model = 'different-model'
    $combinedComparisonNegative.reasoningEffort = 'medium'
    $combinedComparisonNegative.lockPath = Join-Path $capsuleRoot 'wrong.lock'
    foreach ($comparison in $combinedComparisonNegative.comparisons) {
        $comparison.treatment.manifestPath = $mismatchedCapsuleSidePath
        $comparison.treatment.manifestSha256 = $mismatchedCapsuleSideSha256
    }
    $pairMarkerBytes = [IO.File]::ReadAllBytes($pairLockPath)
    $allocationMarkerBytes = [IO.File]::ReadAllBytes($allocationLockPath)
    [IO.File]::WriteAllText(
        $pairLockPath,
        "$runId`n",
        [Text.UTF8Encoding]::new($false)
    )
    Remove-Item -LiteralPath $allocationLockPath -Force
    $combinedComparisonNegativePath = Join-Path $testRoot (
        'combined-comparison-negatives.json'
    )
    Write-JsonFile `
        -InputObject $combinedComparisonNegative `
        -Path $combinedComparisonNegativePath
    $combinedComparisonNegativeResult = Invoke-Validator `
        -ManifestPath $combinedComparisonNegativePath
    foreach ($expectedComparisonIssue in @(
        'comparison-model',
        'comparison-reasoningEffort',
        'pair-lockPath',
        'pair-marker-evidence-pair',
        'pair-marker-evidence-allocation',
        'side-capsuleRoot'
    )) {
        Assert-True (
            $combinedComparisonNegativeResult.ExitCode -ne 0 -and
            $combinedComparisonNegativeResult.Json.Failures -contains
                $expectedComparisonIssue
        ) "Combined comparison negative did not report $expectedComparisonIssue."
    }
    [IO.File]::WriteAllBytes($pairLockPath, $pairMarkerBytes)
    [IO.File]::WriteAllBytes($allocationLockPath, $allocationMarkerBytes)

    $pairMarkerJunctionTarget = Join-Path $testRoot (
        'pair-marker-junction-target'
    )
    $allocationMarkerJunctionTarget = Join-Path $testRoot (
        'allocation-marker-junction-target'
    )
    New-Item -ItemType Directory -Path $pairMarkerJunctionTarget -Force |
        Out-Null
    New-Item `
        -ItemType Directory `
        -Path $allocationMarkerJunctionTarget `
        -Force |
        Out-Null
    Remove-Item -LiteralPath $pairLockPath -Force
    Remove-Item -LiteralPath $allocationLockPath -Force
    New-Item `
        -ItemType Junction `
        -Path $pairLockPath `
        -Target $pairMarkerJunctionTarget |
        Out-Null
    New-Item `
        -ItemType Junction `
        -Path $allocationLockPath `
        -Target $allocationMarkerJunctionTarget |
        Out-Null
    $reparseMarkerResult = Invoke-Validator `
        -ManifestPath $comparisonManifestPath
    foreach ($expectedReparseIssue in @(
        'pair-marker-evidence-pair',
        'pair-marker-evidence-allocation'
    )) {
        Assert-True (
            $reparseMarkerResult.ExitCode -ne 0 -and
            $reparseMarkerResult.Json.Failures -contains $expectedReparseIssue
        ) "Reparse marker negative did not report $expectedReparseIssue."
    }
    Remove-Item -LiteralPath $pairLockPath -Force
    Remove-Item -LiteralPath $allocationLockPath -Force
    [IO.File]::WriteAllBytes($pairLockPath, $pairMarkerBytes)
    [IO.File]::WriteAllBytes($allocationLockPath, $allocationMarkerBytes)

    $fakeComplete = Copy-JsonObject -InputObject $comparisonManifest
    $fakeComplete.comparisons = @($fakeComplete.comparisons[0])
    foreach ($sideName in 'control', 'treatment') {
        $fakeComplete.comparisons[0].$sideName.PSObject.Properties.Remove('mode')
        $fakeComplete.comparisons[0].$sideName.PSObject.Properties.Remove('runId')
        $fakeComplete.comparisons[0].$sideName.PSObject.Properties.Remove('manifestPath')
        $fakeComplete.comparisons[0].$sideName.PSObject.Properties.Remove('manifestSha256')
    }
    $fakeCompletePath = Join-Path $testRoot 'fake-complete-comparison.json'
    Write-JsonFile -InputObject $fakeComplete -Path $fakeCompletePath
    $fakeCompleteResult = Invoke-Validator -ManifestPath $fakeCompletePath
    Assert-True ($fakeCompleteResult.ExitCode -ne 0) 'A one-row comparison without side run manifests must never be COMPLETE.'
    Assert-False $fakeCompleteResult.Json.Complete 'Fake comparison was reported complete.'
    Assert-True (
        $fakeCompleteResult.Json.Failures -contains 'side-run-identity' -or
        $fakeCompleteResult.Json.Failures -contains 'side-run-manifest-reference'
    ) 'Fake comparison did not report missing side-run binding.'

    $terminalRunId = '{0}-{1}' -f (
        [DateTimeOffset]::UtcNow.AddMilliseconds(1).ToString('yyyyMMddTHHmmssfffZ')
    ), ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $createdRunLogRoots.Add(
        (Join-Path $fixtureRepoRoot "evals/logs/$terminalRunId")
    )
    $terminalPairRunRoot = Join-Path $capsuleRoot "runs/$terminalRunId"
    New-Item -ItemType Directory -Path $terminalPairRunRoot -Force | Out-Null
    $terminalPairLockPath = Join-Path $terminalPairRunRoot '.pair.lock'
    $terminalAllocationLockPath = Join-Path $locksRoot "$terminalRunId.run.lock"
    foreach ($markerPath in $terminalPairLockPath, $terminalAllocationLockPath) {
        [IO.File]::WriteAllText(
            $markerPath,
            $terminalRunId,
            [Text.UTF8Encoding]::new($false)
        )
    }
    foreach ($status in 'AUTH_REQUIRED', 'BLOCKED_NOT_RUN') {
        $terminalFailure = if ($status -ceq 'AUTH_REQUIRED') {
            'AUTH_REQUIRED'
        }
        else {
            'CAPSULE_PREFLIGHT_BLOCKED'
        }
        $terminalStepName = if ($status -ceq 'AUTH_REQUIRED') {
            'terminal-auth-required'
        }
        else {
            'terminal-blocked'
        }
        $terminalStep = Invoke-MeechoAuditedProcess `
            -FilePath (Join-Path $PSHOME 'pwsh.exe') `
            -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', 'exit 0') `
            -Environment $stepEnvironment `
            -StepLogRoot (Join-Path $fixtureRepoRoot "evals/logs/$terminalRunId/control/preflight/terminal") `
            -StepName $terminalStepName
        $terminalPath = Join-Path $testRoot "$status.json"
        $controlTerminalManifest = [ordered]@{
            schemaVersion = 1
            kind = 'meecho-eval-run'
            runId = $terminalRunId
            mode = 'control'
            status = $status
            model = 'gpt-test'
            reasoningEffort = 'high'
            configSha256 = ('a' * 64)
            capsuleRoot = $capsuleRoot
            repoRoot = $fixtureRepoRoot
            environmentNames = @($requiredRewrittenEnvironmentNames)
            steps = @(
                [ordered]@{
                    name = $terminalStepName
                    recordPath = $terminalStep.RecordPath
                    recordSha256 = (
                        Get-FileHash `
                            -LiteralPath $terminalStep.RecordPath `
                            -Algorithm SHA256
                    ).Hash.ToLowerInvariant()
                }
            )
            cases = @()
            failures = @($terminalFailure)
        }
        Write-JsonFile `
            -InputObject $controlTerminalManifest `
            -Path $terminalPath
        $terminal = Invoke-Validator -ManifestPath $terminalPath
        Assert-Equal 0 $terminal.ExitCode "$status is a valid, auditable non-complete terminal manifest."
        Assert-False $terminal.Json.Complete "$status must never be reported as a complete run."

        $terminalWithoutSteps = Read-MeechoJson -Path $terminalPath
        $terminalWithoutSteps.steps = @()
        $terminalWithoutSteps.failures = if ($status -ceq 'AUTH_REQUIRED') {
            @('AUTH_REQUIRED', 'REAL_PROFILE_CHANGED')
        }
        else {
            @('AUTH_REQUIRED')
        }
        $terminalWithoutStepsPath = Join-Path $testRoot "$status-without-steps.json"
        Write-JsonFile -InputObject $terminalWithoutSteps -Path $terminalWithoutStepsPath
        $terminalWithoutStepsResult = Invoke-Validator `
            -ManifestPath $terminalWithoutStepsPath
        Assert-True (
            $terminalWithoutStepsResult.ExitCode -ne 0
        ) "$status without a referenced step record must be invalid."
        Assert-True (
            $terminalWithoutStepsResult.Json.Failures -contains 'steps-evidence' -or
            $terminalWithoutStepsResult.Json.Failures -contains 'run-without-step-evidence'
        ) "$status without step evidence did not report the audit gap."
        Assert-True (
            $terminalWithoutStepsResult.Json.Failures -contains
                'terminal-run-failure-classification'
        ) "$status accepted an invalid terminal failure classification."

        $controlTerminalManifestPath = Join-Path $fixtureRepoRoot (
            "evals/logs/$terminalRunId/control/run-manifest-$status.json"
        )
        Write-JsonFile `
            -InputObject $controlTerminalManifest `
            -Path $controlTerminalManifestPath

        $treatmentTerminalStep = Invoke-MeechoAuditedProcess `
            -FilePath (Join-Path $PSHOME 'pwsh.exe') `
            -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', 'exit 0') `
            -Environment $stepEnvironment `
            -StepLogRoot (Join-Path $fixtureRepoRoot "evals/logs/$terminalRunId/treatment/preflight/terminal") `
            -StepName $terminalStepName
        $treatmentTerminalManifest = Copy-JsonObject `
            -InputObject $controlTerminalManifest
        $treatmentTerminalManifest.mode = 'treatment'
        $treatmentTerminalManifest.steps = @(
            [ordered]@{
                name = $terminalStepName
                recordPath = $treatmentTerminalStep.RecordPath
                recordSha256 = (
                    Get-FileHash `
                        -LiteralPath $treatmentTerminalStep.RecordPath `
                        -Algorithm SHA256
                ).Hash.ToLowerInvariant()
            }
        )
        $treatmentTerminalManifestPath = Join-Path $fixtureRepoRoot (
            "evals/logs/$terminalRunId/treatment/run-manifest-$status.json"
        )
        Write-JsonFile `
            -InputObject $treatmentTerminalManifest `
            -Path $treatmentTerminalManifestPath

        $terminalComparison = [ordered]@{
            schemaVersion = 1
            kind = 'meecho-eval-comparison'
            pairRunId = $terminalRunId
            status = $status
            controlRunId = $terminalRunId
            treatmentRunId = $terminalRunId
            model = 'gpt-test'
            reasoningEffort = 'high'
            lockPath = $terminalPairLockPath
            sideRuns = @(
                [ordered]@{
                    mode = 'control'
                    runId = $terminalRunId
                    status = $status
                    manifestPath = $controlTerminalManifestPath
                    manifestSha256 = (
                        Get-FileHash `
                            -LiteralPath $controlTerminalManifestPath `
                            -Algorithm SHA256
                    ).Hash.ToLowerInvariant()
                }
                [ordered]@{
                    mode = 'treatment'
                    runId = $terminalRunId
                    status = $status
                    manifestPath = $treatmentTerminalManifestPath
                    manifestSha256 = (
                        Get-FileHash `
                            -LiteralPath $treatmentTerminalManifestPath `
                            -Algorithm SHA256
                    ).Hash.ToLowerInvariant()
                }
            )
            comparisons = @()
            failures = @($terminalFailure)
        }
        $terminalComparisonPath = Join-Path $fixtureRepoRoot (
            "evals/logs/$terminalRunId/comparison-$status.json"
        )
        Write-JsonFile `
            -InputObject $terminalComparison `
            -Path $terminalComparisonPath
        $terminalComparisonResult = Invoke-Validator `
            -ManifestPath $terminalComparisonPath
        Assert-Equal 0 $terminalComparisonResult.ExitCode "$status comparison with two audited sideRuns must validate."
        Assert-False $terminalComparisonResult.Json.Complete "$status comparison must remain non-complete."

        if ($status -ceq 'AUTH_REQUIRED') {
            $blockedTreatmentManifest = Copy-JsonObject `
                -InputObject $treatmentTerminalManifest
            $blockedTreatmentManifest.status = 'BLOCKED_NOT_RUN'
            $blockedTreatmentManifest.failures = @(
                'CAPSULE_PREFLIGHT_BLOCKED'
            )
            $blockedTreatmentManifestPath = Join-Path $fixtureRepoRoot (
                "evals/logs/$terminalRunId/treatment/" +
                'run-manifest-BLOCKED-priority.json'
            )
            Write-JsonFile `
                -InputObject $blockedTreatmentManifest `
                -Path $blockedTreatmentManifestPath
            $terminalPriorityMismatch = Copy-JsonObject `
                -InputObject $terminalComparison
            $terminalPriorityMismatch.sideRuns[1].status = 'BLOCKED_NOT_RUN'
            $terminalPriorityMismatch.sideRuns[1].manifestPath = (
                $blockedTreatmentManifestPath
            )
            $terminalPriorityMismatch.sideRuns[1].manifestSha256 = (
                Get-FileHash `
                    -LiteralPath $blockedTreatmentManifestPath `
                    -Algorithm SHA256
            ).Hash.ToLowerInvariant()
            $terminalPriorityMismatchPath = Join-Path $testRoot (
                'AUTH_REQUIRED-comparison-priority-mismatch.json'
            )
            Write-JsonFile `
                -InputObject $terminalPriorityMismatch `
                -Path $terminalPriorityMismatchPath
            $terminalPriorityMismatchResult = Invoke-Validator `
                -ManifestPath $terminalPriorityMismatchPath
            Assert-True (
                $terminalPriorityMismatchResult.ExitCode -ne 0 -and
                $terminalPriorityMismatchResult.Json.Failures -contains
                    'terminal-comparison-status-reduction'
            ) 'AUTH_REQUIRED must not mask a BLOCKED_NOT_RUN side.'
        }
        else {
            $terminalComparisonWithoutSides = Copy-JsonObject `
                -InputObject $terminalComparison
            $terminalComparisonWithoutSides.sideRuns = @()
            $terminalComparisonWithoutSidesPath = Join-Path $testRoot (
                "$status-comparison-without-side-runs.json"
            )
            Write-JsonFile `
                -InputObject $terminalComparisonWithoutSides `
                -Path $terminalComparisonWithoutSidesPath
            $terminalComparisonWithoutSidesResult = Invoke-Validator `
                -ManifestPath $terminalComparisonWithoutSidesPath
            Assert-True (
                $terminalComparisonWithoutSidesResult.ExitCode -ne 0
            ) "$status comparison without sideRuns must be invalid."
            Assert-True (
                $terminalComparisonWithoutSidesResult.Json.Failures -contains
                    'terminal-sideRuns'
            ) "$status comparison without sideRuns did not report the missing evidence."
        }
    }
}
finally {
    if ($junctionPath -and (Test-Path -LiteralPath $junctionPath)) {
        Remove-Item -LiteralPath $junctionPath -Force
    }
    $logsBoundary = [IO.Path]::GetFullPath(
        (Join-Path $repoRoot 'evals/logs')
    ).TrimEnd('\', '/')
    foreach ($createdRunLogRoot in $createdRunLogRoots) {
        $fullCreatedRunLogRoot = [IO.Path]::GetFullPath(
            $createdRunLogRoot
        ).TrimEnd('\', '/')
        if (-not $fullCreatedRunLogRoot.StartsWith(
            $logsBoundary + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            throw "Refusing to clean a log root outside evals/logs: $fullCreatedRunLogRoot"
        }
        if (Test-Path -LiteralPath $fullCreatedRunLogRoot) {
            Remove-Item -LiteralPath $fullCreatedRunLogRoot -Recurse -Force
        }
    }
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Output 'PASS Test-CompleteRunValidation'
