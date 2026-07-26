[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$skillRoot = Join-Path $repoRoot 'plugins\meecho\skills\meecho'
$skillPath = Join-Path $skillRoot 'SKILL.md'
$buildReferencePath = Join-Path $skillRoot 'references\build-profile.md'
$corpusRoot = Join-Path $repoRoot 'evals\fixtures\synthetic-corpus'
$inventoryPath = Join-Path $repoRoot 'evals\fixtures\build\basic\analysis-inputs.json'
$targetOnlyInventoryPath = Join-Path $repoRoot 'evals\fixtures\build\target-only\analysis-inputs.json'
$profileFixtureRoot = Join-Path $repoRoot 'evals\fixtures\profile\valid\basic'
$profileRoot = Join-Path $profileFixtureRoot 'profiles\target-style'
$profileContractPath = Join-Path $repoRoot 'evals\contracts\Test-ProfileContract.ps1'
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

function ConvertTo-NormalizedText {
    param(
        [AllowEmptyString()]
        [string] $Text
    )

    return [regex]::Replace($Text, '\s+', '')
}

Write-Host 'Meecho build fixture contract check'
Write-Host "Repository: $repoRoot"

$referenceExists = Test-Path -LiteralPath $buildReferencePath -PathType Leaf
Test-Fact '中文 build 工作流参考文件存在' (
    $referenceExists
) "缺少文件：$buildReferencePath"

$skillText = if (Test-Path -LiteralPath $skillPath -PathType Leaf) {
    Get-Content -LiteralPath $skillPath -Raw -Encoding UTF8
}
else {
    ''
}
Test-Fact '唯一 Skill 可以发现 build 工作流' (
    $skillText.Contains('references/build-profile.md')
) 'SKILL.md 没有指向 references/build-profile.md。'

$inventory = $null
try {
    $inventory = Get-Content -LiteralPath $inventoryPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
}
catch {
    $failures.Add("合成输入清单不是合法 JSON：$inventoryPath")
}

Test-Fact '合成输入清单使用 schema 1' (
    $null -ne $inventory -and
    $inventory.schema -eq 1
) 'analysis-inputs.json 的 schema 必须为 1。'

$inputs = if ($null -ne $inventory) {
    @($inventory.analysis_inputs)
}
else {
    @()
}
$inputPaths = @($inputs | ForEach-Object { $_.relative_path })
$sealedPaths = @(
    Get-ChildItem -LiteralPath (Join-Path $corpusRoot 'sealed') -File -Recurse |
        ForEach-Object {
            [IO.Path]::GetRelativePath($corpusRoot, $_.FullName).Replace('\', '/')
        }
)
$sealedInputs = @($sealedPaths | Where-Object { $_ -in $inputPaths })
Test-Fact '封存作品不进入分析输入清单' (
    $sealedPaths.Count -gt 0 -and
    $sealedInputs.Count -eq 0
) ("误用封存文件：" + ($sealedInputs -join ', '))

$missingInputFiles = [System.Collections.Generic.List[string]]::new()
$invalidRoleInputs = [System.Collections.Generic.List[string]]::new()
$duplicateWorkIds = [System.Collections.Generic.List[string]]::new()
$seenWorkIds = [System.Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
foreach ($input in $inputs) {
    $sourcePath = Join-Path $corpusRoot $input.relative_path
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        $missingInputFiles.Add($input.relative_path)
    }
    if (-not $seenWorkIds.Add($input.work_id)) {
        $duplicateWorkIds.Add($input.work_id)
    }
    if (
        $input.relative_path.StartsWith('target/') -and
        $input.corpus_role -cne 'target'
    ) {
        $invalidRoleInputs.Add($input.work_id)
    }
    if (
        $input.relative_path.StartsWith('contrast/') -and
        $input.corpus_role -cne 'contrast'
    ) {
        $invalidRoleInputs.Add($input.work_id)
    }
}
Test-Fact '输入清单只引用存在的完整作品' (
    $inputs.Count -gt 0 -and
    $missingInputFiles.Count -eq 0 -and
    $duplicateWorkIds.Count -eq 0
) (
    "缺失文件：$($missingInputFiles -join ', ')；重复 work_id：" +
    ($duplicateWorkIds -join ', ')
)
Test-Fact '目标语料与对照语料的角色正确' (
    $invalidRoleInputs.Count -eq 0
) ("角色错误：" + ($invalidRoleInputs -join ', '))

$contrastInputs = @(
    $inputs |
        Where-Object { $_.relative_path.StartsWith('contrast/') }
)
$negativeContrastInputs = @(
    $contrastInputs |
        Where-Object { $_.corpus_role -in @('negative', 'counterexample') }
)
Test-Fact '可选对照语料不是自动负样本' (
    $contrastInputs.Count -gt 0 -and
    @($contrastInputs | Where-Object { $_.corpus_role -cne 'contrast' }).Count -eq 0 -and
    $negativeContrastInputs.Count -eq 0
) ("被误标为负样本：" + (($negativeContrastInputs.work_id) -join ', '))

$targetOnlyInventory = $null
try {
    $targetOnlyInventory = Get-Content -LiteralPath $targetOnlyInventoryPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
}
catch {
    $targetOnlyInventory = $null
}
$targetOnlyInputs = if ($null -ne $targetOnlyInventory) {
    @($targetOnlyInventory.analysis_inputs)
}
else {
    @()
}
$missingTargetOnlyFiles = @(
    $targetOnlyInputs |
        Where-Object {
            -not (
                Test-Path -LiteralPath (Join-Path $corpusRoot $_.relative_path) -PathType Leaf
            )
        }
)
Test-Fact '不提供对照语料时仍是合法 build 输入' (
    $null -ne $targetOnlyInventory -and
    $targetOnlyInventory.schema -eq 1 -and
    $targetOnlyInputs.Count -ge 2 -and
    @($targetOnlyInputs | Where-Object { $_.corpus_role -cne 'target' }).Count -eq 0 -and
    $missingTargetOnlyFiles.Count -eq 0
) "缺少合法的 target-only 合成输入：$targetOnlyInventoryPath"

$stylePath = Join-Path $profileRoot 'style-profile.md'
$styleText = if (Test-Path -LiteralPath $stylePath -PathType Leaf) {
    Get-Content -LiteralPath $stylePath -Raw -Encoding UTF8
}
else {
    ''
}
$ruleMatches = @(
    [regex]::Matches(
        $styleText,
        '(?ms)^### 规律 `(?<id>[a-z0-9][a-z0-9-]{0,63})`\r?\n(?<body>.*?)(?=^### |\z)'
    )
)
$highConfidenceRules = @(
    $ruleMatches |
        Where-Object {
            $_.Groups['body'].Value -match '(?m)^- 置信度：高\s*$'
        }
)
$targetFamilyIds = @(
    $inputs |
        Where-Object { $_.corpus_role -ceq 'target' } |
        ForEach-Object { $_.work_family_id }
)
Test-Fact '合成档案至少包含一条高可信规律' (
    $highConfidenceRules.Count -gt 0
) 'style-profile.md 没有结构化的高可信规律。'

foreach ($rule in $highConfidenceRules) {
    $ruleId = $rule.Groups['id'].Value
    $body = $rule.Groups['body'].Value
    $evidenceLine = [regex]::Match(
        $body,
        '(?m)^- 证据作品族：(?<ids>.+)$'
    )
    $evidenceFamilyIds = @(
        [regex]::Matches(
            $evidenceLine.Groups['ids'].Value,
            '`(?<id>[a-z0-9][a-z0-9-]{0,63})`'
        ) |
            ForEach-Object { $_.Groups['id'].Value } |
            Select-Object -Unique
    )
    $nonTargetFamilies = @(
        $evidenceFamilyIds |
            Where-Object { $_ -notin $targetFamilyIds }
    )
    Test-Fact "高可信规律跨至少两个目标作品族：$ruleId" (
        $evidenceFamilyIds.Count -ge 2 -and
        $nonTargetFamilies.Count -eq 0
    ) (
        "证据作品族：$($evidenceFamilyIds -join ', ')；非目标作品族：" +
        ($nonTargetFamilies -join ', ')
    )
    Test-Fact "高可信规律记录反例或适用边界：$ruleId" (
        $body -match '(?m)^- 反例与边界：\S.+$'
    ) '每条高可信规律都必须说明反例或适用边界。'
}

$sourceByWorkId = @{}
$contrastWorkIds = @(
    $contrastInputs |
        ForEach-Object { $_.work_id }
)
foreach ($input in $inputs) {
    $sourcePath = Join-Path $corpusRoot $input.relative_path
    if (Test-Path -LiteralPath $sourcePath -PathType Leaf) {
        $sourceByWorkId[$input.work_id] = Get-Content -LiteralPath $sourcePath -Raw -Encoding UTF8
    }
}

$exemplarPath = Join-Path $profileRoot 'exemplars.jsonl'
$exemplarErrors = [System.Collections.Generic.List[string]]::new()
if (Test-Path -LiteralPath $exemplarPath -PathType Leaf) {
    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $exemplarPath -Encoding UTF8) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        try {
            $record = $line | ConvertFrom-Json
        }
        catch {
            $exemplarErrors.Add("第 $lineNumber 行不是合法 JSON。")
            continue
        }
        if (-not $sourceByWorkId.ContainsKey($record.work_id)) {
            $exemplarErrors.Add("第 $lineNumber 行引用未知 work_id。")
            continue
        }
        if (-not $sourceByWorkId[$record.work_id].Contains($record.excerpt)) {
            $exemplarErrors.Add("第 $lineNumber 行的短例句无法追溯到原作品。")
        }
        if (
            $record.category -ceq 'counterexample' -and
            $record.work_id -in $contrastWorkIds
        ) {
            $exemplarErrors.Add("第 $lineNumber 行把对照语料当成了反例。")
        }
    }
}
else {
    $exemplarErrors.Add('缺少 exemplars.jsonl。')
}
Test-Fact '短例句可以追溯且对照语料未被当成反例' (
    $exemplarErrors.Count -eq 0
) ("例句错误：" + ($exemplarErrors -join '; '))

