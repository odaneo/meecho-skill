[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$skillRoot = Join-Path $repoRoot 'plugins\meecho\skills\meecho'
$skillPath = Join-Path $skillRoot 'SKILL.md'
$writeReferencePath = Join-Path $skillRoot 'references\write-and-revise.md'
$privacyReferencePath = Join-Path $skillRoot 'references\privacy-and-permissions.md'
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

Write-Host 'Meecho write and permission static contract check'
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

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "RESULT: FAIL ($($failures.Count) checks failed)"
    exit 1
}

Write-Host ''
Write-Host 'RESULT: PASS'
exit 0
