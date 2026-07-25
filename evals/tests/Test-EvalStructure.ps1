Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'TestSupport.psm1') -Force
$repoRoot = Get-MeechoRepoRoot

$requiredFiles = @(
    'evals/capsule/README.md',
    'evals/capsule/config.toml',
    'evals/results/baseline-summary.md',
    'evals/scripts/Initialize-EvalCapsule.ps1',
    'evals/scripts/EvalCapsule.psm1',
    'evals/scripts/EvalAudit.psm1',
    'evals/scripts/CaseStaging.psm1',
    'evals/scripts/Invoke-Baseline.ps1',
    'evals/scripts/Invoke-PairedEvaluation.ps1',
    'evals/scripts/Invoke-EvalValidation.ps1',
    'evals/scripts/Invoke-Task1Tests.ps1',
    'evals/scripts/Update-BaselineSummary.ps1',
    'evals/logs/.gitignore',
    'evals/logs/README.md',
    'evals/rubric.md'
)

foreach ($relativePath in $requiredFiles) {
    Assert-True (Test-Path -LiteralPath (Join-Path $repoRoot $relativePath) -PathType Leaf) "Missing required file: $relativePath"
}

$caseFiles = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'evals/cases') -Filter '*.md' -File | Sort-Object Name)
Assert-Equal 9 $caseFiles.Count 'Exactly nine behavior cases must exist.'

$expectedScenarios = [ordered]@{
    '01-missing-profile.md'               = @('read')
    '02-build-global-profile.md'          = @('allow', 'deny')
    '03-cross-project-use.md'             = @('read')
    '04-explicit-only.md'                 = @('read')
    '05-chat-only-output.md'              = @('read')
    '06-adult-contrast-and-sealed.md'     = @('read')
    '07-explicit-preference-update.md'    = @('allow', 'deny')
    '08-public-example-export.md'         = @('allow', 'deny')
    '09-profile-management-and-schema.md' = @(
        'status-read',
        'unknown-schema-read',
        'old-schema-read',
        'illegal-profile-id-read',
        'path-traversal-read',
        'delete-allow',
        'delete-deny'
    )
}

foreach ($caseFile in $caseFiles) {
    $text = Get-Content -LiteralPath $caseFile.FullName -Raw -Encoding UTF8
    foreach ($heading in '# ', '## User request', '## Accessible files', '## Forbidden state', '## Observable assertions') {
        Assert-True ($text.Contains($heading)) "$($caseFile.Name) is missing heading '$heading'."
    }

    $metadataMatch = [regex]::Match($text, '(?s)<!--\s*meecho-eval\s*(\{.*?\})\s*-->')
    Assert-True $metadataMatch.Success "$($caseFile.Name) must contain a meecho-eval JSON metadata block."
    $metadata = $metadataMatch.Groups[1].Value | ConvertFrom-Json -Depth 20
    $scenarioIds = @($metadata.scenarios | ForEach-Object { $_.id })
    Assert-SequenceEqual $expectedScenarios[$caseFile.Name] $scenarioIds "$($caseFile.Name) scenario declarations changed."
    foreach ($scenario in $metadata.scenarios) {
        Assert-True ($scenario.permissionMode -in @('read', 'allow', 'deny')) "$($caseFile.Name) has an invalid permission mode."
        $expectedPermission = if ($scenario.id -match 'allow$') {
            'allow'
        }
        elseif ($scenario.id -match 'deny$') {
            'deny'
        }
        else {
            'read'
        }
        Assert-Equal $expectedPermission $scenario.permissionMode "$($caseFile.Name) scenario permission does not match its declared behavior."
    }
}

$rubric = Get-Content -LiteralPath (Join-Path $repoRoot 'evals/rubric.md') -Encoding UTF8
$rubricItems = @($rubric | Where-Object { $_ -match '^\d+\.\s' })
Assert-Equal 17 $rubricItems.Count 'The baseline rubric must contain exactly 17 numbered items.'

$families = [ordered]@{
    'high-school'    = 3
    'adult-contrast' = 1
    'sealed'         = 1
}
foreach ($entry in $families.GetEnumerator()) {
    $familyRoot = Join-Path $repoRoot "evals/fixtures/synthetic-corpus/$($entry.Key)"
    Assert-True (Test-Path -LiteralPath $familyRoot -PathType Container) "Missing synthetic family: $($entry.Key)"
    Assert-True (@(Get-ChildItem -LiteralPath $familyRoot -File).Count -ge $entry.Value) "Synthetic family $($entry.Key) has too few documents."
}

$config = Get-Content -LiteralPath (Join-Path $repoRoot 'evals/capsule/config.toml') -Raw -Encoding UTF8
foreach ($required in @(
    'history.persistence = "none"',
    'web_search = "disabled"',
    'cli_auth_credentials_store = "file"',
    'allow_login_shell = false',
    'model_reasoning_effort = "high"',
    'personality = "none"',
    '[features]',
    'apps = false',
    'multi_agent = false',
    '[shell_environment_policy]',
    'inherit = "core"',
    '[permissions.meecho-capsule-read.filesystem]',
    '[permissions.meecho-capsule-allow.filesystem]',
    '[permissions.meecho-capsule-deny.filesystem]'
)) {
    Assert-True ($config.Contains($required)) "Capsule config is missing: $required"
}

Assert-False (Test-Path -LiteralPath (Join-Path $repoRoot 'evals/sandboxes')) 'The legacy repository sandbox directory must not exist.'

$logIgnore = Get-Content -LiteralPath (Join-Path $repoRoot 'evals/logs/.gitignore') -Raw -Encoding UTF8
Assert-True ($logIgnore.Contains('*')) 'Raw run logs must be ignored.'
Assert-True ($logIgnore.Contains('!README.md')) 'The log contract README must remain tracked.'

Write-Output 'PASS Test-EvalStructure'