$profileFiles = @(
    'manifest.json',
    'style-profile.md',
    'attention-lens.md',
    'voices.md',
    'exemplars.jsonl',
    'preferences.md'
)
$profileText = (
    $profileFiles |
        ForEach-Object {
            $path = Join-Path $profileRoot $_
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                Get-Content -LiteralPath $path -Raw -Encoding UTF8
            }
        }
) -join "`n"
$pluginText = (
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'plugins\meecho') -File -Recurse |
        ForEach-Object {
            Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
        }
) -join "`n"
$normalizedDestinations = ConvertTo-NormalizedText ($profileText + $pluginText)
$leakedSealedLines = [System.Collections.Generic.List[string]]::new()
foreach ($sealedPath in $sealedPaths) {
    $fullPath = Join-Path $corpusRoot $sealedPath
    foreach ($line in Get-Content -LiteralPath $fullPath -Encoding UTF8) {
        $normalizedLine = ConvertTo-NormalizedText $line
        if (
            -not $line.StartsWith('#') -and
            $normalizedLine.Length -ge 20 -and
            $normalizedDestinations.Contains($normalizedLine)
        ) {
            $leakedSealedLines.Add($sealedPath)
        }
    }
}
Test-Fact '封存原文没有泄漏到 Plugin 或合成输出档案' (
    $leakedSealedLines.Count -eq 0
) ("发现泄漏：" + (($leakedSealedLines | Select-Object -Unique) -join ', '))

$profileContractOutput = & pwsh -NoProfile -File $profileContractPath *>&1
$profileContractExit = $LASTEXITCODE
Test-Fact '合成 build 输出符合任务 3 的档案 schema' (
    $profileContractExit -eq 0
) ("档案契约退出码：$profileContractExit`n" + ($profileContractOutput -join "`n"))

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "RESULT: FAIL ($($failures.Count) checks failed)"
    exit 1
}

Write-Host ''
Write-Host 'RESULT: PASS'
exit 0
