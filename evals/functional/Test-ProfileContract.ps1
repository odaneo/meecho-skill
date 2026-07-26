[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$referencePath = Join-Path $repoRoot 'plugins\meecho\skills\meecho\references\profile-schema.md'
$fixturesRoot = Join-Path $repoRoot 'evals\fixtures\profile'
$validRoot = Join-Path $fixturesRoot 'valid'
$invalidRoot = Join-Path $fixturesRoot 'invalid'
$failures = [System.Collections.Generic.List[string]]::new()

function Test-Fact {
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [bool] $Condition,

        [Parameter(Mandatory)]
        [string] $FailureMessage
    )

    if ($Condition) {
        Write-Host "[PASS] $Name"
        return
    }

    Write-Host "[FAIL] $Name - $FailureMessage"
    $script:failures.Add($FailureMessage)
}

function Add-ContractError {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]] $Errors,

        [Parameter(Mandatory)]
        [string] $Code,

        [Parameter(Mandatory)]
        [string] $Detail
    )

    $Errors.Add("$Code|$Detail")
}

function Read-JsonObject {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]] $Errors,

        [Parameter(Mandatory)]
        [string] $Code
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Add-ContractError $Errors $Code "缺少文件：$Path"
        return $null
    }

    try {
        return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        Add-ContractError $Errors $Code "JSON 无效：$Path"
        return $null
    }
}

