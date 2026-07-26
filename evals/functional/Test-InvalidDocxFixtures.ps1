[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$fixtureRoot = Join-Path $repoRoot 'evals\fixtures\docx\invalid'
$expectedPath = Join-Path $fixtureRoot 'invalid.expected.json'
$sourceDocxPath = Join-Path $repoRoot 'evals\fixtures\docx\basic.docx'
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

function Get-FilePrefix {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [int] $Length
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ,([byte[]]::new(0))
    }

    $stream = [IO.File]::OpenRead($Path)
    try {
        $buffer = [byte[]]::new($Length)
        $read = $stream.Read($buffer, 0, $buffer.Length)
        return $buffer[0..([Math]::Max(0, $read - 1))]
    }
    finally {
        $stream.Dispose()
    }
}

function Test-BytePrefix {
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [byte[]] $Actual,

        [Parameter(Mandatory)]
        [byte[]] $Expected
    )

    if ($null -eq $Actual -or $Actual.Length -lt $Expected.Length) {
        return $false
    }
    for ($index = 0; $index -lt $Expected.Length; $index++) {
        if ($Actual[$index] -ne $Expected[$index]) {
            return $false
        }
    }
    return $true
}

function Test-ZipCanOpen {
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    try {
        $archive = [IO.Compression.ZipFile]::OpenRead($Path)
        $archive.Dispose()
        return $true
    }
    catch {
        return $false
    }
}

Write-Host 'Meecho invalid DOCX fixture test'
Write-Host "Repository: $repoRoot"

$expected = $null
try {
    $expected = Get-Content -LiteralPath $expectedPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
}
catch {
    $expected = $null
}

Test-Fact '异常输入清单存在且是合成 schema 1' (
    $null -ne $expected -and
    $expected.schema -eq 1 -and
    $expected.classification -ceq 'synthetic'
) "缺少或无法解析：$expectedPath"

$cases = if ($null -ne $expected) {
    @($expected.cases)
}
else {
    @()
}
$expectedKinds = @(
    'unsupported-doc',
    'macro-enabled-docm',
    'corrupt-docx',
    'encrypted-docx',
    'disguised-docx'
)
$actualKinds = @($cases | ForEach-Object { $_.kind })
Test-Fact '清单恰好覆盖五种异常输入' (
    $cases.Count -eq 5 -and
    @($expectedKinds | Where-Object { $_ -notin $actualKinds }).Count -eq 0 -and
    @($actualKinds | Where-Object { $_ -notin $expectedKinds }).Count -eq 0
) ("实际类型：" + ($actualKinds -join ', '))

$missingFiles = @(
    $cases |
        Where-Object {
            -not (
                Test-Path -LiteralPath (
                    Join-Path $fixtureRoot $_.file
                ) -PathType Leaf
            )
        }
)
Test-Fact '清单中的五个文件都存在' (
    $cases.Count -eq 5 -and
    $missingFiles.Count -eq 0
) ("缺失：" + (($missingFiles.file) -join ', '))

