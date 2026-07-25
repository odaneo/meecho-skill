Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$script:SyntheticCorpusRoot = [System.IO.Path]::GetFullPath(
    (Join-Path $script:RepoRoot 'evals/fixtures/synthetic-corpus')
)
$script:SealedCorpusRoot = [System.IO.Path]::GetFullPath(
    (Join-Path $script:SyntheticCorpusRoot 'sealed')
)
$script:ProfileFixtureKinds = @(
    'none',
    'standard',
    'preferences',
    'publication',
    'schema-unknown',
    'schema-old',
    'deletable'
)

function Get-MeechoCanonicalPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'A filesystem path cannot be empty.'
    }

    try {
        return [System.IO.Path]::GetFullPath($Path)
    }
    catch {
        throw "Invalid filesystem path '$Path': $($_.Exception.Message)"
    }
}

function Test-MeechoPathWithin {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Root
    )

    $candidate = Get-MeechoCanonicalPath -Path $Path
    $boundary = Get-MeechoCanonicalPath -Path $Root
    $prefix = $boundary.TrimEnd([char[]]@('\', '/')) + [System.IO.Path]::DirectorySeparatorChar

    return (
        $candidate.Equals($boundary, [System.StringComparison]::OrdinalIgnoreCase) -or
        $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
    )
}

function Assert-MeechoNoReparsePoint {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $current = Get-MeechoCanonicalPath -Path $Path
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse points are not allowed in evaluation staging paths: $current"
            }
        }

        $parent = [System.IO.Directory]::GetParent($current)
        if ($null -eq $parent) {
            break
        }

        $next = $parent.FullName
        if ($next.Equals($current, [System.StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $current = $next
    }
}

function Assert-MeechoSafeRelativePath {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$Label cannot be empty."
    }
    if ([System.IO.Path]::IsPathRooted($Path)) {
        throw "$Label must be relative: $Path"
    }

    $segments = @($Path -split '[\\/]')
    if ($segments.Count -eq 0 -or $segments -contains '' -or $segments -contains '.' -or $segments -contains '..') {
        throw "$Label contains an unsafe path segment: $Path"
    }
}

function Resolve-MeechoAccessibleSource {
    param(
        [Parameter(Mandatory)]
        [string]$Source
    )

    Assert-MeechoSafeRelativePath -Path $Source -Label 'accessibleFiles.source'
    $nativeRelative = $Source.Replace(
        [System.IO.Path]::AltDirectorySeparatorChar,
        [System.IO.Path]::DirectorySeparatorChar
    )
    $resolved = Get-MeechoCanonicalPath -Path (Join-Path $script:SyntheticCorpusRoot $nativeRelative)

    if (-not (Test-MeechoPathWithin -Path $resolved -Root $script:SyntheticCorpusRoot)) {
        throw "Accessible fixture escapes the synthetic corpus: $Source"
    }
    if (Test-MeechoPathWithin -Path $resolved -Root $script:SealedCorpusRoot) {
        throw "Sealed fixtures cannot be staged as accessible input: $Source"
    }
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "Accessible fixture does not exist: $Source"
    }

    Assert-MeechoNoReparsePoint -Path $resolved
    return $resolved
}

function Set-MeechoFixtureFile {
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string]$RelativePath,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Content
    )

    Assert-MeechoSafeRelativePath -Path $RelativePath -Label 'profile fixture path'
    $nativeRelative = $RelativePath.Replace(
        [System.IO.Path]::AltDirectorySeparatorChar,
        [System.IO.Path]::DirectorySeparatorChar
    )
    $destination = Get-MeechoCanonicalPath -Path (Join-Path $Root $nativeRelative)
    if (-not (Test-MeechoPathWithin -Path $destination -Root $Root)) {
        throw "Profile fixture path escapes its root: $RelativePath"
    }
    Assert-MeechoNoReparsePoint -Path $destination

    $parent = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Assert-MeechoNoReparsePoint -Path $parent
    Set-Content -LiteralPath $destination -Value $Content -Encoding UTF8 -NoNewline
}