function Test-ProfileFixture {
    param(
        [Parameter(Mandatory)]
        [string] $FixtureRoot
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $configPath = Join-Path $FixtureRoot 'config.json'
    $config = Read-JsonObject $configPath $errors 'config.json'
    if ($null -eq $config) {
        return @($errors)
    }

    if ($config.schema -ne 1) {
        Add-ContractError $errors 'config.schema' 'config.json 的 schema 必须为 1。'
    }
    $unknownConfigFields = @(
        $config.PSObject.Properties.Name |
            Where-Object { $_ -notin @('schema', 'active_profile_id') }
    )
    if ($unknownConfigFields.Count -gt 0) {
        Add-ContractError $errors 'config.fields' 'config.json 包含未定义字段。'
    }

    $profileId = $config.active_profile_id
    $safeId = (
        $profileId -is [string] -and
        $profileId -cmatch '^[a-z0-9][a-z0-9-]{0,62}$'
    )
    if (-not $safeId) {
        Add-ContractError $errors 'config.active_profile_id' 'active_profile_id 不是安全的 profile ID。'
        return @($errors)
    }

    $profilesRoot = Join-Path $FixtureRoot 'profiles'
    $profileRoot = Join-Path $profilesRoot $profileId
    $profilesRootFull = [IO.Path]::GetFullPath($profilesRoot)
    $profileRootFull = [IO.Path]::GetFullPath($profileRoot)
    if (-not $profileRootFull.StartsWith(
        $profilesRootFull + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        Add-ContractError $errors 'profile.path' '活动档案路径越过 profiles 目录。'
        return @($errors)
    }

    if (-not (Test-Path -LiteralPath $profileRoot -PathType Container)) {
        Add-ContractError $errors 'profile.directory' '活动档案目录不存在。'
        return @($errors)
    }
    $profileDirectory = Get-Item -LiteralPath $profileRoot -Force
    if ($profileDirectory.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        Add-ContractError $errors 'profile.reparse_point' '活动档案目录不得是链接或重解析点。'
        return @($errors)
    }

    $requiredProfileFiles = @(
        'manifest.json',
        'style-profile.md',
        'attention-lens.md',
        'voices.md',
        'exemplars.jsonl',
        'preferences.md'
    )
    foreach ($fileName in $requiredProfileFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $profileRoot $fileName) -PathType Leaf)) {
            Add-ContractError $errors 'profile.required_file' "缺少档案文件：$fileName"
        }
    }

    $manifest = Read-JsonObject (Join-Path $profileRoot 'manifest.json') $errors 'manifest.json'
    if ($null -ne $manifest) {
        if ($manifest.schema -ne 1) {
            Add-ContractError $errors 'manifest.schema' 'manifest.json 的 schema 必须为 1。'
        }
        if ($manifest.profile_id -cne $profileId) {
            Add-ContractError $errors 'manifest.profile_id' 'manifest.json 的 profile_id 与目录名不一致。'
        }
        $unknownManifestFields = @(
            $manifest.PSObject.Properties.Name |
                Where-Object {
                    $_ -notin @(
                        'schema',
                        'profile_id',
                        'created_at',
                        'updated_at',
                        'source_counts'
                    )
                }
        )
        if ($unknownManifestFields.Count -gt 0) {
            Add-ContractError $errors 'manifest.fields' 'manifest.json 包含未定义字段。'
        }
        foreach ($field in @('created_at', 'updated_at')) {
            $value = $manifest.$field
            $isUtcTimestamp = if ($value -is [datetime]) {
                $value.Kind -eq [DateTimeKind]::Utc
            }
            elseif ($value -is [string]) {
                $parsed = [DateTimeOffset]::MinValue
                $value.EndsWith('Z') -and
                    [DateTimeOffset]::TryParse($value, [ref] $parsed)
            }
            else {
                $false
            }
            if (-not $isUtcTimestamp) {
                Add-ContractError $errors "manifest.$field" "$field 必须是 UTC 时间。"
            }
        }
        $sourceCounts = $manifest.source_counts
        foreach ($field in @('target_works', 'contrast_works')) {
            $value = if ($null -ne $sourceCounts) {
                $sourceCounts.$field
            }
            else {
                $null
            }
            if (
                $value -isnot [int] -and
                $value -isnot [long] -or
                $value -lt 0
            ) {
                Add-ContractError $errors "manifest.source_counts.$field" "$field 必须是非负整数。"
            }
        }
    }

    $requiredHeadings = @{
        'style-profile.md' = @('## 已确认规律', '## 反例与边界', '## 不确定结论')
        'attention-lens.md' = @('## 关注对象', '## 观察方式')
        'voices.md' = @('## 目标声音', '## 对照观察')
        'preferences.md' = @('## 用户明确偏好', '## 用户明确反感')
    }
    foreach ($fileName in $requiredHeadings.Keys) {
        $path = Join-Path $profileRoot $fileName
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            continue
        }
        $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        foreach ($heading in $requiredHeadings[$fileName]) {
            if (-not $text.Contains($heading)) {
                Add-ContractError $errors 'markdown.section' "$fileName 缺少章节：$heading"
            }
        }
    }

    $exemplarsPath = Join-Path $profileRoot 'exemplars.jsonl'
    if (Test-Path -LiteralPath $exemplarsPath -PathType Leaf) {
        $ids = [System.Collections.Generic.HashSet[string]]::new(
            [StringComparer]::Ordinal
        )
        $lineNumber = 0
        foreach ($line in Get-Content -LiteralPath $exemplarsPath -Encoding UTF8) {
            $lineNumber++
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }
            try {
                $record = $line | ConvertFrom-Json
            }
            catch {
                Add-ContractError $errors 'exemplar.json' "第 $lineNumber 行不是合法 JSON。"
                continue
            }

            if ($record.category -notin @('target_evidence', 'counterexample')) {
                Add-ContractError $errors 'exemplar.category' "第 $lineNumber 行的 category 无效。"
            }
            if (
                $record.id -isnot [string] -or
                $record.id -cnotmatch '^[a-z0-9][a-z0-9-]{0,63}$' -or
                -not $ids.Add($record.id)
            ) {
                Add-ContractError $errors 'exemplar.id' "第 $lineNumber 行的 id 无效或重复。"
            }
            if (
                $record.excerpt -isnot [string] -or
                [string]::IsNullOrWhiteSpace($record.excerpt) -or
                $record.excerpt.Length -gt 120
            ) {
                Add-ContractError $errors 'exemplar.excerpt' "第 $lineNumber 行必须包含不超过 120 字的短例句。"
            }
            foreach ($field in @('work_id', 'note')) {
                if (
                    $record.$field -isnot [string] -or
                    [string]::IsNullOrWhiteSpace($record.$field)
                ) {
                    Add-ContractError $errors "exemplar.$field" "第 $lineNumber 行缺少 $field。"
                }
            }
        }
    }

    return @($errors)
}