$hashMismatches = @(
    $cases |
        Where-Object {
            $path = Join-Path $fixtureRoot $_.file
            $_.sha256 -isnot [string] -or
            $_.sha256 -cnotmatch '^[A-F0-9]{64}$' -or
            -not (Test-Path -LiteralPath $path -PathType Leaf) -or
            (
                (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne
                $_.sha256
            )
        }
)
Test-Fact '五个文件的 SHA256 与清单一致' (
    $cases.Count -eq 5 -and
    $hashMismatches.Count -eq 0
) ("不一致：" + (($hashMismatches.file) -join ', '))

$docCase = @($cases | Where-Object { $_.kind -ceq 'unsupported-doc' })
$docPath = if ($docCase.Count -eq 1) {
    Join-Path $fixtureRoot $docCase[0].file
}
else {
    ''
}
Test-Fact 'DOC fixture 使用不受支持的 .doc 扩展名' (
    $docCase.Count -eq 1 -and
    [IO.Path]::GetExtension($docPath) -ceq '.doc'
) "DOC fixture 扩展名不正确：$docPath"

$docmCase = @($cases | Where-Object { $_.kind -ceq 'macro-enabled-docm' })
$docmPath = if ($docmCase.Count -eq 1) {
    Join-Path $fixtureRoot $docmCase[0].file
}
else {
    ''
}
$docmMainType = ''
if (Test-Path -LiteralPath $docmPath -PathType Leaf) {
    try {
        $docmArchive = [IO.Compression.ZipFile]::OpenRead($docmPath)
        try {
            $contentTypesEntry = $docmArchive.GetEntry('[Content_Types].xml')
            if ($null -ne $contentTypesEntry) {
                $reader = [IO.StreamReader]::new(
                    $contentTypesEntry.Open(),
                    [Text.Encoding]::UTF8
                )
                try {
                    $docmMainType = $reader.ReadToEnd()
                }
                finally {
                    $reader.Dispose()
                }
            }
        }
        finally {
            $docmArchive.Dispose()
        }
    }
    catch {
        $docmMainType = ''
    }
}
Test-Fact 'DOCM fixture 是宏启用 OOXML 包' (
    $docmCase.Count -eq 1 -and
    [IO.Path]::GetExtension($docmPath) -ceq '.docm' -and
    (Test-ZipCanOpen $docmPath) -and
    $docmMainType.Contains(
        'application/vnd.ms-word.document.macroEnabled.main+xml'
    )
) "DOCM fixture 不是可识别的宏启用 OOXML：$docmPath"

$corruptCase = @($cases | Where-Object { $_.kind -ceq 'corrupt-docx' })
$corruptPath = if ($corruptCase.Count -eq 1) {
    Join-Path $fixtureRoot $corruptCase[0].file
}
else {
    ''
}
$zipPrefix = [byte[]] @(0x50, 0x4B)
Test-Fact '损坏 DOCX 保留 ZIP 前缀但不能打开' (
    $corruptCase.Count -eq 1 -and
    (Test-BytePrefix (Get-FilePrefix $corruptPath 2) $zipPrefix) -and
    -not (Test-ZipCanOpen $corruptPath)
) "损坏 fixture 没有命中预期结构：$corruptPath"

$encryptedCase = @($cases | Where-Object { $_.kind -ceq 'encrypted-docx' })
$encryptedPath = if ($encryptedCase.Count -eq 1) {
    Join-Path $fixtureRoot $encryptedCase[0].file
}
else {
    ''
}
$cfbPrefix = [byte[]] @(0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1)
$encryptedBytes = if (
    Test-Path -LiteralPath $encryptedPath -PathType Leaf
) {
    [IO.File]::ReadAllBytes($encryptedPath)
}
else {
    ,([byte[]]::new(0))
}
$encryptedUtf16 = [Text.Encoding]::Unicode.GetString($encryptedBytes)
Test-Fact '加密 DOCX 是含加密流的 CFB 容器' (
    $encryptedCase.Count -eq 1 -and
    (Test-BytePrefix $encryptedBytes $cfbPrefix) -and
    $encryptedUtf16.Contains('EncryptionInfo') -and
    $encryptedUtf16.Contains('EncryptedPackage')
) "加密 fixture 不是可识别的 Office 加密容器：$encryptedPath"

$disguisedCase = @($cases | Where-Object { $_.kind -ceq 'disguised-docx' })
$disguisedPath = if ($disguisedCase.Count -eq 1) {
    Join-Path $fixtureRoot $disguisedCase[0].file
}
else {
    ''
}
$rtfPrefix = [Text.Encoding]::ASCII.GetBytes('{\rtf1')
Test-Fact '伪装 DOCX 实际是 RTF 而不是 ZIP' (
    $disguisedCase.Count -eq 1 -and
    [IO.Path]::GetExtension($disguisedPath) -ceq '.docx' -and
    (Test-BytePrefix (Get-FilePrefix $disguisedPath 6) $rtfPrefix) -and
    -not (Test-ZipCanOpen $disguisedPath)
) "伪装 fixture 没有命中预期结构：$disguisedPath"

$sourceHash = if (Test-Path -LiteralPath $sourceDocxPath -PathType Leaf) {
    (Get-FileHash -LiteralPath $sourceDocxPath -Algorithm SHA256).Hash
}
else {
    ''
}
Test-Fact '生成异常 fixture 不修改基础 DOCX' (
    $sourceHash -ceq (
        '2D4C1E0DA286F25D6A7335E621DA16E9446F15B2184ACF0BA76961690267E0C9'
    )
) "basic.docx SHA256 发生变化：$sourceHash"

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "RESULT: FAIL ($($failures.Count) checks failed)"
    exit 1
}

Write-Host ''
Write-Host 'RESULT: PASS'
exit 0
