Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'TestSupport.psm1') -Force
$repoRoot = Get-MeechoRepoRoot
Import-Module (Join-Path $repoRoot 'evals/scripts/EvalCapsule.psm1') -Force
Import-Module (Join-Path $repoRoot 'evals/scripts/CaseStaging.psm1') -Force
Import-Module (Join-Path $repoRoot 'evals/scripts/EvalAudit.psm1') -Force

$moduleText = Get-Content -LiteralPath (Join-Path $repoRoot 'evals/scripts/CaseStaging.psm1') -Raw -Encoding UTF8
Assert-False ($moduleText -match '(?is)Remove-Item\b[^\r\n]*-Recurse') 'Case staging must never recursively clear a caller-derived path.'

$casePath = Join-Path $repoRoot 'evals/cases/01-missing-profile.md'
$definition = Get-MeechoEvalCaseDefinition -Path $casePath
Assert-Equal 'case-01' $definition.CaseId 'Case metadata id was not parsed.'
Assert-SequenceEqual @('read') @($definition.Scenarios | ForEach-Object id) 'Case scenario metadata was not parsed.'

$testRoot = New-MeechoTestRoot
$previousLocalAppData = $env:LOCALAPPDATA
try {
    $env:LOCALAPPDATA = $testRoot
    $runId = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $readContext = New-MeechoEvalContext -Mode control -RunId $runId -CaseId case-01 -ScenarioId read -Model gpt-test -ReasoningEffort high -PermissionMode read
    $siblingContext = New-MeechoEvalContext -Mode control -RunId $runId -CaseId case-02 -ScenarioId allow -Model gpt-test -ReasoningEffort high -PermissionMode allow
    Set-Content -LiteralPath (Join-Path $siblingContext.ScenarioUserHome 'sibling-canary.txt') -Value 'must-not-cross' -Encoding UTF8

    $stage = Initialize-MeechoEvalScenario -Context $readContext -CasePath $casePath
    Assert-Equal 'case-01' $stage.CaseId 'Staging returned the wrong case.'
    Assert-Equal 'read' $stage.ScenarioId 'Staging returned the wrong scenario.'
    Assert-True (Test-Path -LiteralPath (Join-Path $readContext.ScenarioWorkspace '.git') -PathType Container) 'Scenario workspace must be an independent Git repository.'
    Assert-False (Test-Path -LiteralPath (Join-Path $readContext.ScenarioWorkspace 'sibling-canary.txt')) 'Sibling scenario state leaked into the workspace.'
    Assert-Equal 0 @(Get-ChildItem -LiteralPath $readContext.ScenarioWorkspace -Recurse -File | Where-Object { $_.FullName -match '[\\/]sealed[\\/]' }).Count 'Sealed corpus must never be staged as accessible input.'
    Assert-False (Test-Path -LiteralPath (Join-Path $readContext.ScenarioUserHome '.meecho')) 'The missing-profile case must start without a virtual profile.'

    $promptText = Get-Content -LiteralPath $stage.PromptPath -Raw -Encoding UTF8
    Assert-Equal $definition.UserRequest.Trim() $promptText.Trim() 'The model prompt must contain only the user request, not reviewer assertions or forbidden-state oracle text.'
    Assert-False ($promptText.Contains('Observable assertions')) 'Reviewer assertions leaked into the model prompt.'
    Assert-False ($promptText.Contains('Forbidden state')) 'Forbidden-state oracle text leaked into the model prompt.'

    $workspaceFiles = @(Get-ChildItem -LiteralPath $readContext.ScenarioWorkspace -Recurse -File -Force | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' })
    Assert-Equal @($definition.AccessibleFiles).Count $workspaceFiles.Count 'Workspace must contain only files declared by this case.'

    $nonEmptyContext = New-MeechoEvalContext -Mode control -RunId $runId -CaseId case-03 -ScenarioId read -Model gpt-test -ReasoningEffort high -PermissionMode read
    $roguePath = Join-Path $nonEmptyContext.ScenarioWorkspace 'do-not-delete.txt'
    Set-Content -LiteralPath $roguePath -Value 'preserve' -Encoding UTF8
    Assert-Throws { Initialize-MeechoEvalScenario -Context $nonEmptyContext -CasePath (Join-Path $repoRoot 'evals/cases/03-cross-project-use.md') } 'Staging must refuse a non-empty workspace instead of deleting it.'
    Assert-True (Test-Path -LiteralPath $roguePath -PathType Leaf) 'Refused staging must leave the pre-existing file intact.'

    $maliciousCase = Join-Path $testRoot 'malicious.md'
    @'
# Traversal case
<!-- meecho-eval
{"caseId":"case-01","scenarios":[{"id":"read","permissionMode":"read"}],"accessibleFiles":[{"source":"../rubric.md","destination":"escape.md"}]}
-->
## User request
x
## Accessible files
x
## Forbidden state
x
## Observable assertions
x
'@ | Set-Content -LiteralPath $maliciousCase -Encoding UTF8
    $maliciousContext = New-MeechoEvalContext -Mode treatment -RunId $runId -CaseId case-01 -ScenarioId read -Model gpt-test -ReasoningEffort high -PermissionMode read
    Assert-Throws { Initialize-MeechoEvalScenario -Context $maliciousContext -CasePath $maliciousCase } 'Fixture traversal must be rejected before copying.'

    $projectContext = New-MeechoEvalContext -Mode treatment -RunId $runId -CaseId case-03 -ScenarioId read -Model gpt-test -ReasoningEffort high -PermissionMode read
    $projectStage = Initialize-MeechoEvalScenario -Context $projectContext -CasePath (Join-Path $repoRoot 'evals/cases/03-cross-project-use.md')
    Assert-Equal 3 @($projectStage.ProjectRoots).Count 'Cross-project case must create three independent project roots.'
    foreach ($projectRoot in $projectStage.ProjectRoots) {
        Assert-True (Test-Path -LiteralPath (Join-Path $projectRoot '.git') -PathType Container) 'Every cross-project invocation needs its own Git repository.'
    }
    Assert-True (Test-Path -LiteralPath (Join-Path $projectContext.ScenarioUserHome '.meecho/profiles/high-school/manifest.json') -PathType Leaf) 'Cross-project case claims a preloaded profile but staging did not create it.'

    $explicitDefinition = Get-MeechoEvalCaseDefinition -Path (Join-Path $repoRoot 'evals/cases/04-explicit-only.md')
    Assert-Equal 3 @($explicitDefinition.Invocations).Count 'Explicit-trigger boundary must contain three fresh invocation prompts.'
    foreach ($invocation in $explicitDefinition.Invocations) {
        Assert-False ($invocation.prompt.Contains('$meecho:meecho')) 'A negative-trigger invocation must not contain the canonical Skill token.'
    }

    $rememberDefinition = Get-MeechoEvalCaseDefinition -Path (Join-Path $repoRoot 'evals/cases/07-explicit-preference-update.md')
    Assert-SequenceEqual @('ordinary-feedback', 'explicit-remember') @($rememberDefinition.Invocations | ForEach-Object Id) 'Remember boundary must execute ordinary feedback before the explicit remember request.'

    foreach ($fixtureCase in @(
        @{ CaseId = 'case-04'; ScenarioId = 'read'; PermissionMode = 'read' },
        @{ CaseId = 'case-05'; ScenarioId = 'read'; PermissionMode = 'read' },
        @{ CaseId = 'case-06'; ScenarioId = 'read'; PermissionMode = 'read' },
        @{ CaseId = 'case-08'; ScenarioId = 'allow'; PermissionMode = 'allow' },
        @{ CaseId = 'case-09'; ScenarioId = 'status-read'; PermissionMode = 'read' }
    )) {
        $fixtureContext = New-MeechoEvalContext -Mode control -RunId $runId -CaseId $fixtureCase.CaseId -ScenarioId $fixtureCase.ScenarioId -Model gpt-test -ReasoningEffort high -PermissionMode $fixtureCase.PermissionMode
        Initialize-MeechoEvalScenario -Context $fixtureContext -CasePath (Get-ChildItem -LiteralPath (Join-Path $repoRoot 'evals/cases') -Filter "$($fixtureCase.CaseId.Substring(5))-*.md" -File | Select-Object -First 1 -ExpandProperty FullName) | Out-Null
        Assert-True (Test-Path -LiteralPath (Join-Path $fixtureContext.ScenarioUserHome '.meecho/profiles/high-school/manifest.json') -PathType Leaf) "$($fixtureCase.CaseId) claims a preloaded profile but staging did not create it."
    }

    $rememberAllow = New-MeechoEvalContext -Mode control -RunId $runId -CaseId case-07 -ScenarioId allow -Model gpt-test -ReasoningEffort high -PermissionMode allow
    $rememberDeny = New-MeechoEvalContext -Mode control -RunId $runId -CaseId case-07 -ScenarioId deny -Model gpt-test -ReasoningEffort high -PermissionMode deny
    Initialize-MeechoEvalScenario -Context $rememberAllow -CasePath (Join-Path $repoRoot 'evals/cases/07-explicit-preference-update.md') | Out-Null
    Initialize-MeechoEvalScenario -Context $rememberDeny -CasePath (Join-Path $repoRoot 'evals/cases/07-explicit-preference-update.md') | Out-Null
    $allowProfile = Get-MeechoFileInventory -Path (Join-Path $rememberAllow.ScenarioUserHome '.meecho')
    $denyProfile = Get-MeechoFileInventory -Path (Join-Path $rememberDeny.ScenarioUserHome '.meecho')
    foreach ($item in $allowProfile) { $item.lastWriteTimeUtc = '' }
    foreach ($item in $denyProfile) { $item.lastWriteTimeUtc = '' }
    Assert-SequenceEqual $allowProfile $denyProfile 'Allow and deny scenarios must begin from identical virtual profile fixtures.'
    Assert-True (Test-Path -LiteralPath (Join-Path $rememberAllow.ScenarioUserHome '.meecho/profiles/high-school/preferences.md') -PathType Leaf) 'Remember case needs an existing preferences file.'

    Assert-True (Test-Path -LiteralPath (Join-Path $rememberAllow.ScenarioUserHome '.meecho/profiles/high-school/manifest.json') -PathType Leaf) 'Remember case profile manifest missing.'

    $unknownSchemaContext = New-MeechoEvalContext -Mode treatment -RunId $runId -CaseId case-09 -ScenarioId unknown-schema-read -Model gpt-test -ReasoningEffort high -PermissionMode read
    Initialize-MeechoEvalScenario -Context $unknownSchemaContext -CasePath (Join-Path $repoRoot 'evals/cases/09-profile-management-and-schema.md') | Out-Null
    Assert-True (Test-Path -LiteralPath (Join-Path $unknownSchemaContext.ScenarioUserHome '.meecho/profiles/schema-unknown/manifest.json') -PathType Leaf) 'Unknown-schema scenario needs its own fixture.'
    Assert-False (Test-Path -LiteralPath (Join-Path $unknownSchemaContext.ScenarioUserHome '.meecho/profiles/schema-old/manifest.json')) 'Unknown-schema scenario must not share the old-schema fixture.'

    $oldSchemaContext = New-MeechoEvalContext -Mode treatment -RunId $runId -CaseId case-09 -ScenarioId old-schema-read -Model gpt-test -ReasoningEffort high -PermissionMode read
    Initialize-MeechoEvalScenario -Context $oldSchemaContext -CasePath (Join-Path $repoRoot 'evals/cases/09-profile-management-and-schema.md') | Out-Null
    Assert-True (Test-Path -LiteralPath (Join-Path $oldSchemaContext.ScenarioUserHome '.meecho/profiles/schema-old/manifest.json') -PathType Leaf) 'Old-schema scenario needs its own fixture.'
    Assert-False (Test-Path -LiteralPath (Join-Path $oldSchemaContext.ScenarioUserHome '.meecho/profiles/schema-unknown/manifest.json')) 'Old-schema scenario must not share the unknown-schema fixture.'

    $publicationContext = New-MeechoEvalContext -Mode treatment -RunId $runId -CaseId case-08 -ScenarioId deny -Model gpt-test -ReasoningEffort high -PermissionMode deny
    Initialize-MeechoEvalScenario -Context $publicationContext -CasePath (Join-Path $repoRoot 'evals/cases/08-public-example-export.md') | Out-Null
    Assert-True (Test-Path -LiteralPath (Join-Path $publicationContext.ScenarioUserHome '.meecho/profiles/high-school/publication-manifest.json') -PathType Leaf) 'Export case needs an approval/publication fixture.'
}
finally {
    $env:LOCALAPPDATA = $previousLocalAppData
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Output 'PASS Test-CaseIsolation'