Write-Host 'Meecho profile contract test'
Write-Host "Repository: $repoRoot"

Test-Fact '中文档案 schema 参考文件存在' (
    Test-Path -LiteralPath $referencePath -PathType Leaf
) "缺少文件：$referencePath"

$validFixtures = if (Test-Path -LiteralPath $validRoot -PathType Container) {
    @(Get-ChildItem -LiteralPath $validRoot -Directory)
}
else {
    @()
}
$invalidFixtures = if (Test-Path -LiteralPath $invalidRoot -PathType Container) {
    @(Get-ChildItem -LiteralPath $invalidRoot -Directory)
}
else {
    @()
}

Test-Fact '至少存在一个合法 fixture' ($validFixtures.Count -gt 0) "目录为空：$validRoot"
Test-Fact '至少存在一个非法 fixture' ($invalidFixtures.Count -gt 0) "目录为空：$invalidRoot"

foreach ($fixture in $validFixtures) {
    $errors = @(Test-ProfileFixture -FixtureRoot $fixture.FullName)
    Test-Fact "合法 fixture 通过：$($fixture.Name)" (
        $errors.Count -eq 0
    ) ("错误：" + ($errors -join '; '))
}

foreach ($fixture in $invalidFixtures) {
    $expectedPath = Join-Path $fixture.FullName 'expected-errors.json'
    $expectationErrors = [System.Collections.Generic.List[string]]::new()
    $expected = Read-JsonObject $expectedPath $expectationErrors 'fixture.expected_errors'
    $actualErrors = @(Test-ProfileFixture -FixtureRoot $fixture.FullName)
    $actualCodes = @(
        $actualErrors |
            ForEach-Object { ($_ -split '\|', 2)[0] }
    )
    $expectedCodes = if ($null -ne $expected) {
        @($expected.contains)
    }
    else {
        @()
    }
    $missingExpectedCodes = @(
        $expectedCodes |
            Where-Object { $_ -notin $actualCodes }
    )
    Test-Fact "非法 fixture 被拒绝：$($fixture.Name)" (
        $expectationErrors.Count -eq 0 -and
        $actualErrors.Count -gt 0 -and
        $expectedCodes.Count -gt 0 -and
        $missingExpectedCodes.Count -eq 0
    ) ("实际错误：" + ($actualErrors -join '; '))
}

$pluginRoot = Join-Path $repoRoot 'plugins\meecho'
$privateProfileNames = @(
    'config.json',
    'manifest.json',
    'style-profile.md',
    'attention-lens.md',
    'voices.md',
    'exemplars.jsonl',
    'preferences.md'
)
$privateFilesInPlugin = @(
    Get-ChildItem -LiteralPath $pluginRoot -File -Recurse |
        Where-Object { $_.Name -in $privateProfileNames }
)
Test-Fact 'Plugin 内没有私人档案文件' (
    $privateFilesInPlugin.Count -eq 0
) ("发现文件：" + (($privateFilesInPlugin.FullName) -join ', '))

$meechoDirectories = @(
    Get-ChildItem -LiteralPath $repoRoot -Directory -Force -Recurse |
        Where-Object {
            $_.Name -ceq '.meecho' -and
            $_.FullName -notmatch '[\\/]evals[\\/]fixtures[\\/]'
        }
)
Test-Fact '项目内没有真实 .meecho 档案目录' (
    $meechoDirectories.Count -eq 0
) ("发现目录：" + (($meechoDirectories.FullName) -join ', '))

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "RESULT: FAIL ($($failures.Count) checks failed)"
    exit 1
}

Write-Host ''
Write-Host 'RESULT: PASS'
exit 0
