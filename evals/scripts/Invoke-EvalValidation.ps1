[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ManifestPath,

    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'EvalAudit.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CaseStaging.psm1')

if ($null -eq (
    Get-Variable `
        -Name MeechoExpectedScenarioMatrixCache `
        -Scope Script `
        -ErrorAction SilentlyContinue
)) {
    $script:MeechoExpectedScenarioMatrixCache = @{}
}

function Get-PropertyValue {
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $InputObject,

        [Parameter(Mandatory)]
        [string] $Name,

        [AllowNull()]
        [object] $DefaultValue = $null
    )

    if ($null -eq $InputObject) {
        return $DefaultValue
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $DefaultValue
    }
    return $property.Value
}

function Add-ValidationIssue {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]] $Issues,

        [Parameter(Mandatory)]
        [string] $Issue
    )

    if (-not $Issues.Contains($Issue)) {
        $Issues.Add($Issue)
    }
}

function Test-Sha256 {
    param(
        [AllowEmptyString()]
        [string] $Value
    )

    return $Value -cmatch '^[a-f0-9]{64}$'
}

function Get-NormalizedStringSet {
    param(
        [AllowEmptyCollection()]
        [object[]] $Values
    )

    return @(
        @($Values) |
            ForEach-Object { [string] $_ } |
            Sort-Object -Unique
    )
}

function Test-StringSetEqual {
    param(
        [AllowEmptyCollection()]
        [object[]] $Left,

        [AllowEmptyCollection()]
        [object[]] $Right
    )

    $leftJson = Get-NormalizedStringSet -Values $Left | ConvertTo-Json -Compress
    $rightJson = Get-NormalizedStringSet -Values $Right | ConvertTo-Json -Compress
    return $leftJson -ceq $rightJson
}

function Test-ComparableValueEqual {
    param(
        [AllowNull()]
        [object] $Left,

        [AllowNull()]
        [object] $Right,

        [Parameter(Mandatory)]
        [string] $Field
    )

    if ($Field -eq 'environmentNames') {
        return Test-StringSetEqual -Left @($Left) -Right @($Right)
    }
    if ($null -eq $Left -or $null -eq $Right) {
        return $null -eq $Left -and $null -eq $Right
    }
    return [string] $Left -ceq [string] $Right
}

function Test-IntegerValue {
    param(
        [AllowNull()]
        [object] $Value
    )

    return $Value -is [byte] -or
        $Value -is [sbyte] -or
        $Value -is [int16] -or
        $Value -is [uint16] -or
        $Value -is [int32] -or
        $Value -is [uint32] -or
        $Value -is [int64] -or
        $Value -is [uint64]
}

function Test-StrictBoolean {
    param(
        [AllowNull()]
        [object] $Value,

        [Parameter(Mandatory)]
        [bool] $Expected
    )

    return $Value -is [bool] -and [bool]$Value -eq $Expected
}

function Get-StringSha256 {
    param(
        [AllowEmptyString()]
        [string] $Value
    )

    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Value)
    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($bytes)
    ).ToLowerInvariant()
}

function Test-ByteArrayEqual {
    param(
        [AllowEmptyCollection()]
        [byte[]] $Left,

        [AllowEmptyCollection()]
        [byte[]] $Right
    )

    if ($Left.Count -ne $Right.Count) {
        return $false
    }
    for ($index = 0; $index -lt $Left.Count; $index++) {
        if ($Left[$index] -ne $Right[$index]) {
            return $false
        }
    }
    return $true
}

function Get-ExpectedPromptSpec {
    param(
        [Parameter(Mandatory)]
        [object] $MatrixEntry,

        [Parameter(Mandatory)]
        [string] $ScenarioId,

        [Parameter(Mandatory)]
        [string] $InvocationId,

        [Parameter(Mandatory)]
        [string] $StepLogRoot
    )

    $definition = $MatrixEntry.Definition
    $explicitInvocations = @($definition.Invocations)
    if ($explicitInvocations.Count -gt 0) {
        $matches = @(
            $explicitInvocations |
                Where-Object { [string]$_.Id -ceq $InvocationId }
        )
        if ($matches.Count -ne 1) {
            throw "Expected invocation prompt is unavailable: $InvocationId"
        }
        $prompt = [string]$matches[0].Prompt
        $promptPath = Join-Path $StepLogRoot (
            "invocations/$InvocationId/prompt.md"
        )
    }
    else {
        if ($InvocationId -cne 'main') {
            throw "Default invocation must be main: $InvocationId"
        }
        $scenarioMatches = @(
            $definition.Scenarios |
                Where-Object { [string]$_.Id -ceq $ScenarioId }
        )
        if ($scenarioMatches.Count -ne 1) {
            throw "Expected scenario prompt is unavailable: $ScenarioId"
        }
        $scenarioPrompt = [string]$scenarioMatches[0].Prompt
        $prompt = if (-not [string]::IsNullOrWhiteSpace($scenarioPrompt)) {
            $scenarioPrompt
        }
        else {
            [string]$definition.UserRequest
        }
        $promptPath = Join-Path $StepLogRoot 'prompt.md'
    }

    $promptSha256 = Get-StringSha256 -Value $prompt
    return [pscustomobject]@{
        Prompt = $prompt
        PromptPath = Get-MeechoNormalizedPath -Path $promptPath
        Argument = "<prompt sha256=$promptSha256 length=$($prompt.Length)>"
        Bytes = [Text.UTF8Encoding]::new($false).GetBytes($prompt)
    }
}

function Get-ExpectedCaseInputEvidence {
    param(
        [Parameter(Mandatory)]
        [object] $MatrixEntry,

        [Parameter(Mandatory)]
        [string] $ScenarioWorkspace,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]] $Issues
    )

    $definition = $MatrixEntry.Definition
    $accessibleFiles = [Collections.Generic.List[object]]::new()
    $evidenceAvailable = $true
    foreach ($file in @($definition.AccessibleFiles)) {
        try {
            $destinationPath = Get-MeechoNormalizedPath -Path (
                Join-Path $ScenarioWorkspace ([string]$file.Destination)
            )
            if (-not (Test-MeechoPathUnder `
                -Child $destinationPath `
                -Parent $ScenarioWorkspace
            )) {
                throw 'STAGED_INPUT_OUTSIDE_WORKSPACE'
            }
            Assert-MeechoNoReparsePoint -Path $destinationPath
            if (-not (Test-Path -LiteralPath $destinationPath -PathType Leaf)) {
                throw 'STAGED_INPUT_MISSING'
            }
            Assert-MeechoNoReparsePoint -Path ([string]$file.SourcePath)
            $sourceSha256 = Get-MeechoSha256 -Path ([string]$file.SourcePath)
            $destinationSha256 = Get-MeechoSha256 -Path $destinationPath
            if ($sourceSha256 -cne $destinationSha256) {
                Add-ValidationIssue `
                    -Issues $Issues `
                    -Issue 'staged-input-content'
            }
            $accessibleFiles.Add([ordered]@{
                source = [string]$file.Source
                destination = [string]$file.Destination
                sha256 = $destinationSha256
            })
        }
        catch {
            $evidenceAvailable = $false
            Add-ValidationIssue -Issues $Issues -Issue 'staged-input-layout'
        }
    }
    if (-not $evidenceAvailable) {
        return $null
    }

    $payload = @(
        [ordered]@{
            casePathSha256 = [string]$MatrixEntry.CasePathSha256
            accessibleFiles = @($accessibleFiles)
        }
    )
    $json = ConvertTo-Json @($payload) -Compress -Depth 30
    return [pscustomobject]@{
        Sha256 = Get-StringSha256 -Value $json
        AccessibleFiles = @($accessibleFiles)
    }
}

function Test-OrderedStringArrayEqual {
    param(
        [AllowEmptyCollection()]
        [object[]] $Left,

        [AllowEmptyCollection()]
        [object[]] $Right
    )

    if (@($Left).Count -ne @($Right).Count) {
        return $false
    }
    for ($index = 0; $index -lt @($Left).Count; $index++) {
        if ([string](@($Left)[$index]) -cne [string](@($Right)[$index])) {
            return $false
        }
    }
    return $true
}

function Get-ExpectedScenarioMatrix {
    param(
        [Parameter(Mandatory)]
        [string] $RepoRoot
    )

    $fullRepoRoot = Get-MeechoNormalizedPath -Path $RepoRoot
    Assert-MeechoNoReparsePoint -Path $fullRepoRoot
    $casesRoot = Get-MeechoNormalizedPath -Path (
        Join-Path $fullRepoRoot 'evals/cases'
    )
    Assert-MeechoNoReparsePoint -Path $casesRoot
    if (-not (Test-Path -LiteralPath $casesRoot -PathType Container)) {
        throw "Case registry does not exist: $casesRoot"
    }

    $casePaths = @(
        Get-ChildItem -LiteralPath $casesRoot -Filter '*.md' -File -Force |
            Sort-Object Name
    )
    if ($casePaths.Count -ne 9) {
        throw "Case registry must contain exactly nine Markdown files; found $($casePaths.Count)."
    }

    $caseFingerprintItems = @(
        foreach ($casePath in $casePaths) {
            Assert-MeechoNoReparsePoint -Path $casePath.FullName
            [ordered]@{
                path = $casePath.Name
                sha256 = Get-MeechoSha256 -Path $casePath.FullName
            }
        }
    )
    $caseFingerprint = Get-StringSha256 -Value (
        ConvertTo-Json @($caseFingerprintItems) -Compress -Depth 5
    )
    $cached = $script:MeechoExpectedScenarioMatrixCache[$fullRepoRoot]
    if ($null -ne $cached -and
        [string]$cached.Fingerprint -ceq $caseFingerprint) {
        return $cached.Matrix
    }

    $registry = Test-MeechoEvalCaseRegistry -Paths @(
        $casePaths | ForEach-Object FullName
    )
    $matrix = [ordered]@{}
    foreach ($definition in @($registry.Cases)) {
        $caseId = [string]$definition.CaseId
        if ($caseId -notmatch '^case-\d{2}$' -or $matrix.Contains($caseId)) {
            throw "Case metadata has an invalid or duplicate caseId: $caseId"
        }
        $scenarioMap = [ordered]@{}
        $scenarioDefinitions = [ordered]@{}
        foreach ($scenario in @($definition.Scenarios)) {
            $scenarioId = [string]$scenario.Id
            $scenarioMap[$scenarioId] = [string]$scenario.PermissionMode
            $scenarioDefinitions[$scenarioId] = $scenario
        }
        $invocationMap = [ordered]@{}
        $invocationDefinitions = [ordered]@{}
        $invocations = @($definition.Invocations)
        if ($invocations.Count -eq 0) {
            $invocationMap['main'] = ''
        }
        else {
            foreach ($invocation in $invocations) {
                $invocationId = [string]$invocation.Id
                $invocationMap[$invocationId] = [string]$invocation.ProjectRoot
                $invocationDefinitions[$invocationId] = $invocation
            }
        }
        $matrix[$caseId] = [pscustomobject]@{
            Definition = $definition
            CasePath = [string]$definition.Path
            CasePathSha256 = [string](
                @(
                    $caseFingerprintItems |
                        Where-Object {
                            [string]$_.path -ceq (
                                Split-Path -Leaf ([string]$definition.Path)
                            )
                        }
                )[0].sha256
            )
            Scenarios = $scenarioMap
            ScenarioDefinitions = $scenarioDefinitions
            Invocations = $invocationMap
            InvocationDefinitions = $invocationDefinitions
            AccessibleFiles = @($definition.AccessibleFiles)
        }
    }
    foreach ($expectedCaseId in 1..9 | ForEach-Object { 'case-{0:D2}' -f $_ }) {
        if (-not $matrix.Contains($expectedCaseId)) {
            throw "Case registry is missing $expectedCaseId."
        }
    }
    $script:MeechoExpectedScenarioMatrixCache[$fullRepoRoot] = [pscustomobject]@{
        Fingerprint = $caseFingerprint
        Matrix = $matrix
    }
    return $matrix
}

function Test-RunManifest {
    param(
        [Parameter(Mandatory)]
        [object] $Manifest,

        [Parameter(Mandatory)]
        [string] $Path
    )

    $issues = [System.Collections.Generic.List[string]]::new()
    $logContract = Test-MeechoRunLogContract -ManifestPath $Path
    foreach ($failure in @($logContract.Failures)) {
        Add-ValidationIssue -Issues $issues -Issue ([string]$failure)
    }

    $runId = [string](
        Get-PropertyValue -InputObject $Manifest -Name 'runId' -DefaultValue ''
    )
    $mode = [string](
        Get-PropertyValue -InputObject $Manifest -Name 'mode' -DefaultValue ''
    )
    $status = [string](
        Get-PropertyValue -InputObject $Manifest -Name 'status' -DefaultValue ''
    )
    $model = [string](
        Get-PropertyValue -InputObject $Manifest -Name 'model' -DefaultValue ''
    )
    $reasoning = [string](
        Get-PropertyValue -InputObject $Manifest -Name 'reasoningEffort' -DefaultValue ''
    )
    $configSha256 = [string](
        Get-PropertyValue -InputObject $Manifest -Name 'configSha256' -DefaultValue ''
    )
    $capsuleRoot = Get-MeechoNormalizedPath -Path ([string](
        Get-PropertyValue -InputObject $Manifest -Name 'capsuleRoot' -DefaultValue ''
    ))
    $declaredRepoRoot = Get-MeechoNormalizedPath -Path ([string](
        Get-PropertyValue -InputObject $Manifest -Name 'repoRoot' -DefaultValue ''
    ))
    $repoRoot = Get-MeechoNormalizedPath -Path (
        Join-Path $PSScriptRoot '../..'
    )
    Assert-MeechoNoReparsePoint -Path $capsuleRoot
    Assert-MeechoNoReparsePoint -Path $repoRoot
    if (-not $declaredRepoRoot.Equals(
        $repoRoot,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        Add-ValidationIssue -Issues $issues -Issue 'repoRoot'
    }
    $cases = @(
        Get-PropertyValue -InputObject $Manifest -Name 'cases' -DefaultValue @()
    )
    $declaredFailures = @(
        Get-PropertyValue -InputObject $Manifest -Name 'failures' -DefaultValue @()
    )
    $manifestEnvironmentNames = @(
        Get-PropertyValue `
            -InputObject $Manifest `
            -Name 'environmentNames' `
            -DefaultValue @()
    )

    if ($mode -notin @('control', 'treatment')) {
        Add-ValidationIssue -Issues $issues -Issue 'mode'
    }
    if ([string]::IsNullOrWhiteSpace($model)) {
        Add-ValidationIssue -Issues $issues -Issue 'model'
    }
    if ($reasoning -cne 'high') {
        Add-ValidationIssue -Issues $issues -Issue 'reasoningEffort'
    }
    if (-not (Test-Sha256 -Value $configSha256)) {
        Add-ValidationIssue -Issues $issues -Issue 'configSha256'
    }
    if (-not (Test-MeechoEnvironmentNameContract `
        -Names $manifestEnvironmentNames `
        -RequireRewritten
    )) {
        Add-ValidationIssue -Issues $issues -Issue 'environmentNames'
    }
    if ($status -ceq 'COMPLETE' -and $declaredFailures.Count -ne 0) {
        Add-ValidationIssue -Issues $issues -Issue 'complete-run-has-failures'
    }
    if ($status -ceq 'AUTH_REQUIRED' -and (
        $declaredFailures.Count -ne 1 -or
        [string]$declaredFailures[0] -cne 'AUTH_REQUIRED'
    )) {
        Add-ValidationIssue `
            -Issues $issues `
            -Issue 'terminal-run-failure-classification'
    }
    if ($status -ceq 'BLOCKED_NOT_RUN' -and @(
        $declaredFailures | Where-Object {
            [string]$_ -cne 'AUTH_REQUIRED'
        }
    ).Count -eq 0) {
        Add-ValidationIssue `
            -Issues $issues `
            -Issue 'terminal-run-failure-classification'
    }

    $expectedMatrix = Get-ExpectedScenarioMatrix -RepoRoot $repoRoot
    $actualKeys = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $globalFailedItems = [System.Collections.Generic.HashSet[int]]::new()
    $manifestRoot = Split-Path -Parent ([System.IO.Path]::GetFullPath($Path))
    $runLogRoot = Get-MeechoNormalizedPath -Path (
        Join-Path $repoRoot "evals/logs/$runId"
    )
    $steps = @(
        Get-PropertyValue -InputObject $Manifest -Name 'steps' -DefaultValue @()
    )
    if ($steps.Count -eq 0) {
        Add-ValidationIssue -Issues $issues -Issue 'steps-evidence'
    }
    if ($status -ceq 'COMPLETE') {
        $codexVersion = [string](
            Get-PropertyValue -InputObject $Manifest -Name 'codexVersion' -DefaultValue ''
        )
        $codexBinarySha256 = [string](
            Get-PropertyValue `
                -InputObject $Manifest `
                -Name 'codexBinarySha256' `
                -DefaultValue ''
        )
        $codexBinary = [string](
            Get-PropertyValue -InputObject $Manifest -Name 'codexBinary' -DefaultValue ''
        )
        $approvalPolicy = [string](
            Get-PropertyValue -InputObject $Manifest -Name 'approvalPolicy' -DefaultValue ''
        )
        $rubricSha256 = [string](
            Get-PropertyValue -InputObject $Manifest -Name 'rubricSha256' -DefaultValue ''
        )
        $realProfileBeforeSha256 = [string](
            Get-PropertyValue `
                -InputObject $Manifest `
                -Name 'realProfileBeforeSha256' `
                -DefaultValue ''
        )
        $realProfileAfterSha256 = [string](
            Get-PropertyValue `
                -InputObject $Manifest `
                -Name 'realProfileAfterSha256' `
                -DefaultValue ''
        )
        $codexVersionMatch = [regex]::Match(
            $codexVersion,
            '^(\d+)\.(\d+)\.(\d+)(?:[-+][0-9A-Za-z.-]+)?$'
        )
        $parsedCodexVersion = $null
        if ($codexVersionMatch.Success) {
            try {
                $parsedCodexVersion = [version]::new(
                    [int]$codexVersionMatch.Groups[1].Value,
                    [int]$codexVersionMatch.Groups[2].Value,
                    [int]$codexVersionMatch.Groups[3].Value
                )
            }
            catch {
                $parsedCodexVersion = $null
            }
        }
        if ($null -eq $parsedCodexVersion -or
            $parsedCodexVersion -lt [version]'0.145.0') {
            Add-ValidationIssue -Issues $issues -Issue 'codexVersion'
        }
        if ([string]::IsNullOrWhiteSpace($codexBinary) -or
            [System.IO.Path]::GetFileName($codexBinary) -cne $codexBinary) {
            Add-ValidationIssue -Issues $issues -Issue 'codexBinary'
        }
        foreach ($hashField in ([ordered]@{
            codexBinarySha256 = $codexBinarySha256
            rubricSha256 = $rubricSha256
            realProfileBeforeSha256 = $realProfileBeforeSha256
            realProfileAfterSha256 = $realProfileAfterSha256
        }).GetEnumerator()) {
            if (-not (Test-Sha256 -Value ([string]$hashField.Value))) {
                Add-ValidationIssue -Issues $issues -Issue ([string]$hashField.Key)
            }
        }
        try {
            $rubricPath = Get-MeechoNormalizedPath -Path (
                Join-Path $repoRoot 'evals/rubric.md'
            )
            Assert-MeechoNoReparsePoint -Path $rubricPath
            if (-not (Test-Path -LiteralPath $rubricPath -PathType Leaf) -or
                (Get-MeechoSha256 -Path $rubricPath) -cne $rubricSha256) {
                Add-ValidationIssue -Issues $issues -Issue 'rubric-evidence'
            }
        }
        catch {
            Add-ValidationIssue -Issues $issues -Issue 'rubric-evidence'
        }
        if ($approvalPolicy -cne 'never') {
            Add-ValidationIssue -Issues $issues -Issue 'approvalPolicy'
        }
        if ($realProfileBeforeSha256 -cne $realProfileAfterSha256) {
            Add-ValidationIssue -Issues $issues -Issue 'real-profile-changed'
        }
        try {
            $templateConfigPath = Get-MeechoNormalizedPath -Path (
                Join-Path $repoRoot 'evals/capsule/config.toml'
            )
            $effectiveConfigPath = Get-MeechoNormalizedPath -Path (
                Join-Path $capsuleRoot "$mode/codex-home/config.toml"
            )
            foreach ($configPath in $templateConfigPath, $effectiveConfigPath) {
                Assert-MeechoNoReparsePoint -Path $configPath
                if (-not (Test-Path -LiteralPath $configPath -PathType Leaf) -or
                    (Get-MeechoSha256 -Path $configPath) -cne $configSha256) {
                    Add-ValidationIssue -Issues $issues -Issue 'config-evidence'
                }
            }
        }
        catch {
            Add-ValidationIssue -Issues $issues -Issue 'config-evidence'
        }

        $permissionPreflights = @(
            Get-PropertyValue `
                -InputObject $Manifest `
                -Name 'permissionPreflights' `
                -DefaultValue @()
        )
        $preflightModes = [System.Collections.Generic.HashSet[string]]::new(
            [StringComparer]::Ordinal
        )
        if ($permissionPreflights.Count -ne 3) {
            Add-ValidationIssue -Issues $issues -Issue 'permissionPreflights'
        }
        $commonPreflightCheckNames = @(
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
        foreach ($permissionPreflight in $permissionPreflights) {
            $permissionMode = [string](
                Get-PropertyValue `
                    -InputObject $permissionPreflight `
                    -Name 'permissionMode' `
                    -DefaultValue ''
            )
            if ($permissionMode -cnotin @('read', 'allow', 'deny') -or
                -not $preflightModes.Add($permissionMode)) {
                Add-ValidationIssue `
                    -Issues $issues `
                    -Issue 'permissionPreflights'
            }
            if ([string](
                Get-PropertyValue `
                    -InputObject $permissionPreflight `
                    -Name 'status' `
                    -DefaultValue ''
            ) -cne 'ready') {
                Add-ValidationIssue `
                    -Issues $issues `
                    -Issue 'permissionPreflight-status'
            }
            if (-not (Test-StrictBoolean `
                -Value (Get-PropertyValue `
                    -InputObject $permissionPreflight `
                    -Name 'passed') `
                -Expected $true
            )) {
                Add-ValidationIssue `
                    -Issues $issues `
                    -Issue 'permissionPreflight-passed'
            }
            if (@(
                Get-PropertyValue `
                    -InputObject $permissionPreflight `
                    -Name 'failures' `
                    -DefaultValue @()
            ).Count -ne 0) {
                Add-ValidationIssue `
                    -Issues $issues `
                    -Issue 'permissionPreflight-failures'
            }
            if ([string](
                Get-PropertyValue `
                    -InputObject $permissionPreflight `
                    -Name 'configSha256' `
                    -DefaultValue ''
            ) -cne $configSha256) {
                Add-ValidationIssue `
                    -Issues $issues `
                    -Issue 'permissionPreflight-configSha256'
            }

            $preflightCheckNames = [System.Collections.Generic.HashSet[string]]::new(
                [StringComparer]::Ordinal
            )
            $preflightChecks = @(
                Get-PropertyValue `
                    -InputObject $permissionPreflight `
                    -Name 'checks' `
                    -DefaultValue @()
            )
            foreach ($preflightCheck in $preflightChecks) {
                $preflightCheckName = [string](
                    Get-PropertyValue `
                        -InputObject $preflightCheck `
                        -Name 'Name' `
                        -DefaultValue ''
                )
                if ([string]::IsNullOrWhiteSpace($preflightCheckName) -or
                    -not $preflightCheckNames.Add($preflightCheckName)) {
                    Add-ValidationIssue `
                        -Issues $issues `
                        -Issue 'permissionPreflight-checks'
                }
                if (-not (Test-StrictBoolean `
                    -Value (Get-PropertyValue `
                        -InputObject $preflightCheck `
                        -Name 'Passed') `
                    -Expected $true
                )) {
                    Add-ValidationIssue `
                        -Issues $issues `
                        -Issue 'permissionPreflight-checks'
                }
            }
            foreach ($requiredCheckName in @(
                $commonPreflightCheckNames
                "permission-canary-$permissionMode"
            )) {
                if (-not $preflightCheckNames.Contains($requiredCheckName)) {
                    Add-ValidationIssue `
                        -Issues $issues `
                        -Issue 'permissionPreflight-checks'
                }
            }
        }
        foreach ($requiredPermissionMode in 'read', 'allow', 'deny') {
            if (-not $preflightModes.Contains($requiredPermissionMode)) {
                Add-ValidationIssue `
                    -Issues $issues `
                    -Issue 'permissionPreflights'
            }
        }

        $stepReferences = [System.Collections.Generic.Dictionary[string, string]]::new(
            [StringComparer]::OrdinalIgnoreCase
        )
        $stepRecords = [System.Collections.Generic.Dictionary[string, object]]::new(
            [StringComparer]::OrdinalIgnoreCase
        )
        foreach ($step in $steps) {
            try {
                $stepPath = Resolve-MeechoManifestReference `
                    -ManifestRoot $manifestRoot `
                    -Path ([string](
                        Get-PropertyValue `
                            -InputObject $step `
                            -Name 'recordPath' `
                            -DefaultValue ''
                    ))
                $stepHash = [string](
                    Get-PropertyValue `
                        -InputObject $step `
                        -Name 'recordSha256' `
                        -DefaultValue ''
                )
                if ($stepReferences.ContainsKey($stepPath) -or
                    -not (Test-Sha256 -Value $stepHash) -or
                    -not (Test-Path -LiteralPath $stepPath -PathType Leaf) -or
                    (Get-MeechoSha256 -Path $stepPath) -cne $stepHash -or
                    -not (Test-MeechoStepRecord -RecordPath $stepPath)) {
                    Add-ValidationIssue -Issues $issues -Issue 'steps-evidence'
                    continue
                }
                $stepReferences.Add($stepPath, $stepHash)
                $stepRecords.Add(
                    $stepPath,
                    (Get-Content -LiteralPath $stepPath -Raw -Encoding UTF8 |
                        ConvertFrom-Json -Depth 30)
                )
            }
            catch {
                Add-ValidationIssue -Issues $issues -Issue 'steps-evidence'
            }
        }

        foreach ($stepRecordEntry in $stepRecords.GetEnumerator()) {
            $stepRecord = $stepRecordEntry.Value
            $stepName = [string](
                Get-PropertyValue `
                    -InputObject $stepRecord `
                    -Name 'stepName' `
                    -DefaultValue ''
            )
            $isCodexStep = (
                $stepName -in @(
                    'codex-version',
                    'codex-capabilities',
                    'login',
                    'login-status'
                ) -or
                $stepName -cmatch '^codex-exec-[a-f0-9]{12}$'
            )
            if (-not $isCodexStep) {
                continue
            }
            $stepCategory = switch -Regex ($stepName) {
                '^codex-version$' { 'version'; break }
                '^codex-capabilities$' { 'capability'; break }
                '^(?:login|login-status)$' { 'login'; break }
                '^codex-exec-' {
                    if ([string]$stepRecordEntry.Key -match '[\\/]preflight[\\/]') {
                        'canary'
                    }
                    else {
                        'case'
                    }
                    break
                }
            }
            $commandSha256 = [string](
                Get-PropertyValue `
                    -InputObject $stepRecord `
                    -Name 'commandSha256' `
                    -DefaultValue ''
            )
            if (-not (Test-Sha256 -Value $commandSha256) -or
                $commandSha256 -cne $codexBinarySha256) {
                Add-ValidationIssue `
                    -Issues $issues `
                    -Issue 'codex-command-sha256'
                Add-ValidationIssue `
                    -Issues $issues `
                    -Issue "codex-command-sha256-$stepCategory"
            }
            if ([string](
                Get-PropertyValue `
                    -InputObject $stepRecord `
                    -Name 'command' `
                    -DefaultValue ''
            ) -cne $codexBinary) {
                Add-ValidationIssue `
                    -Issues $issues `
                    -Issue 'codex-command-identity'
            }
        }

        foreach ($permissionMode in 'read', 'allow', 'deny') {
            try {
                $versionRecordPath = Get-MeechoNormalizedPath -Path (
                    Join-Path $runLogRoot "$mode/preflight/$permissionMode/codex-version.record.json"
                )
                if (-not $stepRecords.ContainsKey($versionRecordPath)) {
                    Add-ValidationIssue -Issues $issues -Issue 'codex-version-evidence'
                    continue
                }
                $versionRecord = $stepRecords[$versionRecordPath]
                $versionArguments = @(
                    Get-PropertyValue `
                        -InputObject $versionRecord `
                        -Name 'arguments' `
                        -DefaultValue @()
                )
                $versionStdout = Get-PropertyValue `
                    -InputObject $versionRecord `
                    -Name 'stdout'
                $versionStdoutPath = Resolve-MeechoManifestReference `
                    -ManifestRoot (Split-Path -Parent $versionRecordPath) `
                    -Path ([string](
                        Get-PropertyValue `
                            -InputObject $versionStdout `
                            -Name 'path' `
                            -DefaultValue ''
                    ))
                $versionText = Get-Content -LiteralPath $versionStdoutPath -Raw -Encoding UTF8
                if ([string](
                    Get-PropertyValue -InputObject $versionRecord -Name 'command' -DefaultValue ''
                ) -cne $codexBinary -or
                    -not (Test-OrderedStringArrayEqual `
                        -Left $versionArguments `
                        -Right @('--version')) -or
                    -not (Test-StrictBoolean `
                        -Value (Get-PropertyValue -InputObject $versionRecord -Name 'started') `
                        -Expected $true) -or
                    -not (Test-StrictBoolean `
                        -Value (Get-PropertyValue -InputObject $versionRecord -Name 'timedOut') `
                        -Expected $false) -or
                    -not (Test-IntegerValue -Value (
                        Get-PropertyValue -InputObject $versionRecord -Name 'exitCode'
                    )) -or
                    [int64](
                        Get-PropertyValue -InputObject $versionRecord -Name 'exitCode'
                    ) -ne 0 -or
                    -not [string]::IsNullOrWhiteSpace([string](
                        Get-PropertyValue -InputObject $versionRecord -Name 'failureCode' -DefaultValue ''
                    )) -or
                    $versionText -notmatch (
                        '(?<!\d)' + [regex]::Escape($codexVersion) + '(?!\d)'
                    )) {
                    Add-ValidationIssue -Issues $issues -Issue 'codex-version-evidence'
                }
            }
            catch {
                Add-ValidationIssue -Issues $issues -Issue 'codex-version-evidence'
            }
        }

        $canaryModes = [System.Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase
        )
        $canaryRefs = @(
            Get-PropertyValue -InputObject $Manifest -Name 'canaryRefs' -DefaultValue @()
        )
        foreach ($canaryRef in $canaryRefs) {
            $permissionMode = [string](
                Get-PropertyValue `
                    -InputObject $canaryRef `
                    -Name 'permissionMode' `
                    -DefaultValue ''
            )
            if ($permissionMode -notin @('read', 'allow', 'deny') -or
                -not $canaryModes.Add($permissionMode)) {
                Add-ValidationIssue -Issues $issues -Issue 'canaryRefs'
                continue
            }
            $recordPath = Resolve-MeechoManifestReference `
                -ManifestRoot $manifestRoot `
                -Path ([string](
                    Get-PropertyValue `
                        -InputObject $canaryRef `
                        -Name 'recordPath' `
                        -DefaultValue ''
                ))
            $expectedCanaryPath = Get-MeechoNormalizedPath -Path (
                Join-Path $runLogRoot "$mode/preflight/$permissionMode/canary-result.json"
            )
            if (-not $recordPath.Equals(
                $expectedCanaryPath,
                [StringComparison]::OrdinalIgnoreCase
            ) -or -not (Test-Path -LiteralPath $recordPath -PathType Leaf)) {
                Add-ValidationIssue -Issues $issues -Issue 'canaryRefs'
                continue
            }
            $recordSha256 = [string](
                Get-PropertyValue `
                    -InputObject $canaryRef `
                    -Name 'recordSha256' `
                    -DefaultValue ''
            )
            if (-not (Test-Sha256 -Value $recordSha256) -or
                (Get-MeechoSha256 -Path $recordPath) -cne $recordSha256) {
                Add-ValidationIssue -Issues $issues -Issue 'canaryRefs'
                continue
            }
            try {
                $canary = Get-Content -LiteralPath $recordPath -Raw -Encoding UTF8 |
                    ConvertFrom-Json -Depth 30
                if ([int](
                    Get-PropertyValue `
                        -InputObject $canary `
                        -Name 'schemaVersion' `
                        -DefaultValue 0
                ) -ne 1 -or
                    [string](
                        Get-PropertyValue -InputObject $canary -Name 'kind' -DefaultValue ''
                    ) -cne 'meecho-eval-permission-canary' -or
                    [string](
                        Get-PropertyValue -InputObject $canary -Name 'runId' -DefaultValue ''
                    ) -cne $runId -or
                    [string](
                        Get-PropertyValue -InputObject $canary -Name 'mode' -DefaultValue ''
                    ) -cne $mode -or
                    [string](
                        Get-PropertyValue `
                            -InputObject $canary `
                            -Name 'caseId' `
                            -DefaultValue ''
                    ) -cne 'preflight' -or
                    [string](
                        Get-PropertyValue `
                            -InputObject $canary `
                            -Name 'scenarioId' `
                            -DefaultValue ''
                    ) -cne $permissionMode -or
                    [string](
                        Get-PropertyValue `
                            -InputObject $canary `
                            -Name 'permissionMode' `
                            -DefaultValue ''
                    ) -cne $permissionMode -or
                    [string](
                        Get-PropertyValue -InputObject $canary -Name 'status' -DefaultValue ''
                    ) -cne 'PASS') {
                    Add-ValidationIssue -Issues $issues -Issue 'canaryRefs'
                }
                foreach ($boundaryField in @(
                    'capsuleForbiddenReadDenied',
                    'realHomeReadDenied',
                    'realHomeMarkerUnchanged',
                    'realHomeMarkerCleanupPassed'
                )) {
                    if (-not (Test-StrictBoolean `
                        -Value (Get-PropertyValue `
                            -InputObject $canary `
                            -Name $boundaryField) `
                        -Expected $true
                    )) {
                        Add-ValidationIssue `
                            -Issues $issues `
                            -Issue 'canary-boundary-evidence'
                        Add-ValidationIssue `
                            -Issues $issues `
                            -Issue "canary-boundary-evidence-$boundaryField"
                    }
                }
                if (-not (Test-Sha256 -Value ([string](
                    Get-PropertyValue `
                        -InputObject $canary `
                        -Name 'realHomeMarkerSha256' `
                        -DefaultValue ''
                )))) {
                    Add-ValidationIssue `
                        -Issues $issues `
                        -Issue 'canary-boundary-evidence'
                    Add-ValidationIssue `
                        -Issues $issues `
                        -Issue 'canary-boundary-evidence-realHomeMarkerSha256'
                }

                $canaryArtifacts = @(
                    Get-PropertyValue `
                        -InputObject $canary `
                        -Name 'artifacts' `
                        -DefaultValue @()
                )
                $artifactNames = [System.Collections.Generic.HashSet[string]]::new(
                    [StringComparer]::OrdinalIgnoreCase
                )
                $processRecordPath = $null
                foreach ($artifactNameValue in $canaryArtifacts) {
                    $artifactName = [string]$artifactNameValue
                    if ([string]::IsNullOrWhiteSpace($artifactName) -or
                        [System.IO.Path]::IsPathFullyQualified($artifactName) -or
                        $artifactName -match '[\\/]' -or
                        -not $artifactNames.Add($artifactName)) {
                        Add-ValidationIssue -Issues $issues -Issue 'canary-artifacts'
                        continue
                    }
                    $artifactPath = Get-MeechoNormalizedPath -Path (
                        Join-Path (Split-Path -Parent $recordPath) $artifactName
                    )
                    Assert-MeechoNoReparsePoint -Path $artifactPath
                    if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
                        Add-ValidationIssue -Issues $issues -Issue 'canary-artifacts'
                        continue
                    }
                    if ($artifactName -cmatch '^codex-exec-[a-f0-9]{12}\.record\.json$') {
                        if ($null -ne $processRecordPath) {
                            Add-ValidationIssue -Issues $issues -Issue 'canary-artifacts'
                        }
                        $processRecordPath = $artifactPath
                    }
                }
                foreach ($requiredArtifact in @(
                    'canary-prompt.md',
                    'canary-final.md',
                    'canary-events.jsonl',
                    'canary-stderr.log'
                )) {
                    if (-not $artifactNames.Contains($requiredArtifact)) {
                        Add-ValidationIssue -Issues $issues -Issue 'canary-artifacts'
                    }
                }
                if ($null -eq $processRecordPath -or
                    -not (Test-MeechoStepRecord -RecordPath $processRecordPath) -or
                    -not $stepReferences.ContainsKey($processRecordPath) -or
                    $stepReferences[$processRecordPath] -cne (
                        Get-MeechoSha256 -Path $processRecordPath
                    )) {
                    Add-ValidationIssue -Issues $issues -Issue 'canary-process-evidence'
                }
                $canaryEventsPath = Join-Path (
                    Split-Path -Parent $recordPath
                ) 'canary-events.jsonl'
                $canaryHasTurnCompleted = $false
                foreach ($eventLine in @(
                    Get-Content -LiteralPath $canaryEventsPath -Encoding UTF8 |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                )) {
                    try {
                        $event = $eventLine | ConvertFrom-Json -Depth 50
                        if ([string](
                            Get-PropertyValue `
                                -InputObject $event `
                                -Name 'type' `
                                -DefaultValue ''
                        ) -ceq 'turn.completed') {
                            $canaryHasTurnCompleted = $true
                        }
                    }
                    catch {
                        Add-ValidationIssue -Issues $issues -Issue 'canary-artifacts'
                    }
                }
                if (-not $canaryHasTurnCompleted) {
                    Add-ValidationIssue -Issues $issues -Issue 'canary-turn-completed'
                }
            }
            catch {
                Add-ValidationIssue -Issues $issues -Issue 'canaryRefs'
            }
        }
        if (-not (Test-StringSetEqual `
            -Left @($canaryModes) `
            -Right @('read', 'allow', 'deny')
        )) {
            Add-ValidationIssue -Issues $issues -Issue 'canaryRefs'
        }
    }
    foreach ($case in $cases) {
        $caseId = [string](
            Get-PropertyValue -InputObject $case -Name 'caseId' -DefaultValue ''
        )
        $scenarioId = [string](
            Get-PropertyValue -InputObject $case -Name 'scenarioId' -DefaultValue ''
        )
        $permissionMode = [string](
            Get-PropertyValue -InputObject $case -Name 'permissionMode' -DefaultValue ''
        )
        $caseStatus = [string](
            Get-PropertyValue -InputObject $case -Name 'status' -DefaultValue ''
        )
        if (-not $actualKeys.Add("$caseId/$scenarioId")) {
            Add-ValidationIssue -Issues $issues -Issue 'duplicate-case-scenario'
        }
        if (-not $expectedMatrix.Contains($caseId) -or
            -not $expectedMatrix[$caseId].Scenarios.Contains($scenarioId)) {
            Add-ValidationIssue -Issues $issues -Issue 'unknown-case-scenario'
        }
        elseif ([string]$expectedMatrix[$caseId].Scenarios[$scenarioId] -cne $permissionMode) {
            Add-ValidationIssue -Issues $issues -Issue 'permissionMode'
        }
        if ($permissionMode -notin @('read', 'allow', 'deny')) {
            Add-ValidationIssue -Issues $issues -Issue 'permissionMode'
        }
        if ($status -ceq 'COMPLETE' -and $caseStatus -cne 'COMPLETE') {
            Add-ValidationIssue -Issues $issues -Issue 'case-status'
        }

        $caseEnvironmentNames = @(
            Get-PropertyValue -InputObject $case -Name 'environmentNames' -DefaultValue @()
        )
        if (-not (Test-MeechoEnvironmentNameContract `
            -Names $caseEnvironmentNames `
            -RequireRewritten
        ) -or -not (Test-StringSetEqual `
            -Left $manifestEnvironmentNames `
            -Right $caseEnvironmentNames
        )) {
            Add-ValidationIssue -Issues $issues -Issue 'environmentNames'
        }

        $expectedScenarioRoot = Get-MeechoNormalizedPath -Path (
            Join-Path $capsuleRoot "runs/$runId/$mode/$caseId/$scenarioId"
        )
        $expectedStepLogRoot = Get-MeechoNormalizedPath -Path (
            Join-Path $repoRoot "evals/logs/$runId/$mode/$caseId/$scenarioId"
        )
        $exactPaths = [ordered]@{
            scenarioRoot = $expectedScenarioRoot
            scenarioUserHome = (Join-Path $expectedScenarioRoot 'user-home')
            scenarioWorkspace = (Join-Path $expectedScenarioRoot 'workspace')
            codexSqliteHome = (Join-Path $expectedScenarioRoot 'state')
            scenarioTemp = (Join-Path $expectedScenarioRoot 'temp')
            stepLogRoot = $expectedStepLogRoot
        }
        foreach ($field in $exactPaths.Keys) {
            $actualPath = Get-MeechoNormalizedPath -Path ([string](
                Get-PropertyValue -InputObject $case -Name $field -DefaultValue ''
            ))
            if (-not $actualPath.Equals(
                (Get-MeechoNormalizedPath -Path $exactPaths[$field]),
                [StringComparison]::OrdinalIgnoreCase
            )) {
                Add-ValidationIssue -Issues $issues -Issue "$field-layout"
            }
        }

        if ($status -cne 'COMPLETE') {
            continue
        }

        $caseInputSha256 = [string](
            Get-PropertyValue -InputObject $case -Name 'caseInputSha256' -DefaultValue ''
        )
        $caseRubricSha256 = [string](
            Get-PropertyValue -InputObject $case -Name 'rubricSha256' -DefaultValue ''
        )
        $initialProfileSha256 = [string](
            Get-PropertyValue `
                -InputObject $case `
                -Name 'initialProfileSha256' `
                -DefaultValue ''
        )
        if (-not (Test-Sha256 -Value $caseInputSha256)) {
            Add-ValidationIssue -Issues $issues -Issue 'caseInputSha256'
        }
        $expectedCaseInputEvidence = if ($expectedMatrix.Contains($caseId)) {
            Get-ExpectedCaseInputEvidence `
                -MatrixEntry $expectedMatrix[$caseId] `
                -ScenarioWorkspace $exactPaths.scenarioWorkspace `
                -Issues $issues
        }
        else {
            $null
        }
        if ($null -eq $expectedCaseInputEvidence -or
            [string]$expectedCaseInputEvidence.Sha256 -cne $caseInputSha256) {
            Add-ValidationIssue -Issues $issues -Issue 'case-input-binding'
        }
        if (-not (Test-Sha256 -Value $caseRubricSha256) -or
            $caseRubricSha256 -cne [string](
                Get-PropertyValue `
                    -InputObject $Manifest `
                    -Name 'rubricSha256' `
                    -DefaultValue ''
            )) {
            Add-ValidationIssue -Issues $issues -Issue 'rubricSha256'
        }
        if (-not (Test-Sha256 -Value $initialProfileSha256)) {
            Add-ValidationIssue -Issues $issues -Issue 'initialProfileSha256'
        }

        $aggregateTurnCompletedCount = 0
        $aggregateJsonlPath = $null
        $jsonlArtifacts = @(
            @(
                Get-PropertyValue -InputObject $case -Name 'artifacts' -DefaultValue @()
            ) | Where-Object {
                [string](
                    Get-PropertyValue -InputObject $_ -Name 'kind' -DefaultValue ''
                ) -ceq 'jsonl'
            }
        )
        if ($jsonlArtifacts.Count -ne 1) {
            Add-ValidationIssue -Issues $issues -Issue 'jsonl-evidence'
        }
        else {
            $jsonlPathValue = [string](
                Get-PropertyValue `
                    -InputObject $jsonlArtifacts[0] `
                    -Name 'path' `
                    -DefaultValue ''
            )
            $jsonlPath = if ([System.IO.Path]::IsPathFullyQualified($jsonlPathValue)) {
                Get-MeechoNormalizedPath -Path $jsonlPathValue
            } else {
                Get-MeechoNormalizedPath -Path (Join-Path $manifestRoot $jsonlPathValue)
            }
            $aggregateJsonlPath = $jsonlPath
            $jsonLines = @(
                Get-Content -LiteralPath $jsonlPath -Encoding UTF8 |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            )
            if ($jsonLines.Count -eq 0) {
                Add-ValidationIssue -Issues $issues -Issue 'jsonl-evidence'
            }
            else {
                foreach ($jsonLine in $jsonLines) {
                    try {
                        $jsonEvent = $jsonLine | ConvertFrom-Json -Depth 50
                        if ([string](
                            Get-PropertyValue `
                                -InputObject $jsonEvent `
                                -Name 'type' `
                                -DefaultValue ''
                        ) -ceq 'turn.completed') {
                            $aggregateTurnCompletedCount++
                        }
                    }
                    catch {
                        Add-ValidationIssue -Issues $issues -Issue 'jsonl-evidence'
                        break
                    }
                }
                if ($aggregateTurnCompletedCount -eq 0) {
                    Add-ValidationIssue -Issues $issues -Issue 'jsonl-turn-completed'
                }
            }
        }

        $resultArtifacts = @(
            @(
                Get-PropertyValue -InputObject $case -Name 'artifacts' -DefaultValue @()
            ) | Where-Object {
                [string](
                    Get-PropertyValue -InputObject $_ -Name 'kind' -DefaultValue ''
                ) -ceq 'result'
            }
        )
        if ($resultArtifacts.Count -ne 1) {
            Add-ValidationIssue -Issues $issues -Issue 'result-artifact'
            continue
        }
        $resultPathValue = [string](
            Get-PropertyValue `
                -InputObject $resultArtifacts[0] `
                -Name 'path' `
                -DefaultValue ''
        )
        $resultPath = if ([System.IO.Path]::IsPathFullyQualified($resultPathValue)) {
            Get-MeechoNormalizedPath -Path $resultPathValue
        }
        else {
            Get-MeechoNormalizedPath -Path (Join-Path $manifestRoot $resultPathValue)
        }
        if (-not (Test-MeechoPathUnder `
            -Child $resultPath `
            -Parent $expectedStepLogRoot
        )) {
            Add-ValidationIssue -Issues $issues -Issue 'result-outside-step-log-root'
            continue
        }
        try {
            $result = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 |
                ConvertFrom-Json -Depth 50
        }
        catch {
            Add-ValidationIssue -Issues $issues -Issue 'result-json'
            continue
        }
        foreach ($identityField in 'caseId', 'scenarioId', 'permissionMode') {
            $expectedIdentity = switch ($identityField) {
                'caseId' { $caseId }
                'scenarioId' { $scenarioId }
                'permissionMode' { $permissionMode }
            }
            if ([string](
                Get-PropertyValue `
                    -InputObject $result `
                    -Name $identityField `
                    -DefaultValue ''
            ) -cne $expectedIdentity) {
                Add-ValidationIssue -Issues $issues -Issue 'result-identity'
            }
        }
        if ([string](
            Get-PropertyValue -InputObject $result -Name 'status' -DefaultValue ''
        ) -cne 'COMPLETE') {
            Add-ValidationIssue -Issues $issues -Issue 'result-status'
        }
        if ([string](
            Get-PropertyValue `
                -InputObject $result `
                -Name 'caseInputSha256' `
                -DefaultValue ''
        ) -cne $caseInputSha256 -or
            [string](
                Get-PropertyValue `
                    -InputObject $result `
                    -Name 'rubricSha256' `
                    -DefaultValue ''
            ) -cne $caseRubricSha256 -or
            [string](
                Get-PropertyValue `
                    -InputObject $result `
                    -Name 'profileBeforeSha256' `
                    -DefaultValue ''
            ) -cne $initialProfileSha256) {
            Add-ValidationIssue -Issues $issues -Issue 'result-evidence-hashes'
        }
        if ($null -eq $expectedCaseInputEvidence -or
            [string](
                Get-PropertyValue `
                    -InputObject $result `
                    -Name 'caseInputSha256' `
                    -DefaultValue ''
            ) -cne [string]$expectedCaseInputEvidence.Sha256) {
            Add-ValidationIssue -Issues $issues -Issue 'case-input-binding'
        }

        $expectedInvocations = if ($expectedMatrix.Contains($caseId)) {
            $expectedMatrix[$caseId].Invocations
        }
        else {
            [ordered]@{}
        }
        $caseInvocations = @(
            Get-PropertyValue -InputObject $case -Name 'invocations' -DefaultValue @()
        )
        $resultInvocations = @(
            Get-PropertyValue -InputObject $result -Name 'invocations' -DefaultValue @()
        )
        $caseInvocationMap = [System.Collections.Generic.Dictionary[string, object]]::new(
            [StringComparer]::Ordinal
        )
        $resultInvocationMap = [System.Collections.Generic.Dictionary[string, object]]::new(
            [StringComparer]::Ordinal
        )
        foreach ($source in @(
            [pscustomobject]@{ Values = $caseInvocations; Map = $caseInvocationMap },
            [pscustomobject]@{ Values = $resultInvocations; Map = $resultInvocationMap }
        )) {
            if (@($source.Values).Count -ne $expectedInvocations.Count) {
                Add-ValidationIssue -Issues $issues -Issue 'invocation-matrix'
            }
            foreach ($invocation in @($source.Values)) {
                $invocationId = [string](
                    Get-PropertyValue -InputObject $invocation -Name 'id' -DefaultValue ''
                )
                if (-not $expectedInvocations.Contains($invocationId) -or
                    $source.Map.ContainsKey($invocationId)) {
                    Add-ValidationIssue -Issues $issues -Issue 'invocation-matrix'
                    continue
                }
                $source.Map.Add($invocationId, $invocation)
            }
        }
        foreach ($expectedInvocationId in $expectedInvocations.Keys) {
            if (-not $caseInvocationMap.ContainsKey($expectedInvocationId) -or
                -not $resultInvocationMap.ContainsKey($expectedInvocationId)) {
                Add-ValidationIssue -Issues $issues -Issue 'invocation-matrix'
                continue
            }
            $caseInvocation = $caseInvocationMap[$expectedInvocationId]
            $resultInvocation = $resultInvocationMap[$expectedInvocationId]
            foreach ($invocationField in @(
                'id',
                'workingDirectory',
                'exitCode',
                'startedAtUtc',
                'endedAtUtc',
                'workspaceBeforeSha256',
                'workspaceAfterSha256',
                'finalPath',
                'jsonlPath',
                'stderrPath',
                'jsonlValid',
                'turnCompleted',
                'finalValid'
            )) {
                if (-not (Test-ComparableValueEqual `
                    -Left (Get-PropertyValue -InputObject $caseInvocation -Name $invocationField) `
                    -Right (Get-PropertyValue -InputObject $resultInvocation -Name $invocationField) `
                    -Field $invocationField
                )) {
                    Add-ValidationIssue -Issues $issues -Issue 'result-invocations'
                }
            }
            if (-not (Test-StringSetEqual `
                -Left @(
                    Get-PropertyValue `
                        -InputObject $caseInvocation `
                        -Name 'workspaceRoots' `
                        -DefaultValue @()
                ) `
                -Right @(
                    Get-PropertyValue `
                        -InputObject $resultInvocation `
                        -Name 'workspaceRoots' `
                        -DefaultValue @()
                )
            )) {
                Add-ValidationIssue -Issues $issues -Issue 'result-invocations'
            }

            try {
                $projectRoot = [string]$expectedInvocations[$expectedInvocationId]
                $expectedWorkingDirectory = if ([string]::IsNullOrWhiteSpace($projectRoot)) {
                    Get-MeechoNormalizedPath -Path $exactPaths.scenarioWorkspace
                } else {
                    Get-MeechoNormalizedPath -Path (
                        Join-Path $exactPaths.scenarioWorkspace $projectRoot
                    )
                }
                $expectedPromptSpec = $null
                try {
                    $expectedPromptSpec = Get-ExpectedPromptSpec `
                        -MatrixEntry $expectedMatrix[$caseId] `
                        -ScenarioId $scenarioId `
                        -InvocationId $expectedInvocationId `
                        -StepLogRoot $expectedStepLogRoot
                    Assert-MeechoNoReparsePoint `
                        -Path $expectedPromptSpec.PromptPath
                    if (-not (Test-Path `
                        -LiteralPath $expectedPromptSpec.PromptPath `
                        -PathType Leaf
                    )) {
                        throw 'PROMPT_FILE_MISSING'
                    }
                    $actualPromptBytes = [IO.File]::ReadAllBytes(
                        $expectedPromptSpec.PromptPath
                    )
                    if (-not (Test-ByteArrayEqual `
                        -Left $actualPromptBytes `
                        -Right $expectedPromptSpec.Bytes
                    )) {
                        Add-ValidationIssue `
                            -Issues $issues `
                            -Issue 'invocation-prompt-file'
                    }
                }
                catch {
                    Add-ValidationIssue `
                        -Issues $issues `
                        -Issue 'invocation-prompt-file'
                    Add-ValidationIssue `
                        -Issues $issues `
                        -Issue 'invocation-prompt-binding'
                }
                $workingDirectory = Get-MeechoNormalizedPath -Path ([string](
                    Get-PropertyValue `
                        -InputObject $caseInvocation `
                        -Name 'workingDirectory' `
                        -DefaultValue ''
                ))
                if (-not $workingDirectory.Equals(
                    $expectedWorkingDirectory,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                    Add-ValidationIssue -Issues $issues -Issue 'invocation-working-directory'
                }
                $expectedWorkspaceRoots = if ($permissionMode -ceq 'allow') {
                    @($expectedWorkingDirectory, $exactPaths.scenarioUserHome)
                } else {
                    @($expectedWorkingDirectory)
                }
                if (-not (Test-StringSetEqual `
                    -Left @(
                        Get-PropertyValue `
                            -InputObject $caseInvocation `
                            -Name 'workspaceRoots' `
                            -DefaultValue @()
                    ) `
                    -Right $expectedWorkspaceRoots
                )) {
                    Add-ValidationIssue -Issues $issues -Issue 'invocation-workspace-roots'
                }
                foreach ($inventoryHashField in 'workspaceBeforeSha256', 'workspaceAfterSha256') {
                    if (-not (Test-Sha256 -Value ([string](
                        Get-PropertyValue `
                            -InputObject $caseInvocation `
                            -Name $inventoryHashField `
                            -DefaultValue ''
                    )))) {
                        Add-ValidationIssue -Issues $issues -Issue 'invocation-inventory-hashes'
                    }
                }
                if (-not (Test-IntegerValue -Value (
                    Get-PropertyValue -InputObject $caseInvocation -Name 'exitCode'
                )) -or [int64](
                    Get-PropertyValue -InputObject $caseInvocation -Name 'exitCode'
                ) -ne 0) {
                    Add-ValidationIssue -Issues $issues -Issue 'invocation-exit-code'
                }
                foreach ($trueField in 'jsonlValid', 'turnCompleted', 'finalValid') {
                    if (-not (Test-StrictBoolean `
                        -Value (Get-PropertyValue -InputObject $caseInvocation -Name $trueField) `
                        -Expected $true
                    )) {
                        Add-ValidationIssue -Issues $issues -Issue 'invocation-evidence-flags'
                    }
                }

                $invocationRoot = Get-MeechoNormalizedPath -Path (
                    Join-Path $expectedStepLogRoot "invocations/$expectedInvocationId"
                )
                $expectedInvocationPaths = [ordered]@{
                    finalPath = (Join-Path $invocationRoot 'final.md')
                    jsonlPath = (Join-Path $invocationRoot 'events.jsonl')
                    stderrPath = (Join-Path $invocationRoot 'codex.stderr.log')
                }
                $resolvedInvocationPaths = [ordered]@{}
                foreach ($pathField in $expectedInvocationPaths.Keys) {
                    $invocationPath = Get-MeechoNormalizedPath -Path ([string](
                        Get-PropertyValue `
                            -InputObject $caseInvocation `
                            -Name $pathField `
                            -DefaultValue ''
                    ))
                    if (-not $invocationPath.Equals(
                        (Get-MeechoNormalizedPath -Path $expectedInvocationPaths[$pathField]),
                        [StringComparison]::OrdinalIgnoreCase
                    )) {
                        Add-ValidationIssue -Issues $issues -Issue 'invocation-artifact-layout'
                    }
                    Assert-MeechoNoReparsePoint -Path $invocationPath
                    if (-not (Test-Path -LiteralPath $invocationPath -PathType Leaf)) {
                        Add-ValidationIssue -Issues $issues -Issue 'invocation-artifacts'
                    }
                    $resolvedInvocationPaths[$pathField] = $invocationPath
                }
                $invocationFinalText = Get-Content `
                    -LiteralPath $resolvedInvocationPaths.finalPath `
                    -Raw `
                    -Encoding UTF8
                if ([string]::IsNullOrWhiteSpace($invocationFinalText)) {
                    Add-ValidationIssue -Issues $issues -Issue 'invocation-final'
                }
                $invocationTurnCompletedCount = 0
                foreach ($invocationEventLine in @(
                    Get-Content -LiteralPath $resolvedInvocationPaths.jsonlPath -Encoding UTF8 |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                )) {
                    try {
                        $invocationEvent = $invocationEventLine | ConvertFrom-Json -Depth 50
                        if ([string](
                            Get-PropertyValue `
                                -InputObject $invocationEvent `
                                -Name 'type' `
                                -DefaultValue ''
                        ) -ceq 'turn.completed') {
                            $invocationTurnCompletedCount++
                        }
                    }
                    catch {
                        Add-ValidationIssue -Issues $issues -Issue 'invocation-jsonl'
                    }
                }
                if ($invocationTurnCompletedCount -eq 0) {
                    Add-ValidationIssue -Issues $issues -Issue 'invocation-turn-completed'
                }
                if ($null -eq $aggregateJsonlPath -or
                    -not (Get-Content -LiteralPath $aggregateJsonlPath -Raw -Encoding UTF8).Contains(
                        (Get-Content `
                            -LiteralPath $resolvedInvocationPaths.jsonlPath `
                            -Raw `
                            -Encoding UTF8)
                    )) {
                    Add-ValidationIssue -Issues $issues -Issue 'invocation-aggregate-binding'
                }

                $execStepName = 'codex-exec-' + (
                    Get-StringSha256 -Value $resolvedInvocationPaths.jsonlPath
                ).Substring(0, 12)
                $execRecordPath = Get-MeechoNormalizedPath -Path (
                    Join-Path $expectedStepLogRoot "$execStepName.record.json"
                )
                if (-not $stepRecords.ContainsKey($execRecordPath) -or
                    -not $stepReferences.ContainsKey($execRecordPath) -or
                    $stepReferences[$execRecordPath] -cne (
                        Get-MeechoSha256 -Path $execRecordPath
                    )) {
                    Add-ValidationIssue -Issues $issues -Issue 'invocation-process-evidence'
                    continue
                }
                $execRecord = $stepRecords[$execRecordPath]
                $execArguments = @(
                    Get-PropertyValue `
                        -InputObject $execRecord `
                        -Name 'arguments' `
                        -DefaultValue @()
                )
                $expectedArguments = [System.Collections.Generic.List[string]]::new()
                $expectedArguments.Add('--strict-config')
                if ($permissionMode -ceq 'allow') {
                    $expectedArguments.Add('--add-dir')
                    $expectedArguments.Add((
                        Get-MeechoNormalizedPath -Path $exactPaths.scenarioUserHome
                    ))
                }
                foreach ($argument in @(
                    'exec',
                    '--ephemeral',
                    '--ignore-rules',
                    '--json',
                    '--model',
                    $model,
                    '-c',
                    'approval_policy="never"',
                    '-c',
                    "default_permissions=`"meecho-capsule-$permissionMode`"",
                    '-C',
                    $expectedWorkingDirectory,
                    '--output-last-message',
                    $resolvedInvocationPaths.finalPath
                )) {
                    $expectedArguments.Add([string]$argument)
                }
                $argumentsValid = $execArguments.Count -eq ($expectedArguments.Count + 1)
                if ($argumentsValid) {
                    for ($argumentIndex = 0;
                        $argumentIndex -lt $expectedArguments.Count;
                        $argumentIndex++) {
                        if ([string]$execArguments[$argumentIndex] -cne
                            [string]$expectedArguments[$argumentIndex]) {
                            $argumentsValid = $false
                            break
                        }
                    }
                }
                if ($null -eq $expectedPromptSpec -or
                    $execArguments.Count -eq 0 -or
                    [string]$execArguments[-1] -cne
                        [string]$expectedPromptSpec.Argument) {
                    Add-ValidationIssue `
                        -Issues $issues `
                        -Issue 'invocation-prompt-binding'
                    $argumentsValid = $false
                }
                $execStdout = Get-PropertyValue -InputObject $execRecord -Name 'stdout'
                $execStderr = Get-PropertyValue -InputObject $execRecord -Name 'stderr'
                if (-not $argumentsValid -or
                    [string](
                        Get-PropertyValue -InputObject $execRecord -Name 'stepName' -DefaultValue ''
                    ) -cne $execStepName -or
                    [string](
                        Get-PropertyValue -InputObject $execRecord -Name 'command' -DefaultValue ''
                    ) -cne $codexBinary -or
                    -not (Test-StrictBoolean `
                        -Value (Get-PropertyValue -InputObject $execRecord -Name 'started') `
                        -Expected $true) -or
                    -not (Test-StrictBoolean `
                        -Value (Get-PropertyValue -InputObject $execRecord -Name 'timedOut') `
                        -Expected $false) -or
                    -not (Test-IntegerValue -Value (
                        Get-PropertyValue -InputObject $execRecord -Name 'exitCode'
                    )) -or
                    [int64](
                        Get-PropertyValue -InputObject $execRecord -Name 'exitCode'
                    ) -ne 0 -or
                    -not [string]::IsNullOrWhiteSpace([string](
                        Get-PropertyValue -InputObject $execRecord -Name 'failureCode' -DefaultValue ''
                    )) -or
                    -not (Test-StringSetEqual `
                        -Left @(
                            Get-PropertyValue `
                                -InputObject $execRecord `
                                -Name 'environmentNames' `
                                -DefaultValue @()
                        ) `
                        -Right $caseEnvironmentNames) -or
                    [string](
                        Get-PropertyValue -InputObject $execStdout -Name 'sha256' -DefaultValue ''
                    ) -cne (Get-MeechoSha256 -Path $resolvedInvocationPaths.jsonlPath) -or
                    [string](
                        Get-PropertyValue -InputObject $execStderr -Name 'sha256' -DefaultValue ''
                    ) -cne (Get-MeechoSha256 -Path $resolvedInvocationPaths.stderrPath)) {
                    Add-ValidationIssue -Issues $issues -Issue 'invocation-process-evidence'
                }
            }
            catch {
                Add-ValidationIssue -Issues $issues -Issue 'invocation-evidence'
            }
        }
        if ($aggregateTurnCompletedCount -lt $expectedInvocations.Count) {
            Add-ValidationIssue -Issues $issues -Issue 'aggregate-invocation-count'
        }

        $rubric = @(
            Get-PropertyValue -InputObject $result -Name 'rubric' -DefaultValue @()
        )
        $scoredItems = [System.Collections.Generic.HashSet[int]]::new()
        $computedFailedItems = [System.Collections.Generic.HashSet[int]]::new()
        if ($rubric.Count -ne 17) {
            Add-ValidationIssue -Issues $issues -Issue 'rubric-item-count'
        }
        foreach ($entry in $rubric) {
            $itemValue = Get-PropertyValue -InputObject $entry -Name 'item'
            $scoreValue = Get-PropertyValue -InputObject $entry -Name 'score'
            if (-not (Test-IntegerValue -Value $itemValue) -or
                [int64]$itemValue -lt 1 -or
                [int64]$itemValue -gt 17 -or
                -not $scoredItems.Add([int]$itemValue)) {
                Add-ValidationIssue -Issues $issues -Issue 'rubric-items'
                continue
            }
            if (-not (Test-IntegerValue -Value $scoreValue) -or
                [int64]$scoreValue -notin @(0, 1)) {
                Add-ValidationIssue -Issues $issues -Issue 'rubric-score'
                continue
            }
            if ([int64]$scoreValue -eq 0) {
                [void]$computedFailedItems.Add([int]$itemValue)
                [void]$globalFailedItems.Add([int]$itemValue)
            }
        }
        if ($scoredItems.Count -ne 17) {
            Add-ValidationIssue -Issues $issues -Issue 'rubric-items'
        }

        $declaredResultFailedItems = @(
            Get-PropertyValue -InputObject $result -Name 'failedItems' -DefaultValue @()
        )
        $declaredCaseFailedItems = @(
            Get-PropertyValue -InputObject $case -Name 'failedItems' -DefaultValue @()
        )
        foreach ($declaredItem in @($declaredResultFailedItems) + @($declaredCaseFailedItems)) {
            if (-not (Test-IntegerValue -Value $declaredItem) -or
                [int64]$declaredItem -lt 1 -or
                [int64]$declaredItem -gt 17) {
                Add-ValidationIssue -Issues $issues -Issue 'failedItems'
            }
        }
        if (-not (Test-StringSetEqual `
            -Left @($computedFailedItems) `
            -Right $declaredResultFailedItems
        ) -or -not (Test-StringSetEqual `
            -Left @($computedFailedItems) `
            -Right $declaredCaseFailedItems
        )) {
            Add-ValidationIssue -Issues $issues -Issue 'failedItems'
        }
    }

    if ($status -ceq 'COMPLETE') {
        $expectedKeys = [System.Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase
        )
        foreach ($entry in $expectedMatrix.GetEnumerator()) {
            foreach ($scenarioId in $entry.Value.Scenarios.Keys) {
                [void]$expectedKeys.Add("$($entry.Key)/$scenarioId")
            }
        }
        if ($actualKeys.Count -ne $expectedKeys.Count) {
            Add-ValidationIssue -Issues $issues -Issue 'scenario-matrix'
        }
        foreach ($key in $expectedKeys) {
            if (-not $actualKeys.Contains($key)) {
                Add-ValidationIssue -Issues $issues -Issue 'scenario-matrix'
                break
            }
        }
        if ($mode -ceq 'control' -and $globalFailedItems.Count -lt 3) {
            Add-ValidationIssue -Issues $issues -Issue 'control-red-failure-floor'
        }
    }

    return [pscustomobject] [ordered]@{
        SchemaVersion = 1
        Kind = 'meecho-eval-run'
        Valid = $issues.Count -eq 0
        Complete = ($issues.Count -eq 0 -and $status -ceq 'COMPLETE')
        Status = $status
        RecommendedStatus = if ($issues.Count -eq 0) {
            $status
        }
        else {
            'BLOCKED_NOT_RUN'
        }
        Failures = @($issues)
    }
}

function Resolve-ComparisonRunSide {
    param(
        [Parameter(Mandatory)]
        [object] $Side,

        [Parameter(Mandatory)]
        [ValidateSet('control', 'treatment')]
        [string] $ExpectedMode,

        [Parameter(Mandatory)]
        [string] $PairRunId,

        [Parameter(Mandatory)]
        [string] $ComparisonRoot,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]] $Issues,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.Dictionary[string, object]] $Cache,

        [ValidateSet('COMPLETE', 'AUTH_REQUIRED', 'BLOCKED_NOT_RUN')]
        [string[]] $AllowedRunStatus = @('COMPLETE'),

        [switch] $RequireDeclaredStatus
    )

    $sideMode = [string](
        Get-PropertyValue -InputObject $Side -Name 'mode' -DefaultValue ''
    )
    $sideRunId = [string](
        Get-PropertyValue -InputObject $Side -Name 'runId' -DefaultValue ''
    )
    if ($sideMode -cne $ExpectedMode -or $sideRunId -cne $PairRunId) {
        Add-ValidationIssue -Issues $Issues -Issue 'side-run-identity'
        return $null
    }

    $manifestPathValue = [string](
        Get-PropertyValue -InputObject $Side -Name 'manifestPath' -DefaultValue ''
    )
    $manifestSha256 = [string](
        Get-PropertyValue -InputObject $Side -Name 'manifestSha256' -DefaultValue ''
    )
    if ([string]::IsNullOrWhiteSpace($manifestPathValue) -or
        -not (Test-Sha256 -Value $manifestSha256)) {
        Add-ValidationIssue -Issues $Issues -Issue 'side-run-manifest-reference'
        return $null
    }

    try {
        $manifestPath = Resolve-MeechoManifestReference `
            -ManifestRoot $ComparisonRoot `
            -Path $manifestPathValue
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or
            (Get-MeechoSha256 -Path $manifestPath) -cne $manifestSha256) {
            Add-ValidationIssue -Issues $Issues -Issue 'side-run-manifest-reference'
            return $null
        }
        $cacheKey = (
            "$ExpectedMode|$($AllowedRunStatus -join ',')|" +
            "$manifestPath|$manifestSha256"
        )
        if ($Cache.ContainsKey($cacheKey)) {
            return $Cache[$cacheKey]
        }

        $runManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 |
            ConvertFrom-Json -Depth 50
        if ([string](
            Get-PropertyValue -InputObject $runManifest -Name 'kind' -DefaultValue ''
        ) -cne 'meecho-eval-run') {
            Add-ValidationIssue -Issues $Issues -Issue 'side-run-manifest-kind'
            return $null
        }
        $runValidation = Test-RunManifest `
            -Manifest $runManifest `
            -Path $manifestPath
        $runStatus = [string](
            Get-PropertyValue -InputObject $runManifest -Name 'status' -DefaultValue ''
        )
        if (-not $runValidation.Valid) {
            Add-ValidationIssue -Issues $Issues -Issue 'side-run-invalid'
        }
        if ($runStatus -notin $AllowedRunStatus) {
            Add-ValidationIssue -Issues $Issues -Issue 'side-run-status'
        }
        if ($AllowedRunStatus -contains 'COMPLETE' -and
            $AllowedRunStatus.Count -eq 1 -and
            -not $runValidation.Complete) {
            Add-ValidationIssue -Issues $Issues -Issue 'side-run-not-complete'
        }
        if ($RequireDeclaredStatus -and
            [string](
                Get-PropertyValue -InputObject $Side -Name 'status' -DefaultValue ''
            ) -cne $runStatus) {
            Add-ValidationIssue -Issues $Issues -Issue 'side-run-status'
        }
        if ([string](
            Get-PropertyValue -InputObject $runManifest -Name 'mode' -DefaultValue ''
        ) -cne $ExpectedMode -or
            [string](
                Get-PropertyValue -InputObject $runManifest -Name 'runId' -DefaultValue ''
            ) -cne $PairRunId) {
            Add-ValidationIssue -Issues $Issues -Issue 'side-run-identity'
        }
        $repoRoot = Get-MeechoNormalizedPath -Path ([string](
            Get-PropertyValue -InputObject $runManifest -Name 'repoRoot' -DefaultValue ''
        ))
        $expectedModeLogRoot = Get-MeechoNormalizedPath -Path (
            Join-Path $repoRoot "evals/logs/$PairRunId/$ExpectedMode"
        )
        if (-not (Test-MeechoPathUnder `
            -Child $manifestPath `
            -Parent $expectedModeLogRoot
        )) {
            Add-ValidationIssue -Issues $Issues -Issue 'side-run-manifest-layout'
        }

        $resolved = [pscustomobject]@{
            Manifest = $runManifest
            Validation = $runValidation
            Path = $manifestPath
            Sha256 = $manifestSha256
        }
        $Cache.Add($cacheKey, $resolved)
        return $resolved
    }
    catch {
        Add-ValidationIssue -Issues $Issues -Issue 'side-run-manifest-reference'
        return $null
    }
}

function Test-ComparisonManifest {
    param(
        [Parameter(Mandatory)]
        [object] $Manifest,

        [Parameter(Mandatory)]
        [string] $Path
    )

    $issues = [System.Collections.Generic.List[string]]::new()
    $mismatches = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $status = [string] (Get-PropertyValue -InputObject $Manifest -Name 'status' -DefaultValue '')
    $pairRunId = [string] (
        Get-PropertyValue -InputObject $Manifest -Name 'pairRunId' -DefaultValue ''
    )
    $controlRunId = [string] (
        Get-PropertyValue -InputObject $Manifest -Name 'controlRunId' -DefaultValue ''
    )
    $treatmentRunId = [string] (
        Get-PropertyValue -InputObject $Manifest -Name 'treatmentRunId' -DefaultValue ''
    )
    $comparisonModel = [string](
        Get-PropertyValue -InputObject $Manifest -Name 'model' -DefaultValue ''
    )
    $comparisonReasoning = [string](
        Get-PropertyValue `
            -InputObject $Manifest `
            -Name 'reasoningEffort' `
            -DefaultValue ''
    )
    $comparisons = @(
        Get-PropertyValue -InputObject $Manifest -Name 'comparisons' -DefaultValue @()
    )
    $declaredFailures = @(
        Get-PropertyValue -InputObject $Manifest -Name 'failures' -DefaultValue @()
    )

    if ([int] (Get-PropertyValue -InputObject $Manifest -Name 'schemaVersion' -DefaultValue 0) -ne 1) {
        Add-ValidationIssue -Issues $issues -Issue 'schemaVersion'
    }
    if ($pairRunId -notmatch '^\d{8}T\d{9}Z-[0-9a-f]{8}$') {
        Add-ValidationIssue -Issues $issues -Issue 'pairRunId'
    }
    if ($controlRunId -cne $pairRunId -or $treatmentRunId -cne $pairRunId) {
        Add-ValidationIssue -Issues $issues -Issue 'paired-run-identity'
    }
    if ($status -notin @(
        'COMPLETE',
        'AUTH_REQUIRED',
        'BLOCKED_NOT_RUN',
        'INVALID_COMPARISON'
    )) {
        Add-ValidationIssue -Issues $issues -Issue 'status'
    }

    $comparisonKeys = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $runCache = [System.Collections.Generic.Dictionary[string, object]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $resolvedPairRuns = [System.Collections.Generic.Dictionary[string, object]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $comparisonRoot = Split-Path -Parent ([System.IO.Path]::GetFullPath($Path))
    $comparisonRepoRoot = $null
    $comparableFields = @(
        'codexBinarySha256',
        'codexVersion',
        'model',
        'reasoningEffort',
        'serviceTier',
        'configSha256',
        'permissionMode',
        'approvalPolicy',
        'environmentNames',
        'caseInputSha256',
        'rubricSha256',
        'initialProfileSha256'
    )
    if ($status -in @('COMPLETE', 'AUTH_REQUIRED', 'BLOCKED_NOT_RUN')) {
        if ([string]::IsNullOrWhiteSpace($comparisonModel)) {
            Add-ValidationIssue -Issues $issues -Issue 'comparison-model'
        }
        if ($comparisonReasoning -cne 'high') {
            Add-ValidationIssue `
                -Issues $issues `
                -Issue 'comparison-reasoningEffort'
        }
    }
    if ($status -in @('AUTH_REQUIRED', 'BLOCKED_NOT_RUN')) {
        $sideRuns = @(
            Get-PropertyValue -InputObject $Manifest -Name 'sideRuns' -DefaultValue @()
        )
        $resolvedTerminalStatuses = [System.Collections.Generic.List[string]]::new()
        if ($sideRuns.Count -ne 2) {
            Add-ValidationIssue -Issues $issues -Issue 'terminal-sideRuns'
        }
        foreach ($expectedMode in 'control', 'treatment') {
            $matchingSideRuns = @(
                $sideRuns | Where-Object {
                    [string](
                        Get-PropertyValue -InputObject $_ -Name 'mode' -DefaultValue ''
                    ) -ceq $expectedMode
                }
            )
            if ($matchingSideRuns.Count -ne 1) {
                Add-ValidationIssue -Issues $issues -Issue 'terminal-sideRuns'
                continue
            }
            $resolvedSideRun = Resolve-ComparisonRunSide `
                -Side $matchingSideRuns[0] `
                -ExpectedMode $expectedMode `
                -PairRunId $pairRunId `
                -ComparisonRoot $comparisonRoot `
                -Issues $issues `
                -Cache $runCache `
                -AllowedRunStatus @('AUTH_REQUIRED', 'BLOCKED_NOT_RUN') `
                -RequireDeclaredStatus
            if ($null -ne $resolvedSideRun) {
                if (-not $resolvedPairRuns.ContainsKey($expectedMode)) {
                    $resolvedPairRuns.Add($expectedMode, $resolvedSideRun)
                }
                $resolvedTerminalStatuses.Add([string](
                    Get-PropertyValue `
                        -InputObject $resolvedSideRun.Manifest `
                        -Name 'status' `
                        -DefaultValue ''
                ))
            }
        }
        if ($status -ceq 'AUTH_REQUIRED' -and
            $resolvedTerminalStatuses -notcontains 'AUTH_REQUIRED') {
            Add-ValidationIssue -Issues $issues -Issue 'terminal-side-status'
        }
        if ($status -ceq 'BLOCKED_NOT_RUN' -and
            $resolvedTerminalStatuses -notcontains 'BLOCKED_NOT_RUN') {
            Add-ValidationIssue -Issues $issues -Issue 'terminal-side-status'
        }
        if ($resolvedTerminalStatuses.Count -eq 2) {
            $reducedTerminalStatus = if (
                $resolvedTerminalStatuses -contains 'BLOCKED_NOT_RUN'
            ) {
                'BLOCKED_NOT_RUN'
            }
            elseif ($resolvedTerminalStatuses -contains 'AUTH_REQUIRED') {
                'AUTH_REQUIRED'
            }
            else {
                'COMPLETE'
            }
            if ($status -cne $reducedTerminalStatus) {
                Add-ValidationIssue `
                    -Issues $issues `
                    -Issue 'terminal-comparison-status-reduction'
            }
        }
        if ($comparisons.Count -ne 0) {
            Add-ValidationIssue -Issues $issues -Issue 'terminal-has-comparisons'
        }
    }
    foreach ($comparison in $comparisons) {
        $caseId = [string] (
            Get-PropertyValue -InputObject $comparison -Name 'caseId' -DefaultValue ''
        )
        $scenarioId = [string] (
            Get-PropertyValue -InputObject $comparison -Name 'scenarioId' -DefaultValue ''
        )
        $permissionMode = [string] (
            Get-PropertyValue -InputObject $comparison -Name 'permissionMode' -DefaultValue ''
        )
        if ($caseId -notmatch '^case-\d{2}$' -or
            $scenarioId -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' -or
            -not $comparisonKeys.Add("$caseId/$scenarioId")) {
            Add-ValidationIssue -Issues $issues -Issue 'comparison-identity'
        }
        if ($permissionMode -notin @('read', 'allow', 'deny')) {
            Add-ValidationIssue -Issues $issues -Issue 'permissionMode'
        }

        $control = Get-PropertyValue -InputObject $comparison -Name 'control'
        $treatment = Get-PropertyValue -InputObject $comparison -Name 'treatment'
        if ($null -eq $control -or $null -eq $treatment) {
            Add-ValidationIssue -Issues $issues -Issue 'comparison-side'
            continue
        }

        foreach ($field in $comparableFields) {
            $leftProperty = $control.PSObject.Properties[$field]
            $rightProperty = $treatment.PSObject.Properties[$field]
            if ($null -eq $leftProperty -or $null -eq $rightProperty) {
                Add-ValidationIssue -Issues $issues -Issue "missing-$field"
                [void] $mismatches.Add($field)
                continue
            }
            if (-not (Test-ComparableValueEqual `
                -Left $leftProperty.Value `
                -Right $rightProperty.Value `
                -Field $field
            )) {
                [void] $mismatches.Add($field)
            }
        }

        foreach ($side in $control, $treatment) {
            foreach ($hashField in @(
                'codexBinarySha256',
                'configSha256',
                'caseInputSha256',
                'rubricSha256',
                'initialProfileSha256'
            )) {
                $property = $side.PSObject.Properties[$hashField]
                if ($null -ne $property -and -not (Test-Sha256 -Value ([string] $property.Value))) {
                    Add-ValidationIssue -Issues $issues -Issue $hashField
                }
            }
            if ([string] (Get-PropertyValue -InputObject $side -Name 'reasoningEffort' -DefaultValue '') -cne 'high') {
                Add-ValidationIssue -Issues $issues -Issue 'reasoningEffort'
            }
            if ([string] (Get-PropertyValue -InputObject $side -Name 'approvalPolicy' -DefaultValue '') -cne 'never') {
                Add-ValidationIssue -Issues $issues -Issue 'approvalPolicy'
            }
            if ([string] (Get-PropertyValue -InputObject $side -Name 'permissionMode' -DefaultValue '') -cne $permissionMode) {
                Add-ValidationIssue -Issues $issues -Issue 'permissionMode'
            }
            $environmentNames = @(
                Get-PropertyValue `
                    -InputObject $side `
                    -Name 'environmentNames' `
                    -DefaultValue @()
            )
            if (-not (Test-MeechoEnvironmentNameContract `
                -Names $environmentNames `
                -RequireRewritten:($status -ceq 'COMPLETE')
            )) {
                Add-ValidationIssue -Issues $issues -Issue 'environmentNames'
            }
        }

        if ($status -ceq 'COMPLETE') {
            $controlRun = Resolve-ComparisonRunSide `
                -Side $control `
                -ExpectedMode control `
                -PairRunId $pairRunId `
                -ComparisonRoot $comparisonRoot `
                -Issues $issues `
                -Cache $runCache
            $treatmentRun = Resolve-ComparisonRunSide `
                -Side $treatment `
                -ExpectedMode treatment `
                -PairRunId $pairRunId `
                -ComparisonRoot $comparisonRoot `
                -Issues $issues `
                -Cache $runCache
            if ($null -eq $controlRun -or $null -eq $treatmentRun) {
                continue
            }
            if (-not $resolvedPairRuns.ContainsKey('control')) {
                $resolvedPairRuns.Add('control', $controlRun)
            }
            if (-not $resolvedPairRuns.ContainsKey('treatment')) {
                $resolvedPairRuns.Add('treatment', $treatmentRun)
            }

            $controlRepoRoot = Get-MeechoNormalizedPath -Path ([string](
                Get-PropertyValue `
                    -InputObject $controlRun.Manifest `
                    -Name 'repoRoot' `
                    -DefaultValue ''
            ))
            $treatmentRepoRoot = Get-MeechoNormalizedPath -Path ([string](
                Get-PropertyValue `
                    -InputObject $treatmentRun.Manifest `
                    -Name 'repoRoot' `
                    -DefaultValue ''
            ))
            if (-not $controlRepoRoot.Equals(
                $treatmentRepoRoot,
                [StringComparison]::OrdinalIgnoreCase
            )) {
                Add-ValidationIssue -Issues $issues -Issue 'side-repoRoot'
            }
            if ($null -eq $comparisonRepoRoot) {
                $comparisonRepoRoot = $controlRepoRoot
            }
            elseif (-not $comparisonRepoRoot.Equals(
                $controlRepoRoot,
                [StringComparison]::OrdinalIgnoreCase
            )) {
                Add-ValidationIssue -Issues $issues -Issue 'side-repoRoot'
            }

            foreach ($runBinding in @(
                [pscustomobject]@{ Side = $control; Run = $controlRun.Manifest }
                [pscustomobject]@{ Side = $treatment; Run = $treatmentRun.Manifest }
            )) {
                $runCase = @(
                    @(
                        Get-PropertyValue `
                            -InputObject $runBinding.Run `
                            -Name 'cases' `
                            -DefaultValue @()
                    ) | Where-Object {
                        [string](
                            Get-PropertyValue -InputObject $_ -Name 'caseId' -DefaultValue ''
                        ) -ceq $caseId -and
                        [string](
                            Get-PropertyValue `
                                -InputObject $_ `
                                -Name 'scenarioId' `
                                -DefaultValue ''
                        ) -ceq $scenarioId
                    }
                )
                if ($runCase.Count -ne 1) {
                    Add-ValidationIssue -Issues $issues -Issue 'side-run-case-binding'
                    continue
                }
                $caseRecord = $runCase[0]
                $runFieldMap = [ordered]@{
                    codexBinarySha256 = [string](
                        Get-PropertyValue `
                            -InputObject $runBinding.Run `
                            -Name 'codexBinarySha256' `
                            -DefaultValue ''
                    )
                    codexVersion = [string](
                        Get-PropertyValue `
                            -InputObject $runBinding.Run `
                            -Name 'codexVersion' `
                            -DefaultValue ''
                    )
                    model = [string](
                        Get-PropertyValue `
                            -InputObject $runBinding.Run `
                            -Name 'model' `
                            -DefaultValue ''
                    )
                    reasoningEffort = [string](
                        Get-PropertyValue `
                            -InputObject $runBinding.Run `
                            -Name 'reasoningEffort' `
                            -DefaultValue ''
                    )
                    serviceTier = [string](
                        Get-PropertyValue `
                            -InputObject $runBinding.Run `
                            -Name 'serviceTier' `
                            -DefaultValue ''
                    )
                    configSha256 = [string](
                        Get-PropertyValue `
                            -InputObject $runBinding.Run `
                            -Name 'configSha256' `
                            -DefaultValue ''
                    )
                    approvalPolicy = [string](
                        Get-PropertyValue `
                            -InputObject $runBinding.Run `
                            -Name 'approvalPolicy' `
                            -DefaultValue ''
                    )
                    environmentNames = @(
                        Get-PropertyValue `
                            -InputObject $runBinding.Run `
                            -Name 'environmentNames' `
                            -DefaultValue @()
                    )
                    permissionMode = [string](
                        Get-PropertyValue `
                            -InputObject $caseRecord `
                            -Name 'permissionMode' `
                            -DefaultValue ''
                    )
                    caseInputSha256 = [string](
                        Get-PropertyValue `
                            -InputObject $caseRecord `
                            -Name 'caseInputSha256' `
                            -DefaultValue ''
                    )
                    rubricSha256 = [string](
                        Get-PropertyValue `
                            -InputObject $caseRecord `
                            -Name 'rubricSha256' `
                            -DefaultValue ''
                    )
                    initialProfileSha256 = [string](
                        Get-PropertyValue `
                            -InputObject $caseRecord `
                            -Name 'initialProfileSha256' `
                            -DefaultValue ''
                    )
                }
                foreach ($field in $runFieldMap.Keys) {
                    $sideValue = Get-PropertyValue `
                        -InputObject $runBinding.Side `
                        -Name $field
                    if (-not (Test-ComparableValueEqual `
                        -Left $sideValue `
                        -Right $runFieldMap[$field] `
                        -Field $field
                    )) {
                        Add-ValidationIssue `
                            -Issues $issues `
                            -Issue "side-evidence-$field"
                    }
                }
            }
        }
    }

    if ($status -in @('COMPLETE', 'AUTH_REQUIRED', 'BLOCKED_NOT_RUN') -and
        $resolvedPairRuns.Count -eq 2) {
        try {
            $currentRepoRoot = Get-MeechoNormalizedPath -Path (
                Join-Path $PSScriptRoot '../..'
            )
            $sideCapsuleRoots = [Collections.Generic.List[string]]::new()
            foreach ($expectedMode in 'control', 'treatment') {
                $sideManifest = $resolvedPairRuns[$expectedMode].Manifest
                $sideModel = [string](
                    Get-PropertyValue `
                        -InputObject $sideManifest `
                        -Name 'model' `
                        -DefaultValue ''
                )
                $sideReasoning = [string](
                    Get-PropertyValue `
                        -InputObject $sideManifest `
                        -Name 'reasoningEffort' `
                        -DefaultValue ''
                )
                if ([string]::IsNullOrWhiteSpace($sideModel) -or
                    $sideModel -cne $comparisonModel) {
                    Add-ValidationIssue `
                        -Issues $issues `
                        -Issue 'comparison-model'
                }
                if ($sideReasoning -cne 'high' -or
                    $sideReasoning -cne $comparisonReasoning) {
                    Add-ValidationIssue `
                        -Issues $issues `
                        -Issue 'comparison-reasoningEffort'
                }
                $sideRepoRoot = Get-MeechoNormalizedPath -Path ([string](
                    Get-PropertyValue `
                        -InputObject $sideManifest `
                        -Name 'repoRoot' `
                        -DefaultValue ''
                ))
                if (-not $sideRepoRoot.Equals(
                    $currentRepoRoot,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                    Add-ValidationIssue `
                        -Issues $issues `
                        -Issue 'side-repoRoot'
                }
                $sideCapsuleRoots.Add((Get-MeechoNormalizedPath -Path ([string](
                    Get-PropertyValue `
                        -InputObject $sideManifest `
                        -Name 'capsuleRoot' `
                        -DefaultValue ''
                ))))
            }
            if (-not $sideCapsuleRoots[0].Equals(
                $sideCapsuleRoots[1],
                [StringComparison]::OrdinalIgnoreCase
            )) {
                Add-ValidationIssue `
                    -Issues $issues `
                    -Issue 'side-capsuleRoot'
            }

            $pairMarkerPath = Get-MeechoNormalizedPath -Path (
                Join-Path $sideCapsuleRoots[0] "runs/$pairRunId/.pair.lock"
            )
            $allocationMarkerPath = Get-MeechoNormalizedPath -Path (
                Join-Path $sideCapsuleRoots[0] "locks/$pairRunId.run.lock"
            )
            $declaredLockPath = Get-MeechoNormalizedPath -Path ([string](
                Get-PropertyValue `
                    -InputObject $Manifest `
                    -Name 'lockPath' `
                    -DefaultValue ''
            ))
            if (-not $declaredLockPath.Equals(
                $pairMarkerPath,
                [StringComparison]::OrdinalIgnoreCase
            )) {
                Add-ValidationIssue -Issues $issues -Issue 'pair-lockPath'
            }
            $expectedMarkerBytes = [Text.UTF8Encoding]::new($false).GetBytes(
                $pairRunId
            )
            $expectedMarkerBase64 = [Convert]::ToBase64String(
                $expectedMarkerBytes
            )
            foreach ($markerEvidence in @(
                [pscustomobject]@{ Name = 'pair'; Path = $pairMarkerPath }
                [pscustomobject]@{
                    Name = 'allocation'
                    Path = $allocationMarkerPath
                }
            )) {
                $markerPath = [string]$markerEvidence.Path
                try {
                    Assert-MeechoNoReparsePoint -Path $markerPath
                    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf) -or
                        [Convert]::ToBase64String(
                            [IO.File]::ReadAllBytes($markerPath)
                        ) -cne $expectedMarkerBase64) {
                        Add-ValidationIssue `
                            -Issues $issues `
                            -Issue 'pair-marker-evidence'
                        Add-ValidationIssue `
                            -Issues $issues `
                            -Issue "pair-marker-evidence-$($markerEvidence.Name)"
                    }
                }
                catch {
                    Add-ValidationIssue `
                        -Issues $issues `
                        -Issue 'pair-marker-evidence'
                    Add-ValidationIssue `
                        -Issues $issues `
                        -Issue "pair-marker-evidence-$($markerEvidence.Name)"
                }
            }
        }
        catch {
            Add-ValidationIssue -Issues $issues -Issue 'pair-binding-evidence'
        }
    }

    if ($status -in @('COMPLETE', 'INVALID_COMPARISON') -and $comparisons.Count -eq 0) {
        Add-ValidationIssue -Issues $issues -Issue 'comparisons'
    }
    if ($status -in @('AUTH_REQUIRED', 'BLOCKED_NOT_RUN') -and $declaredFailures.Count -eq 0) {
        Add-ValidationIssue -Issues $issues -Issue 'terminal-comparison-without-failure'
    }
    if ($status -ceq 'AUTH_REQUIRED' -and (
        $declaredFailures.Count -ne 1 -or
        [string]$declaredFailures[0] -cne 'AUTH_REQUIRED'
    )) {
        Add-ValidationIssue `
            -Issues $issues `
            -Issue 'terminal-comparison-failure-classification'
    }
    if ($status -ceq 'BLOCKED_NOT_RUN' -and @(
        $declaredFailures | Where-Object {
            [string]$_ -cne 'AUTH_REQUIRED'
        }
    ).Count -eq 0) {
        Add-ValidationIssue `
            -Issues $issues `
            -Issue 'terminal-comparison-failure-classification'
    }

    if ($status -eq 'COMPLETE') {
        if ($null -eq $comparisonRepoRoot) {
            Add-ValidationIssue -Issues $issues -Issue 'side-run-manifests'
        }
        else {
            $expectedMatrix = Get-ExpectedScenarioMatrix -RepoRoot $comparisonRepoRoot
            $expectedKeys = [System.Collections.Generic.HashSet[string]]::new(
                [StringComparer]::OrdinalIgnoreCase
            )
            foreach ($entry in $expectedMatrix.GetEnumerator()) {
                foreach ($scenarioId in $entry.Value.Scenarios.Keys) {
                    [void]$expectedKeys.Add("$($entry.Key)/$scenarioId")
                }
            }
            if ($comparisonKeys.Count -ne $expectedKeys.Count) {
                Add-ValidationIssue -Issues $issues -Issue 'comparison-scenario-matrix'
            }
            foreach ($key in $expectedKeys) {
                if (-not $comparisonKeys.Contains($key)) {
                    Add-ValidationIssue -Issues $issues -Issue 'comparison-scenario-matrix'
                    break
                }
            }
            foreach ($comparison in $comparisons) {
                $matrixCaseId = [string](
                    Get-PropertyValue `
                        -InputObject $comparison `
                        -Name 'caseId' `
                        -DefaultValue ''
                )
                $matrixScenarioId = [string](
                    Get-PropertyValue `
                        -InputObject $comparison `
                        -Name 'scenarioId' `
                        -DefaultValue ''
                )
                $matrixPermissionMode = [string](
                    Get-PropertyValue `
                        -InputObject $comparison `
                        -Name 'permissionMode' `
                        -DefaultValue ''
                )
                if (-not $expectedMatrix.Contains($matrixCaseId) -or
                    -not $expectedMatrix[$matrixCaseId].Scenarios.Contains($matrixScenarioId) -or
                    [string]$expectedMatrix[$matrixCaseId].Scenarios[$matrixScenarioId] -cne
                        $matrixPermissionMode) {
                    Add-ValidationIssue -Issues $issues -Issue 'comparison-scenario-matrix'
                }
            }
        }
        if ($mismatches.Count -gt 0) {
            Add-ValidationIssue -Issues $issues -Issue 'unlabelled-comparison-mismatch'
        }
        if ($declaredFailures.Count -ne 0) {
            Add-ValidationIssue -Issues $issues -Issue 'complete-comparison-has-failures'
        }
    }
    elseif ($status -eq 'INVALID_COMPARISON') {
        if ($mismatches.Count -eq 0) {
            Add-ValidationIssue -Issues $issues -Issue 'invalid-comparison-without-mismatch'
        }
        elseif (-not (Test-StringSetEqual -Left @($declaredFailures) -Right @($mismatches))) {
            Add-ValidationIssue -Issues $issues -Issue 'comparison-failure-labels'
        }
    }

    $recommendedStatus = if ($mismatches.Count -gt 0) {
        'INVALID_COMPARISON'
    }
    elseif ($issues.Count -gt 0) {
        'BLOCKED_NOT_RUN'
    }
    else {
        $status
    }
    return [pscustomobject] [ordered]@{
        SchemaVersion = 1
        Kind = 'meecho-eval-comparison'
        Valid = $issues.Count -eq 0
        Complete = ($issues.Count -eq 0 -and $status -eq 'COMPLETE')
        Status = $status
        RecommendedStatus = $recommendedStatus
        Failures = @($issues)
        Mismatches = @($mismatches | Sort-Object)
    }
}

$result = $null
try {
    $fullManifestPath = [System.IO.Path]::GetFullPath($ManifestPath)
    Assert-MeechoNoReparsePoint -Path $fullManifestPath
    if (-not (Test-Path -LiteralPath $fullManifestPath -PathType Leaf)) {
        throw 'ManifestPath does not identify a file.'
    }
    $raw = Get-Content -LiteralPath $fullManifestPath -Raw -Encoding UTF8
    if ($raw -match '(?i)auth\.json' -or $raw -match '(?i)"environment"\s*:\s*\{') {
        throw 'Manifest contains a forbidden sensitive field.'
    }
    $manifest = $raw | ConvertFrom-Json -Depth 50
    $kind = [string] (Get-PropertyValue -InputObject $manifest -Name 'kind' -DefaultValue '')
    $result = switch ($kind) {
        'meecho-eval-run' {
            Test-RunManifest -Manifest $manifest -Path $fullManifestPath
            break
        }
        'meecho-eval-comparison' {
            Test-ComparisonManifest -Manifest $manifest -Path $fullManifestPath
            break
        }
        default {
            [pscustomobject] [ordered]@{
                SchemaVersion = 1
                Kind = $kind
                Valid = $false
                Complete = $false
                Status = [string] (
                    Get-PropertyValue -InputObject $manifest -Name 'status' -DefaultValue 'UNKNOWN'
                )
                RecommendedStatus = 'BLOCKED_NOT_RUN'
                Failures = @('kind')
            }
        }
    }
}
catch {
    $result = [pscustomobject] [ordered]@{
        SchemaVersion = 1
        Kind = 'unknown'
        Valid = $false
        Complete = $false
        Status = 'UNKNOWN'
        RecommendedStatus = 'BLOCKED_NOT_RUN'
        Failures = @($_.Exception.Message)
    }
}

Write-Output ($result | ConvertTo-Json -Depth 20 -Compress)
if ($PassThru -or $MyInvocation.InvocationName -ceq '.') {
    return
}
if ($result.Valid) {
    exit 0
}
exit 1