function Initialize-MeechoSyntheticProfileFixture {
    param(
        [Parameter(Mandatory)]
        [string]$ScenarioUserHome,

        [Parameter(Mandatory)]
        [ValidateSet(
            'standard',
            'preferences',
            'publication',
            'schema-unknown',
            'schema-old',
            'deletable'
        )]
        [string]$Kind
    )

    $meechoRoot = Get-MeechoCanonicalPath -Path (Join-Path $ScenarioUserHome '.meecho')
    if (-not (Test-MeechoPathWithin -Path $meechoRoot -Root $ScenarioUserHome)) {
        throw 'Synthetic profile root escapes ScenarioUserHome.'
    }
    Assert-MeechoNoReparsePoint -Path $meechoRoot
    if (Test-Path -LiteralPath $meechoRoot) {
        throw "Synthetic profile root must not already exist: $meechoRoot"
    }

    New-Item -ItemType Directory -Path $meechoRoot | Out-Null

    if ($Kind -in @('schema-unknown', 'schema-old')) {
        $profileId = $Kind
        $schemaVersion = if ($Kind -eq 'schema-unknown') { 999 } else { 0 }
        $displayName = if ($Kind -eq 'schema-unknown') {
            '未知版本测试档案'
        }
        else {
            '旧版本测试档案'
        }
        $config = [ordered]@{
            schema_version = 1
            active_profile = $profileId
            profiles = [ordered]@{
                $profileId = [ordered]@{
                    display_name = $displayName
                    relative_path = "profiles/$profileId"
                }
            }
        } | ConvertTo-Json -Depth 10
        $manifest = [ordered]@{
            schema_version = $schemaVersion
            profile_id = $profileId
            display_name = $displayName
            status = 'blocked'
        } | ConvertTo-Json -Depth 10
        Set-MeechoFixtureFile -Root $meechoRoot -RelativePath 'config.json' -Content $config
        Set-MeechoFixtureFile `
            -Root $meechoRoot `
            -RelativePath "profiles/$profileId/manifest.json" `
            -Content $manifest
        return $meechoRoot
    }

    Set-MeechoFixtureFile -Root $meechoRoot -RelativePath 'config.json' -Content @'
{
  "schema_version": 1,
  "active_profile": "high-school",
  "profiles": {
    "high-school": {
      "display_name": "高中声音",
      "relative_path": "profiles/high-school"
    }
  }
}
'@
    Set-MeechoFixtureFile -Root $meechoRoot -RelativePath 'profiles/high-school/manifest.json' -Content @'
{
  "schema_version": 1,
  "profile_id": "high-school",
  "display_name": "高中声音",
  "status": "active",
  "created_at": "2026-01-01T00:00:00Z",
  "updated_at": "2026-01-01T00:00:00Z",
  "contains_raw_corpus": false,
  "contains_selected_excerpts": true,
  "source_counts": {
    "high_school_works": 3,
    "adult_contrast_works": 1,
    "sealed_work_families": 0
  }
}
'@
    Set-MeechoFixtureFile -Root $meechoRoot -RelativePath 'profiles/high-school/style-profile.md' -Content @'
# Style Profile

## Scope

仅用于完全虚构的 Task 1 合成语料。

## High-confidence claims

- 常把物件动作放在解释之前；证据来自 family-01 与 family-02。
- 结尾回到先前出现的物件；证据来自 family-02 与 family-03。

## Conditional claims

- 第一人称适合独处场景；群体场景可以使用“我们”。

## Counterexamples

- 题材名词只出现一次时不视为风格规则。

## Anti-style tendencies

- 不把成年时期新增词汇自动判为错误。

## Open questions

- 长篇结构尚未验证。
'@
    Set-MeechoFixtureFile -Root $meechoRoot -RelativePath 'profiles/high-school/attention-lens.md' -Content @'
# Attention Lens

## What the past self notices

先注意细小物件与声音。

## What the past self leaves unexplained

情绪通常通过动作间接呈现。

## Metaphor habits

比喻短，并与当前场景中的物件相连。

## Authority and uncertainty

避免替人物下最终结论。

## Emotional distance

保持一小步观察距离。
'@
    Set-MeechoFixtureFile -Root $meechoRoot -RelativePath 'profiles/high-school/voices.md' -Content @'
# Voices

## Default voice

克制的第一人称观察。

## Alternate voices

群体场景使用“我们”。

## Selection rules

按用户任务与场景选择，不按题材词机械匹配。

## Conflicts and boundaries

成年对照只描述时期差异，不覆盖历史证据。
'@
    Set-MeechoFixtureFile -Root $meechoRoot -RelativePath 'profiles/high-school/exemplars.jsonl' -Content @'
{"schema_version":1,"excerpt_id":"ex-synthetic-001","work_id":"synthetic-hs-01","family_id":"family-01","voice_id":"default","narrative_function":"进入场景","features":["物件观察","解释延迟"],"source_locator":"合成段落-1","text":"风先碰了一下空椅子。"}
{"schema_version":1,"excerpt_id":"ex-synthetic-002","work_id":"synthetic-hs-03","family_id":"family-03","voice_id":"collective","narrative_function":"收束场景","features":["物件回返","克制"],"source_locator":"合成段落-2","text":"我们把旧哨子放回抽屉。"}
'@
    Set-MeechoFixtureFile -Root $meechoRoot -RelativePath 'profiles/high-school/preferences.md' -Content @'
# Current Preferences

## Explicitly remembered preferences

- 暂无。

## Explicitly rejected tendencies

- 暂无。

## Separation from historical evidence

当前偏好不能改写历史风格证据。
'@

    if ($Kind -eq 'publication') {
        Set-MeechoFixtureFile -Root $meechoRoot -RelativePath 'profiles/high-school/publication-manifest.json' -Content @'
{
  "schema_version": 1,
  "example_id": null,
  "owner_approved": false,
  "contains_raw_corpus": false,
  "contains_original_excerpts": false,
  "derived_with_model": true,
  "included_in_plugin": false,
  "published_files": []
}
'@
    }

    if ($Kind -eq 'deletable') {
        Set-MeechoFixtureFile -Root $meechoRoot -RelativePath 'backups/high-school/20260101T000000Z/manifest.json' -Content @'
{
  "schema_version": 1,
  "profile_id": "high-school",
  "display_name": "高中声音",
  "status": "backup",
  "created_at": "2026-01-01T00:00:00Z",
  "updated_at": "2026-01-01T00:00:00Z",
  "contains_raw_corpus": false,
  "contains_selected_excerpts": true,
  "source_counts": {
    "high_school_works": 3,
    "adult_contrast_works": 1,
    "sealed_work_families": 0
  }
}
'@
    }

    return $meechoRoot
}

function Get-MeechoEvalCaseDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $casePath = Get-MeechoCanonicalPath -Path $Path
    if (-not (Test-Path -LiteralPath $casePath -PathType Leaf)) {
        throw "Evaluation case does not exist: $casePath"
    }
    Assert-MeechoNoReparsePoint -Path $casePath

    $text = Get-Content -LiteralPath $casePath -Raw -Encoding UTF8
    $matches = [regex]::Matches(
        $text,
        '(?s)<!--\s*meecho-eval\s*(?<json>\{.*?\})\s*-->'
    )
    if ($matches.Count -ne 1) {
        throw "Evaluation case must contain exactly one meecho-eval JSON metadata block: $casePath"
    }

    try {
        $metadata = $matches[0].Groups['json'].Value | ConvertFrom-Json -Depth 30
    }
    catch {
        throw "Invalid meecho-eval JSON metadata in '$casePath': $($_.Exception.Message)"
    }

    $propertyNames = @($metadata.PSObject.Properties.Name)
    if ($propertyNames -notcontains 'caseId' -or [string]::IsNullOrWhiteSpace([string]$metadata.caseId)) {
        throw "Evaluation case metadata is missing caseId: $casePath"
    }
    $caseId = [string]$metadata.caseId
    if ($caseId -notmatch '^case-\d{2}$') {
        throw "Evaluation case id must match case-NN: $caseId"
    }

    if ($propertyNames -notcontains 'scenarios') {
        throw "Evaluation case metadata is missing scenarios: $casePath"
    }
    $scenarioMetadata = @($metadata.scenarios)
    if ($scenarioMetadata.Count -eq 0) {
        throw "Evaluation case must declare at least one scenario: $casePath"
    }

    $scenarioIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $scenarios = [System.Collections.Generic.List[object]]::new()
    foreach ($scenario in $scenarioMetadata) {
        if ($null -eq $scenario) {
            throw "Evaluation case contains an empty scenario declaration: $casePath"
        }
        $scenarioProperties = @($scenario.PSObject.Properties.Name)
        if ($scenarioProperties -notcontains 'id' -or $scenarioProperties -notcontains 'permissionMode') {
            throw "Every scenario needs id and permissionMode: $casePath"
        }

        $scenarioId = [string]$scenario.id
        $permissionMode = [string]$scenario.permissionMode
        if ($scenarioId -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
            throw "Scenario id must be a lowercase stable slug: $scenarioId"
        }
        if ($permissionMode -notin @('read', 'allow', 'deny')) {
            throw "Unsupported permission mode '$permissionMode' in $casePath"
        }
        if (-not $scenarioIds.Add($scenarioId)) {
            throw "Duplicate scenario id '$scenarioId' in $casePath"
        }

        $initialState = 'default'
        if ($scenarioProperties -contains 'initialState' -and
            -not [string]::IsNullOrWhiteSpace([string]$scenario.initialState)) {
            $initialState = [string]$scenario.initialState
        }
        if ($initialState -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
            throw "Scenario initialState must be a lowercase stable slug: $initialState"
        }

        $scenarioPrompt = $null
        if ($scenarioProperties -contains 'prompt' -and
            -not [string]::IsNullOrWhiteSpace([string]$scenario.prompt)) {
            $scenarioPrompt = [string]$scenario.prompt
        }

        $scenarioProfileFixture = $null
        if ($scenarioProperties -contains 'profileFixture' -and
            -not [string]::IsNullOrWhiteSpace([string]$scenario.profileFixture)) {
            $scenarioProfileFixture = [string]$scenario.profileFixture
            if ($scenarioProfileFixture -notin $script:ProfileFixtureKinds) {
                throw "Unsupported scenario profileFixture '$scenarioProfileFixture' in $casePath"
            }
        }

        $scenarios.Add([pscustomobject]@{
            Id             = $scenarioId
            PermissionMode = $permissionMode
            InitialState   = $initialState
            ProfileFixture = $scenarioProfileFixture
            Prompt         = $scenarioPrompt
        })
    }

    $accessibleMetadata = @()
    if ($propertyNames -contains 'accessibleFiles' -and $null -ne $metadata.accessibleFiles) {
        $accessibleMetadata = @($metadata.accessibleFiles)
    }

    $destinations = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $accessibleFiles = [System.Collections.Generic.List[object]]::new()
    foreach ($file in $accessibleMetadata) {
        if ($null -eq $file) {
            throw "Evaluation case contains an empty accessible file declaration: $casePath"
        }
        $fileProperties = @($file.PSObject.Properties.Name)
        if ($fileProperties -notcontains 'source' -or $fileProperties -notcontains 'destination') {
            throw "Every accessible file needs source and destination: $casePath"
        }

        $source = [string]$file.source
        $destination = [string]$file.destination
        Assert-MeechoSafeRelativePath -Path $destination -Label 'accessibleFiles.destination'
        $destinationKey = $destination.Replace('\', '/')
        if ($destinationKey -eq '.git' -or $destinationKey.StartsWith('.git/', [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Accessible file destination cannot target Git metadata: $destination"
        }
        if (-not $destinations.Add($destinationKey)) {
            throw "Duplicate accessible file destination '$destination' in $casePath"
        }

        $sourcePath = Resolve-MeechoAccessibleSource -Source $source
        $accessibleFiles.Add([pscustomobject]@{
            Source      = $source
            SourcePath  = $sourcePath
            Destination = $destinationKey
        })
    }

    $projectRootMetadata = @()
    if ($propertyNames -contains 'projectRoots' -and $null -ne $metadata.projectRoots) {
        $projectRootMetadata = @($metadata.projectRoots)
    }
    $projectRootKeys = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $projectRoots = [System.Collections.Generic.List[string]]::new()
    foreach ($projectRoot in $projectRootMetadata) {
        $relativeProjectRoot = [string]$projectRoot
        Assert-MeechoSafeRelativePath -Path $relativeProjectRoot -Label 'projectRoots'
        $projectRootKey = $relativeProjectRoot.Replace('\', '/').TrimEnd('/')
        if ($projectRootKey -eq '.git' -or $projectRootKey.StartsWith('.git/', [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Project root cannot target Git metadata: $relativeProjectRoot"
        }
        if (-not $projectRootKeys.Add($projectRootKey)) {
            throw "Duplicate project root '$relativeProjectRoot' in $casePath"
        }
        $projectRoots.Add($projectRootKey)
    }

    $profileFixture = 'none'
    if ($propertyNames -contains 'profileFixture' -and $null -ne $metadata.profileFixture) {
        $profileFixture = [string]$metadata.profileFixture
    }
    if ($profileFixture -notin $script:ProfileFixtureKinds) {
        throw "Unsupported profileFixture '$profileFixture' in $casePath"
    }

    $invocationMetadata = @()
    if ($propertyNames -contains 'invocations' -and $null -ne $metadata.invocations) {
        $invocationMetadata = @($metadata.invocations)
    }
    $invocationIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $invocations = [System.Collections.Generic.List[object]]::new()
    foreach ($invocation in $invocationMetadata) {
        if ($null -eq $invocation) {
            throw "Evaluation case contains an empty invocation declaration: $casePath"
        }
        $invocationProperties = @($invocation.PSObject.Properties.Name)
        if ($invocationProperties -notcontains 'id' -or $invocationProperties -notcontains 'prompt') {
            throw "Every invocation needs id and prompt: $casePath"
        }

        $invocationId = [string]$invocation.id
        $invocationPrompt = [string]$invocation.prompt
        if ($invocationId -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
            throw "Invocation id must be a lowercase stable slug: $invocationId"
        }
        if (-not $invocationIds.Add($invocationId)) {
            throw "Duplicate invocation id '$invocationId' in $casePath"
        }
        if ([string]::IsNullOrWhiteSpace($invocationPrompt)) {
            throw "Invocation prompt cannot be empty: $invocationId"
        }

        $invocationProjectRoot = $null
        if ($invocationProperties -contains 'projectRoot' -and
            -not [string]::IsNullOrWhiteSpace([string]$invocation.projectRoot)) {
            $invocationProjectRoot = ([string]$invocation.projectRoot).Replace('\', '/').TrimEnd('/')
            Assert-MeechoSafeRelativePath -Path $invocationProjectRoot -Label 'invocations.projectRoot'
            if (-not $projectRootKeys.Contains($invocationProjectRoot)) {
                throw "Invocation '$invocationId' references undeclared project root '$invocationProjectRoot'."
            }
        }

        $invocations.Add([pscustomobject]@{
            Id          = $invocationId
            Prompt      = $invocationPrompt
            ProjectRoot = $invocationProjectRoot
        })
    }

    $sections = [ordered]@{}
    foreach ($sectionName in @(
        'User request',
        'Accessible files',
        'Forbidden state',
        'Observable assertions'
    )) {
        $sectionMatch = [regex]::Match(
            $text,
            "(?ms)^## $([regex]::Escape($sectionName))\s*\r?\n(?<body>.*?)(?=^##\s|\z)"
        )
        if (-not $sectionMatch.Success -or [string]::IsNullOrWhiteSpace($sectionMatch.Groups['body'].Value)) {
            throw "Evaluation case has no $sectionName body: $casePath"
        }
        $sections[$sectionName] = $sectionMatch.Groups['body'].Value.Trim()
    }

    return [pscustomobject]@{
        Path                 = $casePath
        CaseId               = $caseId
        Scenarios            = @($scenarios)
        AccessibleFiles      = @($accessibleFiles)
        ProjectRoots         = @($projectRoots)
        ProfileFixture       = $profileFixture
        Invocations          = @($invocations)
        UserRequest          = $sections['User request']
        AccessibleBoundary   = $sections['Accessible files']
        ForbiddenState       = $sections['Forbidden state']
        ObservableAssertions = $sections['Observable assertions']
    }
}

function Test-MeechoEvalCaseRegistry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Paths
    )

    if ($Paths.Count -eq 0) {
        throw 'At least one evaluation case path is required.'
    }

    $caseIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $matrixKeys = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $definitions = [System.Collections.Generic.List[object]]::new()
    $scenarioCount = 0

    foreach ($path in $Paths) {
        $definition = Get-MeechoEvalCaseDefinition -Path $path
        if (-not $caseIds.Add($definition.CaseId)) {
            throw "Duplicate case id '$($definition.CaseId)' in evaluation registry."
        }

        foreach ($scenario in $definition.Scenarios) {
            $matrixKey = "$($definition.CaseId)|$($scenario.Id)"
            if (-not $matrixKeys.Add($matrixKey)) {
                throw "Duplicate case/scenario pair '$matrixKey' in evaluation registry."
            }
            $scenarioCount++
        }
        $definitions.Add($definition)
    }

    return [pscustomobject]@{
        Passed        = $true
        Cases         = @($definitions)
        ScenarioCount = $scenarioCount
    }
}

function Invoke-MeechoGit {
    param(
        [Parameter(Mandatory)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $git = @(Get-Command git -CommandType Application -ErrorAction Stop)[0]
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $git.Path
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $systemRoot = [Environment]::GetEnvironmentVariable('SystemRoot', 'Process')
    if ([string]::IsNullOrWhiteSpace($systemRoot) -or
        -not (Test-Path -LiteralPath $systemRoot -PathType Container)) {
        throw 'SystemRoot is unavailable for the isolated Git process.'
    }
    $gitDirectory = Split-Path -Parent $git.Path
    $systemDirectory = Join-Path $systemRoot 'System32'
    $minimalPath = @($gitDirectory, $systemDirectory) |
        Select-Object -Unique |
        Join-String -Separator [System.IO.Path]::PathSeparator
    $tempDirectory = [Environment]::GetEnvironmentVariable('TEMP', 'Process')
    if ([string]::IsNullOrWhiteSpace($tempDirectory) -or
        -not (Test-Path -LiteralPath $tempDirectory -PathType Container)) {
        $tempDirectory = [System.IO.Path]::GetTempPath()
    }

    $startInfo.Environment.Clear()
    $startInfo.Environment['SystemRoot'] = $systemRoot
    $startInfo.Environment['PATH'] = $minimalPath
    $startInfo.Environment['TEMP'] = $tempDirectory
    $startInfo.Environment['HOME'] = $WorkingDirectory
    $startInfo.Environment['GIT_CONFIG_NOSYSTEM'] = '1'
    $startInfo.Environment['GIT_CONFIG_GLOBAL'] = 'NUL'
    $startInfo.Environment['GIT_TERMINAL_PROMPT'] = '0'
    foreach ($argument in $Arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw 'Git process did not start.'
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $gitTimeoutMilliseconds = 30000
        if (-not $process.WaitForExit($gitTimeoutMilliseconds)) {
            try {
                $process.Kill($true)
            }
            catch {
                # The timeout remains authoritative even if the process exits
                # between WaitForExit and Kill.
            }
            [void]$process.WaitForExit(5000)
            throw "GIT_TIMEOUT: git $($Arguments -join ' ') exceeded $gitTimeoutMilliseconds ms (exit 124)."
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "git $($Arguments -join ' ') failed with exit code $($process.ExitCode): $($stderr.Trim())"
        }
        return $stdout.Trim()
    }
    finally {
        $process.Dispose()
    }
}

function Initialize-MeechoEvalScenario {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Context,

        [Parameter(Mandatory)]
        [string]$CasePath
    )

    $requiredContextFields = @(
        'CaseId',
        'ScenarioId',
        'PermissionMode',
        'RunRoot',
        'CaseRoot',
        'ScenarioRoot',
        'ScenarioUserHome',
        'ScenarioWorkspace',
        'StepLogRoot'
    )
    $contextProperties = @($Context.PSObject.Properties.Name)
    foreach ($field in $requiredContextFields) {
        if ($contextProperties -notcontains $field) {
            throw "Evaluation context is missing $field."
        }
    }

    $definition = Get-MeechoEvalCaseDefinition -Path $CasePath
    if ($definition.CaseId -cne [string]$Context.CaseId) {
        throw "Case metadata '$($definition.CaseId)' does not match context '$($Context.CaseId)'."
    }

    $scenarioMatches = @(
        $definition.Scenarios |
            Where-Object { $_.Id -ceq [string]$Context.ScenarioId }
    )
    if ($scenarioMatches.Count -ne 1) {
        throw "Scenario '$($Context.ScenarioId)' is not declared exactly once by $($definition.CaseId)."
    }
    $scenario = $scenarioMatches[0]
    if ($scenario.PermissionMode -cne [string]$Context.PermissionMode) {
        throw "Scenario permission '$($scenario.PermissionMode)' does not match context '$($Context.PermissionMode)'."
    }
    $effectiveProfileFixture = if (
        [string]::IsNullOrWhiteSpace([string]$scenario.ProfileFixture)
    ) {
        $definition.ProfileFixture
    }
    else {
        [string]$scenario.ProfileFixture
    }
    $effectiveUserRequest = if (
        [string]::IsNullOrWhiteSpace([string]$scenario.Prompt)
    ) {
        $definition.UserRequest
    }
    else {
        [string]$scenario.Prompt
    }

    $runRoot = Get-MeechoCanonicalPath -Path ([string]$Context.RunRoot)
    $caseRoot = Get-MeechoCanonicalPath -Path ([string]$Context.CaseRoot)
    $scenarioRoot = Get-MeechoCanonicalPath -Path ([string]$Context.ScenarioRoot)
    $scenarioUserHome = Get-MeechoCanonicalPath -Path ([string]$Context.ScenarioUserHome)
    $workspace = Get-MeechoCanonicalPath -Path ([string]$Context.ScenarioWorkspace)
    $stepLogRoot = Get-MeechoCanonicalPath -Path ([string]$Context.StepLogRoot)

    if (-not (Test-MeechoPathWithin -Path $caseRoot -Root $runRoot)) {
        throw 'CaseRoot escapes RunRoot.'
    }
    if (-not (Test-MeechoPathWithin -Path $scenarioRoot -Root $caseRoot)) {
        throw 'ScenarioRoot escapes CaseRoot.'
    }
    if (-not (Test-MeechoPathWithin -Path $workspace -Root $scenarioRoot)) {
        throw 'ScenarioWorkspace escapes ScenarioRoot.'
    }
    if (-not (Test-MeechoPathWithin -Path $scenarioUserHome -Root $scenarioRoot)) {
        throw 'ScenarioUserHome escapes ScenarioRoot.'
    }
    foreach ($path in @($runRoot, $caseRoot, $scenarioRoot, $scenarioUserHome, $workspace)) {
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            throw "Evaluation context directory does not exist: $path"
        }
        Assert-MeechoNoReparsePoint -Path $path
    }
    if (-not (Test-Path -LiteralPath $stepLogRoot -PathType Container)) {
        throw "StepLogRoot does not exist: $stepLogRoot"
    }
    Assert-MeechoNoReparsePoint -Path $stepLogRoot

    $promptPath = Get-MeechoCanonicalPath -Path (Join-Path $stepLogRoot 'prompt.md')
    if (-not (Test-MeechoPathWithin -Path $promptPath -Root $stepLogRoot)) {
        throw 'PromptPath escapes StepLogRoot.'
    }
    Assert-MeechoNoReparsePoint -Path $promptPath
    if (Test-Path -LiteralPath $promptPath) {
        throw "PromptPath already exists: $promptPath"
    }

    $existingItems = @(Get-ChildItem -LiteralPath $workspace -Force)
    foreach ($item in $existingItems) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Scenario workspace contains a reparse point: $($item.FullName)"
        }
    }
    if ($existingItems.Count -ne 0) {
        throw "Scenario workspace must be empty before staging: $workspace"
    }

    $meechoRoot = Get-MeechoCanonicalPath -Path (Join-Path $scenarioUserHome '.meecho')
    Assert-MeechoNoReparsePoint -Path $meechoRoot
    if (Test-Path -LiteralPath $meechoRoot) {
        throw "Scenario virtual profile root must be absent before staging: $meechoRoot"
    }

    $copyPlan = [System.Collections.Generic.List[object]]::new()
    foreach ($file in $definition.AccessibleFiles) {
        $nativeDestination = $file.Destination.Replace(
            [System.IO.Path]::AltDirectorySeparatorChar,
            [System.IO.Path]::DirectorySeparatorChar
        )
        $destinationPath = Get-MeechoCanonicalPath -Path (Join-Path $workspace $nativeDestination)
        if (-not (Test-MeechoPathWithin -Path $destinationPath -Root $workspace)) {
            throw "Accessible file destination escapes workspace: $($file.Destination)"
        }
        Assert-MeechoNoReparsePoint -Path $destinationPath

        $copyPlan.Add([pscustomobject]@{
            Source          = $file.Source
            SourcePath      = $file.SourcePath
            Destination     = $file.Destination
            DestinationPath = $destinationPath
        })
    }

    $projectPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($relativeProjectRoot in $definition.ProjectRoots) {
        $nativeProjectRoot = $relativeProjectRoot.Replace(
            [System.IO.Path]::AltDirectorySeparatorChar,
            [System.IO.Path]::DirectorySeparatorChar
        )
        $projectPath = Get-MeechoCanonicalPath -Path (Join-Path $workspace $nativeProjectRoot)
        if (-not (Test-MeechoPathWithin -Path $projectPath -Root $workspace)) {
            throw "Declared project root escapes workspace: $relativeProjectRoot"
        }
        Assert-MeechoNoReparsePoint -Path $projectPath
        $projectPaths.Add($projectPath)
    }

    foreach ($file in $copyPlan) {
        $destinationParent = Split-Path -Parent $file.DestinationPath
        if (-not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
            New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
        }
        Assert-MeechoNoReparsePoint -Path $destinationParent
        Copy-Item -LiteralPath $file.SourcePath -Destination $file.DestinationPath
    }

    [void](Invoke-MeechoGit -WorkingDirectory $workspace -Arguments @(
        '-c', 'core.hooksPath=NUL',
        'init', '--quiet'
    ))
    [void](Invoke-MeechoGit -WorkingDirectory $workspace -Arguments @(
        '-c', 'core.hooksPath=NUL',
        '-c', 'core.autocrlf=false',
        'add', '--all'
    ))
    [void](Invoke-MeechoGit -WorkingDirectory $workspace -Arguments @(
        '-c', 'core.hooksPath=NUL',
        '-c', 'user.name=Meecho Eval',
        '-c', 'user.email=meecho-eval@example.invalid',
        'commit', '--quiet', '--allow-empty',
        '-m', 'Meecho evaluation fixture'
    ))
    $commit = Invoke-MeechoGit -WorkingDirectory $workspace -Arguments @(
        '-c', 'core.hooksPath=NUL',
        'rev-parse', 'HEAD'
    )

    $projectCommits = [System.Collections.Generic.List[object]]::new()
    foreach ($projectPath in $projectPaths) {
        if (-not (Test-Path -LiteralPath $projectPath -PathType Container)) {
            New-Item -ItemType Directory -Path $projectPath | Out-Null
        }
        Assert-MeechoNoReparsePoint -Path $projectPath
        [void](Invoke-MeechoGit -WorkingDirectory $projectPath -Arguments @(
            '-c', 'core.hooksPath=NUL',
            'init', '--quiet'
        ))
        [void](Invoke-MeechoGit -WorkingDirectory $projectPath -Arguments @(
            '-c', 'core.hooksPath=NUL',
            '-c', 'core.autocrlf=false',
            'add', '--all'
        ))
        [void](Invoke-MeechoGit -WorkingDirectory $projectPath -Arguments @(
            '-c', 'core.hooksPath=NUL',
            '-c', 'user.name=Meecho Eval',
            '-c', 'user.email=meecho-eval@example.invalid',
            'commit', '--quiet', '--allow-empty',
            '-m', 'Meecho project fixture'
        ))
        $projectCommit = Invoke-MeechoGit -WorkingDirectory $projectPath -Arguments @(
            '-c', 'core.hooksPath=NUL',
            'rev-parse', 'HEAD'
        )
        $projectCommits.Add([pscustomobject]@{
            Path   = $projectPath
            Commit = $projectCommit
        })
    }

    if ($effectiveProfileFixture -ne 'none') {
        [void](Initialize-MeechoSyntheticProfileFixture `
            -ScenarioUserHome $scenarioUserHome `
            -Kind $effectiveProfileFixture)
    }

    Set-Content `
        -LiteralPath $promptPath `
        -Value $effectiveUserRequest `
        -Encoding UTF8 `
        -NoNewline

    $stagedInvocations = [System.Collections.Generic.List[object]]::new()
    foreach ($invocation in $definition.Invocations) {
        $invocationRoot = Get-MeechoCanonicalPath -Path (
            Join-Path $stepLogRoot (Join-Path 'invocations' $invocation.Id)
        )
        if (-not (Test-MeechoPathWithin -Path $invocationRoot -Root $stepLogRoot)) {
            throw "Invocation log root escapes StepLogRoot: $($invocation.Id)"
        }
        Assert-MeechoNoReparsePoint -Path $invocationRoot
        if (Test-Path -LiteralPath $invocationRoot) {
            throw "Invocation log root already exists: $invocationRoot"
        }
        New-Item -ItemType Directory -Path $invocationRoot -Force | Out-Null

        $invocationPromptPath = Get-MeechoCanonicalPath -Path (
            Join-Path $invocationRoot 'prompt.md'
        )
        if (-not (Test-MeechoPathWithin -Path $invocationPromptPath -Root $invocationRoot)) {
            throw "Invocation prompt escapes its log root: $($invocation.Id)"
        }
        Set-Content `
            -LiteralPath $invocationPromptPath `
            -Value $invocation.Prompt `
            -Encoding UTF8 `
            -NoNewline

        $invocationProjectPath = $workspace
        if (-not [string]::IsNullOrWhiteSpace([string]$invocation.ProjectRoot)) {
            $nativeProjectRoot = $invocation.ProjectRoot.Replace(
                [System.IO.Path]::AltDirectorySeparatorChar,
                [System.IO.Path]::DirectorySeparatorChar
            )
            $invocationProjectPath = Get-MeechoCanonicalPath -Path (
                Join-Path $workspace $nativeProjectRoot
            )
            if (-not (Test-MeechoPathWithin -Path $invocationProjectPath -Root $workspace) -or
                -not (Test-Path -LiteralPath $invocationProjectPath -PathType Container)) {
                throw "Invocation project root is unavailable: $($invocation.ProjectRoot)"
            }
        }

        $stagedInvocations.Add([pscustomobject]@{
            Id               = $invocation.Id
            Prompt           = $invocation.Prompt
            PromptPath       = $invocationPromptPath
            WorkingDirectory = $invocationProjectPath
            ProjectRoot      = $invocationProjectPath
        })
    }

    $stagedFiles = @(
        foreach ($file in $copyPlan) {
            [pscustomobject]@{
                Source          = $file.Source
                Destination     = $file.Destination
                DestinationPath = $file.DestinationPath
                Sha256         = (Get-FileHash -LiteralPath $file.DestinationPath -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
    )

    return [pscustomobject]@{
        CaseId          = $definition.CaseId
        ScenarioId      = $scenario.Id
        PermissionMode  = $scenario.PermissionMode
        InitialState    = $scenario.InitialState
        ProfileFixture  = $effectiveProfileFixture
        CasePath        = $definition.Path
        Workspace       = $workspace
        PromptPath      = $promptPath
        UserRequest     = $effectiveUserRequest
        AccessibleFiles = $stagedFiles
        GitCommit       = $commit
        ProjectRoots    = @($projectCommits | ForEach-Object Path)
        ProjectCommits  = @($projectCommits)
        Invocations     = @($stagedInvocations)
        ProfileRoot     = if ($effectiveProfileFixture -eq 'none') { $null } else { $meechoRoot }
    }
}

Export-ModuleMember -Function @(
    'Get-MeechoEvalCaseDefinition',
    'Test-MeechoEvalCaseRegistry',
    'Initialize-MeechoEvalScenario'
)
