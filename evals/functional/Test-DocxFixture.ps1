[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$fixturePath = Join-Path $repoRoot 'evals\fixtures\docx\basic.docx'
$expectedPath = Join-Path $repoRoot 'evals\fixtures\docx\basic.expected.json'
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

function Test-ExactSequence {
    param(
        [AllowEmptyCollection()]
        [object[]] $Actual,

        [AllowEmptyCollection()]
        [object[]] $Expected
    )

    if ($Actual.Count -ne $Expected.Count) {
        return $false
    }

    for ($index = 0; $index -lt $Actual.Count; $index++) {
        if ([string] $Actual[$index] -cne [string] $Expected[$index]) {
            return $false
        }
    }

    return $true
}

Write-Host 'Meecho DOCX fixture test'
Write-Host "Repository: $repoRoot"

$expected = $null
try {
    $expected = Get-Content -LiteralPath $expectedPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
}
catch {
    $failures.Add("预期清单不是合法 JSON：$expectedPath")
}

Test-Fact 'DOCX 预期清单使用 schema 1 并标记为合成内容' (
    $null -ne $expected -and
    $expected.schema -eq 1 -and
    $expected.classification -ceq 'synthetic'
) 'basic.expected.json 必须使用 schema 1 和 synthetic 分类。'

$fixtureExists = Test-Path -LiteralPath $fixturePath -PathType Leaf
Test-Fact '合成 DOCX fixture 存在' (
    $fixtureExists
) "缺少文件：$fixturePath"

$beforeHash = $null
$afterHash = $null
$entryNames = @()
$visibleParagraphs = @()
$titleParagraphs = @()
$readSucceeded = $false

if ($fixtureExists) {
    $beforeHash = (Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash
    $archive = $null
    $reader = $null

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [System.IO.Compression.ZipFile]::OpenRead($fixturePath)
        $entryNames = @($archive.Entries | ForEach-Object { $_.FullName })

        $documentEntry = $archive.GetEntry('word/document.xml')
        if ($null -ne $documentEntry) {
            $reader = [System.IO.StreamReader]::new(
                $documentEntry.Open(),
                [System.Text.Encoding]::UTF8,
                $true
            )
            [xml] $documentXml = $reader.ReadToEnd()
            $namespaceManager = [System.Xml.XmlNamespaceManager]::new(
                $documentXml.NameTable
            )
            $namespaceManager.AddNamespace(
                'w',
                'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
            )

            foreach (
                $paragraphNode in @(
                    $documentXml.SelectNodes('//w:body/w:p', $namespaceManager)
                )
            ) {
                $text = @(
                    $paragraphNode.SelectNodes('.//w:t', $namespaceManager) |
                        ForEach-Object { $_.InnerText }
                ) -join ''

                if ([string]::IsNullOrWhiteSpace($text)) {
                    continue
                }

                $styleNode = $paragraphNode.SelectSingleNode(
                    './w:pPr/w:pStyle',
                    $namespaceManager
                )
                $style = if ($null -ne $styleNode) {
                    $styleNode.GetAttribute(
                        'val',
                        'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
                    )
                }
                else {
                    ''
                }

                $visibleParagraphs += $text
                if ($style -ceq 'Title') {
                    $titleParagraphs += $text
                }
            }
        }

        $readSucceeded = $true
    }
    catch {
        $failures.Add("无法作为 OOXML DOCX 读取：$($_.Exception.Message)")
    }
    finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        }
        if ($null -ne $archive) {
            $archive.Dispose()
        }
    }

    $afterHash = (Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash
}

$requiredEntries = @(
    '[Content_Types].xml',
    '_rels/.rels',
    'word/document.xml',
    'word/styles.xml'
)
$missingEntries = @(
    $requiredEntries | Where-Object { $_ -notin $entryNames }
)
Test-Fact 'fixture 是包含必需部件的合法 OOXML 包' (
    $readSucceeded -and
    $missingEntries.Count -eq 0
) ('缺少 OOXML 部件：' + ($missingEntries -join ', '))

$encryptionEntries = @(
    $entryNames | Where-Object {
        $_ -in @('EncryptionInfo', 'EncryptedPackage')
    }
)
Test-Fact 'fixture 未加密' (
    $readSucceeded -and
    $encryptionEntries.Count -eq 0
) ('发现加密包部件：' + ($encryptionEntries -join ', '))

$expectedTitle = if ($null -ne $expected) {
    [string] $expected.title
}
else {
    ''
}
$expectedBody = if ($null -ne $expected) {
    @($expected.paragraphs | ForEach-Object { [string] $_ })
}
else {
    @()
}
$expectedVisible = @($expectedTitle) + $expectedBody
$actualBody = if ($visibleParagraphs.Count -gt 0) {
    @($visibleParagraphs | Select-Object -Skip 1)
}
else {
    @()
}

Test-Fact '标题由 Title 样式标记且与预期一致' (
    $titleParagraphs.Count -eq 1 -and
    $titleParagraphs[0] -ceq $expectedTitle -and
    $visibleParagraphs.Count -gt 0 -and
    $visibleParagraphs[0] -ceq $expectedTitle
) '标题文本、样式或位置与 basic.expected.json 不一致。'

Test-Fact '首段、中间段和末段顺序与预期清单一致' (
    Test-ExactSequence $actualBody $expectedBody
) '正文段落数量、文字或顺序与 basic.expected.json 不一致。'

Test-Fact 'fixture 只包含清单中的合成可见文字' (
    Test-ExactSequence $visibleParagraphs $expectedVisible
) 'DOCX 含有预期清单之外的可见文字。'

Test-Fact 'DOCX 在只读检查前后哈希不变' (
    $null -ne $beforeHash -and
    $beforeHash -ceq $afterHash
) '测试读取改变了 DOCX 文件。'

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "RESULT: FAIL ($($failures.Count) checks failed)"
    exit 1
}

Write-Host ''
Write-Host 'RESULT: PASS'
exit 0
