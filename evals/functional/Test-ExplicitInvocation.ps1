[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$skillsRoot = Join-Path $repoRoot 'plugins\meecho\skills'
$skillRoot = Join-Path $skillsRoot 'meecho'
$skillPath = Join-Path $skillRoot 'SKILL.md'
$agentPath = Join-Path $skillRoot 'agents\openai.yaml'
$pluginManifestPath = Join-Path $repoRoot 'plugins\meecho\.codex-plugin\plugin.json'
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

Write-Host 'Meecho explicit invocation contract test'
Write-Host "Repository: $repoRoot"

$skillDirectories = @()
if (Test-Path -LiteralPath $skillsRoot -PathType Container) {
    $skillDirectories = @(Get-ChildItem -LiteralPath $skillsRoot -Directory)
}
Test-Fact 'plugin contains exactly one Skill' (
    $skillDirectories.Count -eq 1 -and
    $skillDirectories[0].Name -ceq 'meecho'
) 'plugins/meecho/skills must contain only the meecho Skill directory.'

$skillExists = Test-Path -LiteralPath $skillPath -PathType Leaf
$agentExists = Test-Path -LiteralPath $agentPath -PathType Leaf
Test-Fact 'SKILL.md exists' $skillExists "Missing file: $skillPath"
Test-Fact 'agents/openai.yaml exists' $agentExists "Missing file: $agentPath"

$skillText = if ($skillExists) {
    Get-Content -LiteralPath $skillPath -Raw -Encoding UTF8
}
else {
    ''
}
$agentText = if ($agentExists) {
    Get-Content -LiteralPath $agentPath -Raw -Encoding UTF8
}
else {
    ''
}

$frontmatterMatch = [regex]::Match(
    $skillText,
    '\A---\r?\n(?<frontmatter>.*?)\r?\n---(?:\r?\n|$)',
    [Text.RegularExpressions.RegexOptions]::Singleline
)
Test-Fact 'SKILL.md has closed YAML frontmatter' $frontmatterMatch.Success 'SKILL.md must start with closed YAML frontmatter.'

$frontmatter = if ($frontmatterMatch.Success) {
    $frontmatterMatch.Groups['frontmatter'].Value
}
else {
    ''
}
$frontmatterKeys = @(
    [regex]::Matches($frontmatter, '(?m)^(?<key>[a-z][a-z0-9_-]*):') |
        ForEach-Object { $_.Groups['key'].Value }
)
Test-Fact 'Skill frontmatter uses only name and description' (
    $frontmatterKeys.Count -eq 2 -and
    $frontmatterKeys -contains 'name' -and
    $frontmatterKeys -contains 'description'
) 'Skill frontmatter must contain exactly name and description.'
Test-Fact 'Skill name is meecho' (
    $frontmatter -match '(?m)^name:\s*["'']?meecho["'']?\s*$'
) 'Skill frontmatter name must be exactly meecho.'

$namespace = '$meecho:meecho'
Test-Fact 'Skill metadata documents the explicit selector' (
    $frontmatter.Contains($namespace)
) 'Skill description must name the explicit selector $meecho:meecho.'
Test-Fact 'UI default prompt uses the namespaced selector' (
    $agentText.Contains($namespace)
) 'interface.default_prompt must mention $meecho:meecho.'

$pluginManifest = $null
if (Test-Path -LiteralPath $pluginManifestPath -PathType Leaf) {
    $pluginManifest = Get-Content -LiteralPath $pluginManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
}
$pluginDefaultPrompt = if (
    $null -ne $pluginManifest -and
    $pluginManifest.interface.defaultPrompt -is [string]
) {
    $pluginManifest.interface.defaultPrompt
}
else {
    ''
}
Test-Fact 'Plugin default prompt uses the namespaced selector' (
    $pluginDefaultPrompt.Contains($namespace)
) 'plugin.json interface.defaultPrompt must mention $meecho:meecho.'
Test-Fact 'implicit invocation is disabled' (
    $agentText -match '(?m)^\s{2}allow_implicit_invocation:\s*false\s*$'
) 'policy.allow_implicit_invocation must be false.'

$declaredOperations = @(
    [regex]::Matches($skillText, '(?m)^- `(?<operation>[a-z]+)`:\s+\S.*$') |
        ForEach-Object { $_.Groups['operation'].Value }
)
$expectedOperations = @(
    'build',
    'write',
    'revise',
    'update',
    'remember',
    'status',
    'export',
    'delete'
)
$missingOperations = @($expectedOperations | Where-Object { $_ -notin $declaredOperations })
$unexpectedOperations = @($declaredOperations | Where-Object { $_ -notin $expectedOperations })
Test-Fact 'Skill exposes exactly the eight planned operation intents' (
    $declaredOperations.Count -eq $expectedOperations.Count -and
    $missingOperations.Count -eq 0 -and
    $unexpectedOperations.Count -eq 0
) ("Missing: {0}; unexpected: {1}" -f ($missingOperations -join ', '), ($unexpectedOperations -join ', '))

$duplicateSkillPaths = @(
    '.agents\skills\meecho',
    '.codex\skills\meecho'
)
$duplicatesFound = @(
    $duplicateSkillPaths |
        Where-Object { Test-Path -LiteralPath (Join-Path $repoRoot $_) }
)
Test-Fact 'repository has no second standalone meecho Skill' (
    $duplicatesFound.Count -eq 0
) ("Duplicate paths: " + ($duplicatesFound -join ', '))

Test-Fact 'obsolete skills placeholder is removed' (
    -not (Test-Path -LiteralPath (Join-Path $skillsRoot '.gitkeep'))
) 'plugins/meecho/skills/.gitkeep is no longer needed after creating the Skill.'

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "RESULT: FAIL ($($failures.Count) checks failed)"
    exit 1
}

Write-Host ''
Write-Host 'RESULT: PASS'
exit 0
