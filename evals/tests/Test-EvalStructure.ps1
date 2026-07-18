[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$failures = [System.Collections.Generic.List[string]]::new()
function Assert-Condition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { $script:failures.Add($Message) }
}

function Get-RequiredFile {
    param([string]$RelativePath)
    $path = Join-Path $RepositoryRoot $RelativePath
    Assert-Condition (Test-Path -LiteralPath $path -PathType Leaf) "Missing required file: $RelativePath"
    return $path
}

$highSchool = Join-Path $RepositoryRoot 'evals/fixtures/synthetic-corpus/high-school'
$adult = Join-Path $RepositoryRoot 'evals/fixtures/synthetic-corpus/adult-contrast'
$sealed = Join-Path $RepositoryRoot 'evals/fixtures/synthetic-corpus/sealed'
Assert-Condition (Test-Path -LiteralPath $highSchool -PathType Container) 'Missing high-school synthetic corpus family.'
Assert-Condition (Test-Path -LiteralPath $adult -PathType Container) 'Missing adult-contrast synthetic corpus family.'
Assert-Condition (Test-Path -LiteralPath $sealed -PathType Container) 'Missing sealed synthetic corpus family.'
if (Test-Path -LiteralPath $highSchool -PathType Container) {
    Assert-Condition (@(Get-ChildItem -LiteralPath $highSchool -File -Filter '*.md').Count -ge 3) 'High-school corpus must contain at least three synthetic works.'
}
if (Test-Path -LiteralPath $adult -PathType Container) {
    Assert-Condition (@(Get-ChildItem -LiteralPath $adult -File -Filter '*.md').Count -ge 1) 'Adult-contrast corpus must contain a synthetic work.'
}
if (Test-Path -LiteralPath $sealed -PathType Container) {
    Assert-Condition (@(Get-ChildItem -LiteralPath $sealed -File -Filter '*.md').Count -ge 1) 'Sealed corpus must contain a synthetic work.'
}

1..9 | ForEach-Object {
    $caseId = '{0:D2}' -f $_
    $casesDirectory = Join-Path $RepositoryRoot 'evals/cases'
    $matches = if (Test-Path -LiteralPath $casesDirectory -PathType Container) {
        @(Get-ChildItem -LiteralPath $casesDirectory -Filter "$caseId-*.md" -File)
    } else { @() }
    Assert-Condition (@($matches).Count -eq 1) "Expected exactly one case file for case $caseId."
    if (@($matches).Count -eq 1) {
        $content = Get-Content -LiteralPath @($matches)[0].FullName -Raw
        @('# ', '## User request', '## Accessible files', '## Forbidden state', '## Observable assertions') | ForEach-Object {
            Assert-Condition ($content.Contains($_)) "Case $caseId is missing required heading: $_"
        }
    }
}

$rubric = Get-RequiredFile 'evals/rubric.md'
if (Test-Path -LiteralPath $rubric -PathType Leaf) {
    $rubricItems = @(Select-String -LiteralPath $rubric -Pattern '^([1-9]|1[0-7])\.\s+' -AllMatches)
    Assert-Condition ($rubricItems.Count -eq 17) "Rubric must contain exactly 17 numbered scoring items; found $($rubricItems.Count)."
}

$sandboxIgnore = Get-RequiredFile 'evals/sandboxes/.gitignore'
if (Test-Path -LiteralPath $sandboxIgnore -PathType Leaf) {
    Assert-Condition (((Get-Content -LiteralPath $sandboxIgnore -Raw).Trim() -replace "`r`n", "`n") -eq "*`n!.gitignore") 'evals/sandboxes/.gitignore must ignore every sandbox artifact except itself.'
}
$logsIgnore = Get-RequiredFile 'evals/logs/.gitignore'
if (Test-Path -LiteralPath $logsIgnore -PathType Leaf) {
    Assert-Condition (((Get-Content -LiteralPath $logsIgnore -Raw).Trim() -replace "`r`n", "`n") -eq "*`n!.gitignore`n!README.md") 'evals/logs/.gitignore must retain only its policy files.'
}

@(
    'evals/scripts/Invoke-Baseline.ps1',
    'evals/scripts/Invoke-EvalValidation.ps1',
    'evals/logs/README.md',
    'evals/results/baseline-summary.md'
) | ForEach-Object { [void](Get-RequiredFile $_) }

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Output "FAIL: $_" }
    throw "Evaluation structure validation failed with $($failures.Count) issue(s)."
}

Write-Output 'Evaluation structure validation passed.'
