[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$pluginRoot = Join-Path $repoRoot 'plugins\meecho'
$manifestPath = Join-Path $pluginRoot '.codex-plugin\plugin.json'
$marketplacePath = Join-Path $repoRoot '.agents\plugins\marketplace.json'
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

Write-Host 'Meecho Plugin structure test'
Write-Host "Repository: $repoRoot"

$manifestExists = Test-Path -LiteralPath $manifestPath -PathType Leaf
Test-Fact 'plugin manifest exists' $manifestExists "Missing file: $manifestPath"

$manifest = $null
if ($manifestExists) {
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Test-Fact 'plugin manifest is valid JSON' $true 'Manifest is not valid JSON.'
    }
    catch {
        Test-Fact 'plugin manifest is valid JSON' $false $_.Exception.Message
    }
}
else {
    Test-Fact 'plugin manifest is valid JSON' $false 'Manifest cannot be parsed because it does not exist.'
}

Test-Fact 'plugin name is meecho' ($null -ne $manifest -and $manifest.name -ceq 'meecho') 'Manifest name must be exactly "meecho".'

$marketplaceExists = Test-Path -LiteralPath $marketplacePath -PathType Leaf
Test-Fact 'repository marketplace exists' $marketplaceExists "Missing file: $marketplacePath"

$marketplace = $null
if ($marketplaceExists) {
    try {
        $marketplace = Get-Content -LiteralPath $marketplacePath -Raw -Encoding UTF8 | ConvertFrom-Json
        Test-Fact 'repository marketplace is valid JSON' $true 'Marketplace is not valid JSON.'
    }
    catch {
        Test-Fact 'repository marketplace is valid JSON' $false $_.Exception.Message
    }
}
else {
    Test-Fact 'repository marketplace is valid JSON' $false 'Marketplace cannot be parsed because it does not exist.'
}

$marketplacePlugins = @()
if ($null -ne $marketplace -and $null -ne $marketplace.plugins) {
    $marketplacePlugins = @($marketplace.plugins)
}
$meechoEntries = @($marketplacePlugins | Where-Object { $_.name -ceq 'meecho' })
Test-Fact 'marketplace has exactly one meecho entry' ($meechoEntries.Count -eq 1) 'Marketplace must contain exactly one plugin named "meecho".'

$meechoEntry = if ($meechoEntries.Count -eq 1) { $meechoEntries[0] } else { $null }
Test-Fact 'marketplace points to the repository plugin' (
    $null -ne $meechoEntry -and
    $meechoEntry.source.source -ceq 'local' -and
    $meechoEntry.source.path -ceq './plugins/meecho'
) 'Meecho must use the repo-local source ./plugins/meecho.'
Test-Fact 'marketplace uses explicit install policy' (
    $null -ne $meechoEntry -and
    $meechoEntry.policy.installation -ceq 'AVAILABLE' -and
    $meechoEntry.policy.authentication -ceq 'ON_INSTALL'
) 'Meecho must be AVAILABLE with authentication ON_INSTALL.'

$skillsRoot = Join-Path $pluginRoot 'skills'
$skillsRootExists = Test-Path -LiteralPath $skillsRoot -PathType Container
Test-Fact 'plugin has one skills capability directory' $skillsRootExists 'plugins/meecho/skills must exist.'

$pluginCapabilityDirectories = @()
if (Test-Path -LiteralPath $pluginRoot -PathType Container) {
    $pluginCapabilityDirectories = @(
        Get-ChildItem -LiteralPath $pluginRoot -Directory -Force |
            Where-Object { $_.Name -ne '.codex-plugin' }
    )
}
Test-Fact 'skills is the only plugin capability directory' (
    $pluginCapabilityDirectories.Count -eq 1 -and
    $pluginCapabilityDirectories[0].Name -ceq 'skills'
) 'Task 1 may create only the top-level skills container; the actual Skill belongs to task 2.'

$forbiddenRelativePaths = @(
    'scripts',
    '.mcp.json',
    '.app.json',
    'hooks',
    'package.json',
    'package-lock.json',
    'pnpm-lock.yaml',
    'yarn.lock',
    'requirements.txt',
    'pyproject.toml',
    'Pipfile',
    'poetry.lock',
    'node_modules',
    '.venv'
)
$forbiddenFound = @()
foreach ($relativePath in $forbiddenRelativePaths) {
    $candidate = Join-Path $pluginRoot $relativePath
    if (Test-Path -LiteralPath $candidate) {
        $forbiddenFound += $relativePath
    }
}
Test-Fact 'plugin has no scripts or runtime dependencies' ($forbiddenFound.Count -eq 0) ("Forbidden paths: " + ($forbiddenFound -join ', '))

$privateFiles = @()
if (Test-Path -LiteralPath $pluginRoot -PathType Container) {
    $privateFiles = @(
        Get-ChildItem -LiteralPath $pluginRoot -File -Recurse |
            Where-Object {
                $_.Extension -in @('.doc', '.docx', '.docm', '.dotx', '.odt', '.rtf', '.pdf') -or
                $_.FullName -match '[\\/](corpus|profiles|private|source-documents)[\\/]'
            }
    )
}
Test-Fact 'plugin contains no private corpus files' ($privateFiles.Count -eq 0) ("Private-looking files: " + (($privateFiles.FullName) -join ', '))

$legacyBaselinePaths = @(
    'evals\cases',
    'evals\rubric.md',
    'evals\results\baseline-summary.md',
    'evals\scripts\Invoke-Baseline.ps1',
    'evals\scripts\Invoke-Task1Tests.ps1',
    'evals\tests\Test-BaselineRunner.ps1'
)
$legacyBaselineFound = @(
    $legacyBaselinePaths |
        Where-Object { Test-Path -LiteralPath (Join-Path $repoRoot $_) }
)
Test-Fact 'legacy AI-scored baseline is absent' ($legacyBaselineFound.Count -eq 0) ("Legacy paths: " + ($legacyBaselineFound -join ', '))

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "RESULT: FAIL ($($failures.Count) checks failed)"
    exit 1
}

Write-Host ''
Write-Host 'RESULT: PASS'
exit 0
