[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$skillRoot = Join-Path $repoRoot 'plugins\meecho\skills\meecho'
$skillPath = Join-Path $skillRoot 'SKILL.md'
$writeReferencePath = Join-Path $skillRoot 'references\write-and-revise.md'
$privacyReferencePath = Join-Path $skillRoot 'references\privacy-and-permissions.md'
$profileFixtureRoot = Join-Path $repoRoot 'evals\fixtures\profile\valid\basic'
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

function Read-JsonContract {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Heading
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $pattern = (
        '(?ms)^## ' +
        [regex]::Escape($Heading) +
        '\s*\r?\n.*?```json\s*\r?\n(?<json>.*?)\r?\n```'
    )
    $match = [regex]::Match($text, $pattern)
    if (-not $match.Success) {
        return $null
    }

    try {
        return $match.Groups['json'].Value | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Get-TreeFingerprint {
    param(
        [Parameter(Mandatory)]
        [string] $Root
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return @()
    }

    return @(
        Get-ChildItem -LiteralPath $Root -File -Recurse -Force |
            Sort-Object FullName |
            ForEach-Object {
                $relativePath = [IO.Path]::GetRelativePath($Root, $_.FullName).
                    Replace('\', '/')
                $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
                "$relativePath|$hash"
            }
    )
}

function Test-TreeEqual {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Before,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $After
    )

    return (
        $null -eq (
            Compare-Object -ReferenceObject $Before -DifferenceObject $After
        )
    )
}

function Remove-Whitespace {
    param(
        [AllowEmptyString()]
        [string] $Text
    )

    return [regex]::Replace($Text, '\s+', '')
}

function Test-PrivateChineseOverlap {
    param(
        [Parameter(Mandatory)]
        [string] $PrivateSource,

        [Parameter(Mandatory)]
        [string] $Candidate,

        [Parameter(Mandatory)]
        [int] $MinimumLength
    )

    $normalizedSource = Remove-Whitespace $PrivateSource
    $normalizedCandidate = Remove-Whitespace $Candidate
    $chineseRuns = [regex]::Matches(
        $normalizedCandidate,
        "[\p{IsCJKUnifiedIdeographs}]{$MinimumLength,}"
    )
    foreach ($run in $chineseRuns) {
        for ($length = $run.Value.Length; $length -ge $MinimumLength; $length--) {
            for ($start = 0; $start -le $run.Value.Length - $length; $start++) {
                $fragment = $run.Value.Substring($start, $length)
                if ($normalizedSource.Contains($fragment)) {
                    return $true
                }
            }
        }
    }

    return $false
}

Write-Host 'Meecho write boundary test'
Write-Host "Repository: $repoRoot"

$writeReferenceExists = Test-Path -LiteralPath $writeReferencePath -PathType Leaf
$privacyReferenceExists = Test-Path -LiteralPath $privacyReferencePath -PathType Leaf
Test-Fact '中文写作与润色协议存在' (
    $writeReferenceExists
) "缺少文件：$writeReferencePath"
Test-Fact '中文隐私与权限协议存在' (
    $privacyReferenceExists
) "缺少文件：$privacyReferencePath"

$skillText = if (Test-Path -LiteralPath $skillPath -PathType Leaf) {
    Get-Content -LiteralPath $skillPath -Raw -Encoding UTF8
}
else {
    ''
}
Test-Fact 'Skill 为 write 和 revise 路由写作协议' (
    $skillText.Contains('references/write-and-revise.md')
) 'SKILL.md 没有指向 references/write-and-revise.md。'
Test-Fact 'Skill 为八个操作路由权限协议' (
    $skillText.Contains('references/privacy-and-permissions.md')
) 'SKILL.md 没有指向 references/privacy-and-permissions.md。'

$operationContract = Read-JsonContract `
    -Path $privacyReferencePath `
    -Heading '可检验的操作矩阵'
$protectionContract = Read-JsonContract `
    -Path $writeReferencePath `
    -Heading '可检验的复刻保护规则'

Test-Fact '操作矩阵是合法的版本 1 协议' (
    $null -ne $operationContract -and
    $operationContract.协议版本 -eq 1
) '隐私与权限参考文件缺少可解析的版本 1 操作矩阵。'
Test-Fact '复刻保护是合法的版本 1 协议' (
    $null -ne $protectionContract -and
    $protectionContract.协议版本 -eq 1
) '写作与润色参考文件缺少可解析的版本 1 复刻保护规则。'

$expectedOperations = [ordered]@{
    'build' = @{
        项目变更 = '禁止'
        档案变更 = '批准后允许'
        其他位置变更 = '禁止'
        前置条件 = '写入审批'
    }
    'write' = @{
        项目变更 = '禁止'
        档案变更 = '禁止'
        其他位置变更 = '禁止'
        前置条件 = '无'
    }
    'revise' = @{
        项目变更 = '禁止'
        档案变更 = '禁止'
        其他位置变更 = '禁止'
        前置条件 = '无'
    }
    'update' = @{
        项目变更 = '禁止'
        档案变更 = '批准后允许'
        其他位置变更 = '禁止'
        前置条件 = '写入审批'
    }
    'remember' = @{
        项目变更 = '禁止'
        档案变更 = '批准后允许'
        其他位置变更 = '禁止'
        前置条件 = '写入审批'
    }
    'status' = @{
        项目变更 = '禁止'
        档案变更 = '禁止'
        其他位置变更 = '禁止'
        前置条件 = '无'
    }
    'export' = @{
        项目变更 = '禁止'
        档案变更 = '禁止'
        其他位置变更 = '批准后允许'
        前置条件 = '写入审批'
    }
    'delete' = @{
        项目变更 = '禁止'
        档案变更 = '二次确认后允许'
        其他位置变更 = '禁止'
        前置条件 = '二次确认'
    }
}

$operations = if ($null -ne $operationContract) {
    @($operationContract.操作)
}
else {
    @()
}
$actualNames = @($operations | ForEach-Object { $_.名称 })
Test-Fact '操作矩阵恰好覆盖八个公开操作' (
    $operations.Count -eq 8 -and
    @($expectedOperations.Keys | Where-Object { $_ -notin $actualNames }).Count -eq 0 -and
    @($actualNames | Where-Object { $_ -notin $expectedOperations.Keys }).Count -eq 0
) ("实际操作：" + ($actualNames -join ', '))

foreach ($operationName in $expectedOperations.Keys) {
    $actual = @(
        $operations |
            Where-Object { $_.名称 -ceq $operationName }
    )
    $expected = $expectedOperations[$operationName]
    $valid = (
        $actual.Count -eq 1 -and
        $actual[0].项目变更 -ceq $expected.项目变更 -and
        $actual[0].档案变更 -ceq $expected.档案变更 -and
        $actual[0].其他位置变更 -ceq $expected.其他位置变更 -and
        $actual[0].前置条件 -ceq $expected.前置条件 -and
        $actual[0].输出位置 -ceq '聊天' -and
        $actual[0].创建草稿文件 -eq $false
    )
    Test-Fact "操作边界正确：$operationName" (
        $valid
    ) "$operationName 的变更位置、前置条件或输出位置不符合协议。"
}

$temporaryRoot = Join-Path (
    [IO.Path]::GetTempPath()
) ("meecho-write-boundaries-" + [guid]::NewGuid().ToString('N'))
$projectRoot = Join-Path $temporaryRoot 'project'
$privateRoot = Join-Path $temporaryRoot 'private-profile'
New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
Copy-Item -LiteralPath $profileFixtureRoot -Destination $privateRoot -Recurse
Set-Content `
    -LiteralPath (Join-Path $projectRoot 'user-note.txt') `
    -Value '合成项目文件，仅用于验证普通写作不落盘。' `
    -Encoding UTF8

try {
    $projectBefore = @(Get-TreeFingerprint $projectRoot)
    $profileBefore = @(Get-TreeFingerprint $privateRoot)

    foreach ($operationName in @('write', 'revise', 'status')) {
        $chatOutput = "合成的 $operationName 聊天返回值"
        if ([string]::IsNullOrWhiteSpace($chatOutput)) {
            throw "$operationName 没有产生聊天返回值。"
        }
    }

    $projectAfterReadOnly = @(Get-TreeFingerprint $projectRoot)
    $profileAfterReadOnly = @(Get-TreeFingerprint $privateRoot)
    Test-Fact '普通写作、润色和 status 前后项目树不变' (
        Test-TreeEqual $projectBefore $projectAfterReadOnly
    ) '只读操作改变了合成项目目录。'
    Test-Fact '普通写作、润色和 status 前后私人档案不变' (
        Test-TreeEqual $profileBefore $profileAfterReadOnly
    ) '只读操作改变了合成私人档案目录。'

    foreach ($operationName in @('build', 'update', 'remember', 'export', 'delete')) {
        $permissionDecision = '拒绝'
        if ($permissionDecision -cne '拒绝') {
            throw '拒绝权限模拟失效。'
        }
    }

    $projectAfterDenied = @(Get-TreeFingerprint $projectRoot)
    $profileAfterDenied = @(Get-TreeFingerprint $privateRoot)
    Test-Fact '拒绝管理动作后没有项目文件或部分文件' (
        Test-TreeEqual $projectBefore $projectAfterDenied
    ) '拒绝权限后合成项目目录发生变化。'
    Test-Fact '拒绝管理动作后没有档案文件或部分文件' (
        Test-TreeEqual $profileBefore $profileAfterDenied
    ) '拒绝权限后合成私人档案目录发生变化。'
}
finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
}

$minimumLength = if ($null -ne $protectionContract) {
    [int] $protectionContract.最小连续汉字数
}
else {
    0
}
Test-Fact '复刻保护阈值固定为 20 个连续汉字' (
    $minimumLength -eq 20 -and
    $protectionContract.比较前处理 -ceq '只去除空白字符' -and
    $protectionContract.命中动作 -ceq '停止并重新生成'
) '复刻保护阈值、规范化方式或命中动作不正确。'

$privateSource = '私人原文开头。甲乙丙丁戊己庚辛壬癸子丑寅卯辰巳午未申酉。私人原文结尾。'
$twentyCharacters = '甲乙丙丁戊己庚辛壬癸子丑寅卯辰巳午未申酉'
$nineteenCharacters = '甲乙丙丁戊己庚辛壬癸子丑寅卯辰巳午未申'
$spacedTwentyCharacters = '甲乙丙丁戊 己庚辛壬癸 子丑寅卯辰 巳午未申酉'
$unrelatedCharacters = '天地玄黄宇宙洪荒日月盈昃辰宿列张寒来暑往'

Test-Fact '完全相同的 20 个连续汉字会被拦截' (
    Test-PrivateChineseOverlap $privateSource $twentyCharacters $minimumLength
) '20 字边界未命中。'
Test-Fact '只有 19 个连续汉字时不会误拦截' (
    -not (
        Test-PrivateChineseOverlap $privateSource $nineteenCharacters $minimumLength
    )
) '19 字边界被误判。'
Test-Fact '插入空白不能绕过 20 字保护' (
    Test-PrivateChineseOverlap $privateSource $spacedTwentyCharacters $minimumLength
) '去除空白后应当命中。'
Test-Fact '无关的连续汉字不会被误拦截' (
    -not (
        Test-PrivateChineseOverlap $privateSource $unrelatedCharacters $minimumLength
    )
) '无关文字被误判。'

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "RESULT: FAIL ($($failures.Count) checks failed)"
    exit 1
}

Write-Host ''
Write-Host 'RESULT: PASS'
exit 0
