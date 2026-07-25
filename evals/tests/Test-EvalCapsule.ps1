Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'TestSupport.psm1') -Force
$repoRoot = Get-MeechoRepoRoot
$modulePath = Join-Path $repoRoot 'evals/scripts/EvalCapsule.psm1'
Import-Module $modulePath -Force
Import-Module (Join-Path $repoRoot 'evals/scripts/EvalAudit.psm1') -Force

$expectedExports = @(
    'Invoke-MeechoEvalCase',
    'New-MeechoEvalContext',
    'Remove-MeechoEvalRun',
    'Test-MeechoEvalPreflight'
)
$actualExports = @((Get-Module EvalCapsule).ExportedFunctions.Keys | Sort-Object)
Assert-SequenceEqual $expectedExports $actualExports 'EvalCapsule must expose only the four planned public functions.'

$testRoot = New-MeechoTestRoot
$previousLocalAppData = $env:LOCALAPPDATA
$previousUserProfile = $env:USERPROFILE
$previousHome = $env:HOME
try {
    $env:LOCALAPPDATA = $testRoot
    $controlledUserProfile = Join-Path $testRoot 'controlled-real-user-home'
    $controlledHome = Join-Path $testRoot 'controlled-home'
    New-Item -ItemType Directory -Path $controlledUserProfile | Out-Null
    New-Item -ItemType Directory -Path $controlledHome | Out-Null
    $env:USERPROFILE = $controlledUserProfile
    $env:HOME = $controlledHome
    $runId = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)

    $capsuleModule = Get-Module EvalCapsule
    $realHomeRoots = @(& $capsuleModule {
        Get-MeechoRealHomeRoots
    })
    Assert-SequenceEqual @(
        [IO.Path]::GetFullPath($controlledUserProfile).TrimEnd('\', '/'),
        [IO.Path]::GetFullPath($controlledHome).TrimEnd('\', '/')
    ) @($realHomeRoots) 'Distinct USERPROFILE and HOME roots must both receive a real-home deny canary.'
    $splitMarkerValues = @(
        ('split-userprofile-' + [guid]::NewGuid().ToString('N'))
        ('split-home-' + [guid]::NewGuid().ToString('N'))
    )
    $splitMarkers = @(& $capsuleModule {
        param($Roots, $Values)
        New-MeechoRealHomeCanaryMarkers `
            -UserProfileRoots $Roots `
            -MarkerValues $Values
    } $realHomeRoots $splitMarkerValues)
    Assert-Equal 2 $splitMarkers.Count 'Each distinct real-home root must receive its own marker.'
    for ($splitIndex = 0; $splitIndex -lt $splitMarkers.Count; $splitIndex++) {
        Assert-Equal $realHomeRoots[$splitIndex] (
            $splitMarkers[$splitIndex].UserProfileRoot
        ) 'A split-home marker was attached to the wrong real root.'
        Assert-Equal $splitMarkerValues[$splitIndex] (
            [IO.File]::ReadAllText(
                $splitMarkers[$splitIndex].MarkerPath,
                [Text.UTF8Encoding]::new($false, $true)
            )
        ) 'A split-home marker did not contain its independent random value.'
    }
    foreach ($splitMarker in $splitMarkers) {
        $splitCleanupPassed = & $capsuleModule {
            param($Marker)
            Remove-MeechoRealHomeCanaryMarker `
                -UserProfileRoot $Marker.UserProfileRoot `
                -MarkerDirectoryPath $Marker.MarkerDirectoryPath `
                -MarkerPath $Marker.MarkerPath
        } $splitMarker
        Assert-True $splitCleanupPassed 'A split-home marker did not clean up exactly.'
    }

    $contexts = @(
        New-MeechoEvalContext -Mode control -RunId $runId -CaseId case-01 -ScenarioId read -Model 'gpt-test' -ReasoningEffort high -PermissionMode read
        New-MeechoEvalContext -Mode control -RunId $runId -CaseId case-01 -ScenarioId allow -Model 'gpt-test' -ReasoningEffort high -PermissionMode allow
        New-MeechoEvalContext -Mode control -RunId $runId -CaseId case-01 -ScenarioId deny -Model 'gpt-test' -ReasoningEffort high -PermissionMode deny
        New-MeechoEvalContext -Mode control -RunId $runId -CaseId case-02 -ScenarioId read -Model 'gpt-test' -ReasoningEffort high -PermissionMode read
        New-MeechoEvalContext -Mode treatment -RunId $runId -CaseId case-01 -ScenarioId read -Model 'gpt-test' -ReasoningEffort high -PermissionMode read
    )

    $expectedFields = @(
        'Mode', 'RunId', 'CaseId', 'ScenarioId', 'CapsuleRoot', 'CodexHome',
        'CodexSqliteHome', 'RunRoot', 'CaseRoot', 'ScenarioRoot',
        'ScenarioUserHome', 'ScenarioWorkspace', 'ScenarioTemp',
        'WorkspaceRoots', 'StepLogRoot', 'Model', 'ReasoningEffort',
        'PermissionMode', 'ConfigSha256'
    )
    Assert-SequenceEqual $expectedFields @($contexts[0].PSObject.Properties.Name) 'Context fields or field order changed.'

    $capsuleRoot = Join-Path $testRoot 'MeechoDev/eval'
    foreach ($context in $contexts) {
        Assert-PathUnder $context.ScenarioRoot $capsuleRoot 'Every scenario must be outside the repository and under the capsule root.'
        Assert-PathUnder $context.CodexSqliteHome $context.ScenarioRoot 'SQLite state must be scenario-local.'
        Assert-PathUnder $context.ScenarioUserHome $context.ScenarioRoot 'Virtual home must be scenario-local.'
        Assert-PathUnder $context.ScenarioWorkspace $context.ScenarioRoot 'Workspace must be scenario-local.'
        Assert-PathUnder $context.ScenarioTemp $context.ScenarioRoot 'Temp must be scenario-local.'
        Assert-PathUnder $context.StepLogRoot (Join-Path $repoRoot 'evals/logs') 'Step logs must use the ignored local log tree.'
        Assert-True (Test-Path -LiteralPath $context.CodexSqliteHome -PathType Container) 'SQLite directory was not created.'
        Assert-True (Test-Path -LiteralPath $context.ScenarioUserHome -PathType Container) 'Virtual home was not created.'
        Assert-True (Test-Path -LiteralPath $context.ScenarioWorkspace -PathType Container) 'Workspace was not created.'
        Assert-True (Test-Path -LiteralPath $context.ScenarioTemp -PathType Container) 'Temp directory was not created.'
        Assert-True (Test-Path -LiteralPath (Join-Path $context.CodexHome 'config.toml') -PathType Leaf) 'Effective config was not copied.'
        Assert-Equal $context.ConfigSha256 ((Get-FileHash -LiteralPath (Join-Path $context.CodexHome 'config.toml') -Algorithm SHA256).Hash.ToLowerInvariant()) 'Config hash must describe the effective copied config.'
    }

    $scenarioRoots = @($contexts | ForEach-Object ScenarioRoot)
    Assert-Equal $scenarioRoots.Count @($scenarioRoots | Sort-Object -Unique).Count 'Every mode/case/scenario must have a unique scenario root.'
    foreach ($field in 'CodexSqliteHome', 'ScenarioUserHome', 'ScenarioWorkspace', 'ScenarioTemp', 'StepLogRoot') {
        $values = @($contexts | ForEach-Object { $_.$field })
        Assert-Equal $values.Count @($values | Sort-Object -Unique).Count "$field must be unique per mode/case/scenario."
    }
    Assert-Equal 2 @($contexts | ForEach-Object CodexHome | Sort-Object -Unique).Count 'Codex home must be isolated by mode, not by scenario.'
    Assert-Equal 1 @($contexts | ForEach-Object RunRoot | Sort-Object -Unique).Count 'One pair run id must share one run root.'

    $readContext = $contexts[0]
    $allowContext = $contexts[1]
    Assert-SequenceEqual @($readContext.ScenarioWorkspace) @($readContext.WorkspaceRoots) 'Read mode must expose only the scenario workspace as writable.'
    Assert-SequenceEqual @($allowContext.ScenarioWorkspace, $allowContext.ScenarioUserHome) @($allowContext.WorkspaceRoots) 'Allow mode must add only the scenario virtual home.'

    Assert-Throws { New-MeechoEvalContext -Mode control -RunId $runId -CaseId case-01 -ScenarioId 'Read' -Model x -ReasoningEffort high -PermissionMode read } 'Uppercase scenario ids must fail.'
    Assert-Throws { New-MeechoEvalContext -Mode control -RunId $runId -CaseId case-01 -ScenarioId 'read--again' -Model x -ReasoningEffort high -PermissionMode read } 'Double hyphens must fail.'
    Assert-Throws { New-MeechoEvalContext -Mode control -RunId $runId -CaseId case-01 -ScenarioId '../escape' -Model x -ReasoningEffort high -PermissionMode read } 'Traversal scenario ids must fail.'
    Assert-Throws { New-MeechoEvalContext -Mode control -RunId 'not-a-run' -CaseId case-01 -ScenarioId read -Model x -ReasoningEffort high -PermissionMode read } 'Invalid run ids must fail.'
    Assert-Throws { New-MeechoEvalContext -Mode control -RunId $runId -CaseId case-1 -ScenarioId read -Model x -ReasoningEffort high -PermissionMode read } 'Invalid case ids must fail.'

    # Breaks caught: a canary that touches the real .meecho tree, returns its
    # secret, accepts leaked/changed evidence, follows a reparse root, or
    # recursively deletes an unexpected file.
    # Breaks caught: control mode only checking Meecho-looking paths, reading
    # sensitive stores, leaking detection details, or following a reparse.
    $controlScan = & $capsuleModule {
        param($CodexHome)
        Test-MeechoControlHomeClean -CodexHome $CodexHome
    } $readContext.CodexHome
    Assert-SequenceEqual @('Passed', 'FailureCode') @(
        $controlScan.PSObject.Properties.Name
    ) 'Control Meecho-off scan must return only a strict bool and stable failure code.'
    Assert-True (
        $controlScan.Passed -is [bool]
    ) 'Control Meecho-off Passed must be a strict boolean.'
    Assert-True $controlScan.Passed 'A clean control Codex home was rejected.'
    Assert-Equal '' $controlScan.FailureCode 'A clean control scan returned a failure code.'

    $pathNamedSkillRoot = Join-Path $readContext.CodexHome 'skills/meecho'
    New-Item -ItemType Directory -Path $pathNamedSkillRoot -Force | Out-Null
    Set-Content `
        -LiteralPath (Join-Path $pathNamedSkillRoot 'SKILL.md') `
        -Value 'ordinary unrelated skill text' `
        -NoNewline `
        -Encoding UTF8
    $pathNamedScan = & $capsuleModule {
        param($CodexHome)
        Test-MeechoControlHomeClean -CodexHome $CodexHome
    } $readContext.CodexHome
    Assert-False $pathNamedScan.Passed 'skills/meecho/SKILL.md must fail the control Meecho-off scan.'
    Assert-Equal 'CONTROL_CONTAINS_MEECHO' (
        $pathNamedScan.FailureCode
    ) 'Meecho path detection returned an unstable failure code.'
    Remove-Item -LiteralPath (Join-Path $readContext.CodexHome 'skills') -Recurse -Force

    $neutralSkillRoot = Join-Path $readContext.CodexHome 'skills/voice'
    New-Item -ItemType Directory -Path $neutralSkillRoot -Force | Out-Null
    $neutralSkillPath = Join-Path $neutralSkillRoot 'SKILL.md'
    Set-Content `
        -LiteralPath $neutralSkillPath `
        -Value 'Use $meecho:meecho for this request.' `
        -NoNewline `
        -Encoding UTF8
    $contentTokenScan = & $capsuleModule {
        param($CodexHome)
        Test-MeechoControlHomeClean -CodexHome $CodexHome
    } $readContext.CodexHome
    Assert-False $contentTokenScan.Passed 'A path-neutral SKILL.md containing $meecho:meecho must fail.'
    Assert-Equal 'CONTROL_CONTAINS_MEECHO' (
        $contentTokenScan.FailureCode
    ) 'Meecho token detection returned an unstable failure code.'

    Set-Content `
        -LiteralPath $neutralSkillPath `
        -Value 'This configuration loads the Meecho plugin.' `
        -NoNewline `
        -Encoding UTF8
    $contentReferenceScan = & $capsuleModule {
        param($CodexHome)
        Test-MeechoControlHomeClean -CodexHome $CodexHome
    } $readContext.CodexHome
    Assert-False $contentReferenceScan.Passed 'A path-neutral Meecho plugin reference must fail.'
    Assert-Equal 'CONTROL_CONTAINS_MEECHO' (
        $contentReferenceScan.FailureCode
    ) 'Meecho plugin reference returned an unstable failure code.'

    foreach ($metadataFixture in @(
        [pscustomobject]@{
            Name = 'Skill YAML name'
            Content = "---`nname: meecho`ndescription: prose voice rewrite`n---"
        },
        [pscustomobject]@{
            Name = 'Plugin JSON name'
            Content = '{"name":"meecho","version":"1.0.0"}'
        },
        [pscustomobject]@{
            Name = 'Enabled skills TOML'
            Content = 'enabled_skills = ["meecho"]'
        }
    )) {
        Set-Content `
            -LiteralPath $neutralSkillPath `
            -Value $metadataFixture.Content `
            -NoNewline `
            -Encoding UTF8
        $metadataScan = & $capsuleModule {
            param($CodexHome)
            Test-MeechoControlHomeClean -CodexHome $CodexHome
        } $readContext.CodexHome
        Assert-False $metadataScan.Passed "$($metadataFixture.Name) must fail the control Meecho-off scan."
        Assert-Equal 'CONTROL_CONTAINS_MEECHO' (
            $metadataScan.FailureCode
        ) "$($metadataFixture.Name) returned an unstable failure code."
    }

    Set-Content `
        -LiteralPath $neutralSkillPath `
        -Value 'A general voice skill with no plugin dependency.' `
        -NoNewline `
        -Encoding UTF8
    $sensitiveNamedSkillRoot = Join-Path $readContext.CodexHome 'skills/secret'
    New-Item -ItemType Directory -Path $sensitiveNamedSkillRoot -Force | Out-Null
    Set-Content `
        -LiteralPath (Join-Path $sensitiveNamedSkillRoot 'SKILL.md') `
        -Value 'Use $meecho:meecho for this request.' `
        -NoNewline `
        -Encoding UTF8
    $sensitiveNamedSkillScan = & $capsuleModule {
        param($CodexHome)
        Test-MeechoControlHomeClean -CodexHome $CodexHome
    } $readContext.CodexHome
    Assert-False $sensitiveNamedSkillScan.Passed 'A load-bearing skill must not bypass scanning through a secret/token/session directory name.'
    Assert-Equal 'CONTROL_CONTAINS_MEECHO' (
        $sensitiveNamedSkillScan.FailureCode
    ) 'A sensitive-named load-bearing skill returned an unstable failure code.'
    Remove-Item -LiteralPath $sensitiveNamedSkillRoot -Recurse -Force

    Set-Content `
        -LiteralPath $neutralSkillPath `
        -Value 'A general voice skill with no plugin dependency.' `
        -NoNewline `
        -Encoding UTF8
    $sensitivePaths = @(
        (Join-Path $readContext.CodexHome 'auth.json'),
        (Join-Path $readContext.CodexHome 'secret-store.json'),
        (Join-Path $readContext.CodexHome 'session.json'),
        (Join-Path $readContext.CodexHome 'state.sqlite')
    )
    $sensitiveLocks = [Collections.Generic.List[IO.FileStream]]::new()
    try {
        foreach ($sensitivePath in $sensitivePaths) {
            Set-Content `
                -LiteralPath $sensitivePath `
                -Value 'synthetic sensitive value $meecho:meecho' `
                -NoNewline `
                -Encoding UTF8
            $sensitiveLocks.Add(
                [IO.File]::Open(
                    $sensitivePath,
                    [IO.FileMode]::Open,
                    [IO.FileAccess]::ReadWrite,
                    [IO.FileShare]::None
                )
            )
        }
        $sensitiveSkipScan = & $capsuleModule {
            param($CodexHome)
            Test-MeechoControlHomeClean -CodexHome $CodexHome
        } $readContext.CodexHome
        Assert-True $sensitiveSkipScan.Passed 'Sensitive auth/secret/session/sqlite stores were read or falsely flagged.'
        Assert-Equal '' (
            $sensitiveSkipScan.FailureCode
        ) 'Sensitive-store skipping returned a failure code.'
    }
    finally {
        foreach ($sensitiveLock in $sensitiveLocks) {
            $sensitiveLock.Dispose()
        }
        foreach ($sensitivePath in $sensitivePaths) {
            Remove-Item -LiteralPath $sensitivePath -Force
        }
    }

    $reparseTarget = Join-Path $testRoot 'control-scan-reparse-target'
    $reparsePath = Join-Path $readContext.CodexHome 'control-scan-link'
    New-Item -ItemType Directory -Path $reparseTarget | Out-Null
    New-Item -ItemType Junction -Path $reparsePath -Target $reparseTarget | Out-Null
    $reparseScan = & $capsuleModule {
        param($CodexHome)
        Test-MeechoControlHomeClean -CodexHome $CodexHome
    } $readContext.CodexHome
    Assert-False $reparseScan.Passed 'A reparse entry must fail closed.'
    Assert-Equal 'CONTROL_MEECHO_SCAN_UNSAFE' (
        $reparseScan.FailureCode
    ) 'Reparse rejection exposed an unstable or path-bearing failure.'
    Remove-Item -LiteralPath $reparsePath -Force
    Remove-Item -LiteralPath (Join-Path $readContext.CodexHome 'skills') -Recurse -Force

    $controlledMeechoRoot = Join-Path $controlledUserProfile '.meecho'
    New-Item -ItemType Directory -Path $controlledMeechoRoot | Out-Null
    $controlledMeechoSentinel = Join-Path $controlledMeechoRoot 'must-stay.txt'
    Set-Content -LiteralPath $controlledMeechoSentinel -Value 'untouched' -NoNewline -Encoding UTF8
    $controlledMeechoSentinelHash = (
        Get-FileHash -LiteralPath $controlledMeechoSentinel -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    $realHomeMarkerValue = 'controlled-real-home-secret-' + [guid]::NewGuid().ToString('N')
    $realHomeMarker = & $capsuleModule {
        param($UserProfileRoot, $MarkerValue)
        New-MeechoRealHomeCanaryMarker `
            -UserProfileRoot $UserProfileRoot `
            -MarkerValue $MarkerValue
    } $controlledUserProfile $realHomeMarkerValue

    Assert-SequenceEqual @(
        'UserProfileRoot',
        'MarkerDirectoryPath',
        'MarkerPath',
        'MarkerSha256'
    ) @($realHomeMarker.PSObject.Properties.Name) 'Real-home marker helper must not return marker contents.'
    Assert-Equal (
        [IO.Path]::GetFullPath($controlledUserProfile).TrimEnd('\', '/')
    ) (
        [IO.Path]::GetFullPath(
            (Split-Path -Parent $realHomeMarker.MarkerDirectoryPath)
        ).TrimEnd('\', '/')
    ) 'Real-home marker directory must be a direct child of the injected USERPROFILE.'
    Assert-Equal 'deny-read-marker.txt' (
        Split-Path -Leaf $realHomeMarker.MarkerPath
    ) 'Real-home marker must use the dedicated leaf name.'
    Assert-False (
        [IO.Path]::GetFullPath($realHomeMarker.MarkerPath).StartsWith(
            [IO.Path]::GetFullPath($controlledMeechoRoot) +
                [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase
        )
    ) 'Real-home deny marker must never be created inside the real .meecho tree.'
    Assert-Equal $realHomeMarkerValue (
        [IO.File]::ReadAllText(
            $realHomeMarker.MarkerPath,
            [Text.UTF8Encoding]::new($false, $true)
        )
    ) 'CreateNew marker contents changed.'
    Assert-Equal $realHomeMarker.MarkerSha256 (
        Get-FileHash -LiteralPath $realHomeMarker.MarkerPath -Algorithm SHA256
    ).Hash.ToLowerInvariant() 'Marker hash must describe the exact created file.'

    $forbiddenRoot = Join-Path $testRoot 'controlled-forbidden'
    New-Item -ItemType Directory -Path $forbiddenRoot | Out-Null
    $forbiddenPath = Join-Path $forbiddenRoot 'forbidden-secret.txt'
    $forbiddenMarkerValue = 'controlled-forbidden-secret'
    Set-Content -LiteralPath $forbiddenPath -Value $forbiddenMarkerValue -NoNewline -Encoding UTF8
    $forbiddenEvidencePath = Join-Path $contexts[0].ScenarioWorkspace 'forbidden-evidence.txt'
    $realHomeEvidencePath = Join-Path $contexts[0].ScenarioWorkspace 'real-home-evidence.txt'
    $deniedJsonl = @(
        ([ordered]@{
            type = 'item.completed'
            item = [ordered]@{
                id = 'item-forbidden'
                type = 'command_execution'
                command = "Get-Content -LiteralPath '$forbiddenPath'"
                aggregated_output = "Get-Content: permission denied: $forbiddenPath"
                exit_code = 1
                status = 'failed'
            }
        } | ConvertTo-Json -Compress -Depth 10),
        ([ordered]@{
            type = 'item.completed'
            item = [ordered]@{
                id = 'item-real-home'
                type = 'commandExecution'
                command = "Get-Content -LiteralPath '$($realHomeMarker.MarkerPath)'"
                aggregatedOutput = "Get-Content: access is denied: $($realHomeMarker.MarkerPath)"
                exitCode = 1
                status = 'failed'
            }
        } | ConvertTo-Json -Compress -Depth 10),
        '{"type":"turn.completed"}'
    ) -join "`n"
    $boundary = & $capsuleModule {
        param(
            $JsonlText,
            $FinalText,
            $StderrText,
            $ForbiddenPath,
            $ForbiddenMarkerValue,
            $ForbiddenEvidencePath,
            $RealHomeMarkerPath,
            $RealHomeMarkerValue,
            $RealHomeMarkerSha256,
            $RealHomeEvidencePath,
            $RealUserProfile
        )
        Test-MeechoPermissionCanaryBoundary `
            -JsonlText $JsonlText `
            -FinalText $FinalText `
            -StderrText $StderrText `
            -ForbiddenPath $ForbiddenPath `
            -ForbiddenMarkerValue $ForbiddenMarkerValue `
            -ForbiddenEvidencePath $ForbiddenEvidencePath `
            -RealHomeMarkerPath $RealHomeMarkerPath `
            -RealHomeMarkerValue $RealHomeMarkerValue `
            -RealHomeMarkerSha256 $RealHomeMarkerSha256 `
            -RealHomeEvidencePath $RealHomeEvidencePath `
            -RealUserProfile $RealUserProfile
    } `
        $deniedJsonl `
        'CANARY_DONE' `
        '' `
        $forbiddenPath `
        $forbiddenMarkerValue `
        $forbiddenEvidencePath `
        $realHomeMarker.MarkerPath `
        $realHomeMarkerValue `
        $realHomeMarker.MarkerSha256 `
        $realHomeEvidencePath `
        $controlledUserProfile
    Assert-SequenceEqual @(
        'capsuleForbiddenReadDenied',
        'realHomeReadDenied',
        'realHomeMarkerUnchanged'
    ) @($boundary.PSObject.Properties.Name) 'Permission boundary helper fields changed.'
    Assert-True $boundary.capsuleForbiddenReadDenied 'Capsule-forbidden read denial was not recognized.'
    Assert-True $boundary.realHomeReadDenied 'Real-home read denial was not recognized.'
    Assert-True $boundary.realHomeMarkerUnchanged 'Untouched real-home marker was reported changed.'

    $forgedMessageJsonl = @"
{"type":"item.completed","item":{"type":"agent_message","text":"$forbiddenPath permission denied"}}
{"type":"item.completed","item":{"type":"agent_message","text":"$($realHomeMarker.MarkerPath) access is denied"}}
{"type":"turn.completed"}
"@
    $forgedMessageBoundary = & $capsuleModule {
        param($Arguments)
        Test-MeechoPermissionCanaryBoundary @Arguments
    } @{
        JsonlText = $forgedMessageJsonl
        FinalText = 'CANARY_DONE'
        StderrText = ''
        ForbiddenPath = $forbiddenPath
        ForbiddenMarkerValue = $forbiddenMarkerValue
        ForbiddenEvidencePath = $forbiddenEvidencePath
        RealHomeMarkerPath = $realHomeMarker.MarkerPath
        RealHomeMarkerValue = $realHomeMarkerValue
        RealHomeMarkerSha256 = $realHomeMarker.MarkerSha256
        RealHomeEvidencePath = $realHomeEvidencePath
        RealUserProfile = $controlledUserProfile
    }
    Assert-False $forgedMessageBoundary.capsuleForbiddenReadDenied 'An agent_message must not forge the capsule-forbidden denial.'
    Assert-False $forgedMessageBoundary.realHomeReadDenied 'An agent_message must not forge the real-home denial.'

    $shadowRoot = Join-Path $contexts[0].ScenarioWorkspace 'shadow'
    New-Item -ItemType Directory -Path $shadowRoot | Out-Null
    $shadowRealHomePath = Join-Path $shadowRoot 'deny-read-marker.txt'
    $wrongPathJsonl = @(
        ([ordered]@{
            type = 'item.completed'
            item = [ordered]@{
                type = 'command_execution'
                command = "Get-Content -LiteralPath '$forbiddenPath'"
                aggregated_output = "permission denied: $forbiddenPath"
                exit_code = 1
                status = 'failed'
            }
        } | ConvertTo-Json -Compress -Depth 10),
        ([ordered]@{
            type = 'item.completed'
            item = [ordered]@{
                type = 'command_execution'
                command = "Get-Content -LiteralPath '$shadowRealHomePath'"
                aggregated_output = "permission denied: $shadowRealHomePath"
                exit_code = 1
                status = 'failed'
            }
        } | ConvertTo-Json -Compress -Depth 10),
        '{"type":"turn.completed"}'
    ) -join "`n"
    $wrongPathBoundary = & $capsuleModule {
        param($Arguments)
        Test-MeechoPermissionCanaryBoundary @Arguments
    } @{
        JsonlText = $wrongPathJsonl
        FinalText = 'CANARY_DONE'
        StderrText = ''
        ForbiddenPath = $forbiddenPath
        ForbiddenMarkerValue = $forbiddenMarkerValue
        ForbiddenEvidencePath = $forbiddenEvidencePath
        RealHomeMarkerPath = $realHomeMarker.MarkerPath
        RealHomeMarkerValue = $realHomeMarkerValue
        RealHomeMarkerSha256 = $realHomeMarker.MarkerSha256
        RealHomeEvidencePath = $realHomeEvidencePath
        RealUserProfile = $controlledUserProfile
    }
    Assert-True $wrongPathBoundary.capsuleForbiddenReadDenied 'The exact capsule-forbidden command should remain accepted.'
    Assert-False $wrongPathBoundary.realHomeReadDenied 'A same-leaf command against the wrong full path must not prove real-home denial.'

    $writeTarget = Join-Path $contexts[0].ScenarioUserHome '.meecho/write-attempt.txt'
    $writeDeniedJsonl = [ordered]@{
        type = 'item.completed'
        item = [ordered]@{
            type = 'command_execution'
            command = "Set-Content -LiteralPath '$writeTarget' -Value blocked"
            aggregated_output = "Set-Content: permission denied: $writeTarget"
            exit_code = 1
            status = 'failed'
        }
    } | ConvertTo-Json -Compress -Depth 10
    $writeDenied = & $capsuleModule {
        param($JsonlText, $TargetPath)
        Test-MeechoCommandDenialEvidence `
            -JsonlText $JsonlText `
            -TargetPath $TargetPath `
            -Operation write
    } $writeDeniedJsonl $writeTarget
    Assert-True $writeDenied 'A failed command_execution for the exact write target should prove denial.'
    $writeMessageOnly = [ordered]@{
        type = 'item.completed'
        item = [ordered]@{
            type = 'agent_message'
            text = "$writeTarget permission denied"
        }
    } | ConvertTo-Json -Compress -Depth 10
    $writeMessageDenied = & $capsuleModule {
        param($JsonlText, $TargetPath)
        Test-MeechoCommandDenialEvidence `
            -JsonlText $JsonlText `
            -TargetPath $TargetPath `
            -Operation write
    } $writeMessageOnly $writeTarget
    Assert-False $writeMessageDenied 'An agent_message must not forge a write denial.'
    $startedOnlyJsonl = [ordered]@{
        type = 'item.started'
        item = [ordered]@{
            type = 'command_execution'
            command = "Set-Content -LiteralPath '$writeTarget' -Value blocked"
            aggregated_output = "permission denied: $writeTarget"
            exit_code = 1
            status = 'failed'
        }
    } | ConvertTo-Json -Compress -Depth 10
    $startedOnlyDenied = & $capsuleModule {
        param($JsonlText, $TargetPath)
        Test-MeechoCommandDenialEvidence `
            -JsonlText $JsonlText `
            -TargetPath $TargetPath `
            -Operation write
    } $startedOnlyJsonl $writeTarget
    Assert-False $startedOnlyDenied 'item.started is not authoritative denial evidence.'
    $successfulCommandJsonl = [ordered]@{
        type = 'item.completed'
        item = [ordered]@{
            type = 'command_execution'
            command = "Set-Content -LiteralPath '$writeTarget' -Value blocked"
            aggregated_output = "permission denied: $writeTarget"
            exit_code = 0
            status = 'completed'
        }
    } | ConvertTo-Json -Compress -Depth 10
    $successfulCommandDenied = & $capsuleModule {
        param($JsonlText, $TargetPath)
        Test-MeechoCommandDenialEvidence `
            -JsonlText $JsonlText `
            -TargetPath $TargetPath `
            -Operation write
    } $successfulCommandJsonl $writeTarget
    Assert-False $successfulCommandDenied 'A successful command must not prove denial merely because its output contains denial words.'

    $leakedBoundary = & $capsuleModule {
        param($Arguments)
        Test-MeechoPermissionCanaryBoundary @Arguments
    } @{
        JsonlText = $deniedJsonl + "`n" + $realHomeMarkerValue
        FinalText = 'CANARY_DONE'
        StderrText = ''
        ForbiddenPath = $forbiddenPath
        ForbiddenMarkerValue = $forbiddenMarkerValue
        ForbiddenEvidencePath = $forbiddenEvidencePath
        RealHomeMarkerPath = $realHomeMarker.MarkerPath
        RealHomeMarkerValue = $realHomeMarkerValue
        RealHomeMarkerSha256 = $realHomeMarker.MarkerSha256
        RealHomeEvidencePath = $realHomeEvidencePath
        RealUserProfile = $controlledUserProfile
    }
    Assert-False $leakedBoundary.realHomeReadDenied 'Leaked marker content must fail the real-home denial check.'

    Set-Content -LiteralPath $forbiddenEvidencePath -Value $forbiddenMarkerValue -NoNewline -Encoding UTF8
    $forbiddenLeakBoundary = & $capsuleModule {
        param($Arguments)
        Test-MeechoPermissionCanaryBoundary @Arguments
    } @{
        JsonlText = $deniedJsonl
        FinalText = 'CANARY_DONE'
        StderrText = ''
        ForbiddenPath = $forbiddenPath
        ForbiddenMarkerValue = $forbiddenMarkerValue
        ForbiddenEvidencePath = $forbiddenEvidencePath
        RealHomeMarkerPath = $realHomeMarker.MarkerPath
        RealHomeMarkerValue = $realHomeMarkerValue
        RealHomeMarkerSha256 = $realHomeMarker.MarkerSha256
        RealHomeEvidencePath = $realHomeEvidencePath
        RealUserProfile = $controlledUserProfile
    }
    Assert-False $forbiddenLeakBoundary.capsuleForbiddenReadDenied 'A capsule-forbidden evidence file must fail the denial check.'
    Remove-Item -LiteralPath $forbiddenEvidencePath -Force

    Set-Content -LiteralPath $realHomeMarker.MarkerPath -Value 'changed' -NoNewline -Encoding UTF8
    $changedBoundary = & $capsuleModule {
        param($Arguments)
        Test-MeechoPermissionCanaryBoundary @Arguments
    } @{
        JsonlText = $deniedJsonl
        FinalText = 'CANARY_DONE'
        StderrText = ''
        ForbiddenPath = $forbiddenPath
        ForbiddenMarkerValue = $forbiddenMarkerValue
        ForbiddenEvidencePath = $forbiddenEvidencePath
        RealHomeMarkerPath = $realHomeMarker.MarkerPath
        RealHomeMarkerValue = $realHomeMarkerValue
        RealHomeMarkerSha256 = $realHomeMarker.MarkerSha256
        RealHomeEvidencePath = $realHomeEvidencePath
        RealUserProfile = $controlledUserProfile
    }
    Assert-False $changedBoundary.realHomeMarkerUnchanged 'Changed marker contents must fail the unchanged check.'
    Set-Content -LiteralPath $realHomeMarker.MarkerPath -Value $realHomeMarkerValue -NoNewline -Encoding UTF8

    $strictCanaryRecord = & $capsuleModule {
        param($Context, $MarkerSha256)
        New-MeechoPermissionCanaryRecord `
            -Context $Context `
            -PermissionMode read `
            -CanaryChecksPassed $true `
            -ExecutionExitCode 0 `
            -Detail 'controlled pass' `
            -Artifacts @('canary-prompt.md') `
            -CapsuleForbiddenReadDenied $true `
            -RealHomeReadDenied $true `
            -RealHomeMarkerUnchanged $true `
            -RealHomeMarkerCleanupPassed $true `
            -RealHomeMarkerSha256 $MarkerSha256
    } $readContext $realHomeMarker.MarkerSha256
    Assert-Equal 'PASS' $strictCanaryRecord.status 'All strict canary booleans should produce PASS.'
    foreach ($strictBooleanField in @(
        'capsuleForbiddenReadDenied',
        'realHomeReadDenied',
        'realHomeMarkerUnchanged',
        'realHomeMarkerCleanupPassed'
    )) {
        Assert-True (
            $strictCanaryRecord.$strictBooleanField -is [bool]
        ) "$strictBooleanField must be serialized from a strict boolean."
    }
    Assert-Equal $realHomeMarker.MarkerSha256 (
        $strictCanaryRecord.realHomeMarkerSha256
    ) 'Canary result must retain only the marker hash.'
    Assert-False (
        ($strictCanaryRecord | ConvertTo-Json -Depth 20).Contains(
            $realHomeMarkerValue
        )
    ) 'Canary result leaked marker contents.'

    $cleanupFailureRecord = & $capsuleModule {
        param($Context, $MarkerSha256)
        New-MeechoPermissionCanaryRecord `
            -Context $Context `
            -PermissionMode read `
            -CanaryChecksPassed $true `
            -ExecutionExitCode 0 `
            -Detail 'cleanup failed' `
            -Artifacts @('canary-prompt.md') `
            -CapsuleForbiddenReadDenied $true `
            -RealHomeReadDenied $true `
            -RealHomeMarkerUnchanged $true `
            -RealHomeMarkerCleanupPassed $false `
            -RealHomeMarkerSha256 $MarkerSha256
    } $readContext $realHomeMarker.MarkerSha256
    Assert-Equal 'BLOCKED_NOT_RUN' $cleanupFailureRecord.status 'A cleanup failure must never produce a passing canary result.'

    $unexpectedPath = Join-Path $realHomeMarker.MarkerDirectoryPath 'unexpected.txt'
    Set-Content -LiteralPath $unexpectedPath -Value 'must-not-be-recursively-deleted' -NoNewline -Encoding UTF8
    Assert-Throws {
        & $capsuleModule {
            param($Marker)
            Remove-MeechoRealHomeCanaryMarker `
                -UserProfileRoot $Marker.UserProfileRoot `
                -MarkerDirectoryPath $Marker.MarkerDirectoryPath `
                -MarkerPath $Marker.MarkerPath
        } $realHomeMarker
    } 'Cleanup must refuse a non-empty marker directory.' 'REAL_HOME_CANARY_DIRECTORY_NOT_EMPTY'
    Assert-True (Test-Path -LiteralPath $unexpectedPath -PathType Leaf) 'Canary cleanup recursively deleted an unexpected file.'
    Assert-False (Test-Path -LiteralPath $realHomeMarker.MarkerPath) 'Canary cleanup did not delete its exact owned marker.'
    Remove-Item -LiteralPath $unexpectedPath -Force
    $cleanupPassed = & $capsuleModule {
        param($Marker)
        Remove-MeechoRealHomeCanaryMarker `
            -UserProfileRoot $Marker.UserProfileRoot `
            -MarkerDirectoryPath $Marker.MarkerDirectoryPath `
            -MarkerPath $Marker.MarkerPath
    } $realHomeMarker
    Assert-True $cleanupPassed 'Exact marker plus empty-directory cleanup failed.'
    Assert-False (Test-Path -LiteralPath $realHomeMarker.MarkerDirectoryPath) 'Empty marker directory was not removed.'
    Assert-Equal $controlledMeechoSentinelHash (
        Get-FileHash -LiteralPath $controlledMeechoSentinel -Algorithm SHA256
    ).Hash.ToLowerInvariant() 'Real .meecho sentinel changed during marker lifecycle.'

    $reparseTarget = Join-Path $testRoot 'controlled-reparse-target'
    $reparseUserProfile = Join-Path $testRoot 'controlled-reparse-user-home'
    New-Item -ItemType Directory -Path $reparseTarget | Out-Null
    New-Item -ItemType Junction -Path $reparseUserProfile -Target $reparseTarget | Out-Null
    Assert-Throws {
        & $capsuleModule {
            param($UserProfileRoot)
            New-MeechoRealHomeCanaryMarker `
                -UserProfileRoot $UserProfileRoot `
                -MarkerValue 'must-not-be-created'
        } $reparseUserProfile
    } 'Marker creation must reject a reparse USERPROFILE.' 'REPARSE_POINT_REJECTED'
    Remove-Item -LiteralPath $reparseUserProfile -Force

    foreach ($permissionContext in $contexts[0..2]) {
        $preflight = Test-MeechoEvalPreflight -Context $permissionContext
        Assert-SequenceEqual @('Passed', 'Status', 'Checks', 'Failures') @($preflight.PSObject.Properties.Name) 'Preflight result fields changed.'
        Assert-True ($preflight.Status -in @('ready', 'AUTH_REQUIRED', 'BLOCKED_NOT_RUN')) 'Preflight returned an unknown status.'
        $canaryName = "permission-canary-$($permissionContext.PermissionMode)"
        $canaryCheck = @($preflight.Checks | Where-Object Name -eq $canaryName)
        if ($preflight.Status -eq 'ready') {
            Assert-Equal 1 $canaryCheck.Count "Ready preflight did not execute the real $canaryName."
            Assert-True $canaryCheck[0].Passed "Ready preflight claimed success although $canaryName failed."
        }
        else {
            Assert-Equal 0 @($canaryCheck | Where-Object Passed).Count "Non-ready preflight falsely recorded $canaryName as passed."
        }

        $stepRecords = @(Get-ChildItem -LiteralPath $permissionContext.StepLogRoot -Filter '*.record.json' -File -ErrorAction SilentlyContinue)
        Assert-True ($stepRecords.Count -ge 1) 'Even a blocked/auth preflight must persist per-step stdout/stderr/exit/timestamp records.'
        foreach ($recordPath in $stepRecords) {
            $record = Read-MeechoJson -Path $recordPath.FullName
            foreach ($artifactProperty in 'stdout', 'stderr', 'exitCodeArtifact') {
                Assert-True (Test-Path -LiteralPath (Join-Path $recordPath.DirectoryName $record.$artifactProperty.path) -PathType Leaf) "Preflight step record is missing $artifactProperty."
            }
            Assert-True (
                Test-MeechoStepRecord -RecordPath $recordPath.FullName
            ) 'Capsule step records must satisfy the shared audit schema.'
        }
    }

    Assert-Throws { Remove-MeechoEvalRun -RunId $runId } 'Run deletion requires an explicit confirmation switch.'
    Remove-MeechoEvalRun -RunId $runId -Confirm
    Assert-False (Test-Path -LiteralPath $contexts[0].RunRoot) 'Confirmed deletion must remove only the requested run.'
    Assert-True (Test-Path -LiteralPath $contexts[0].CodexHome) 'Run deletion must preserve the mode Codex home.'
}
finally {
    $env:LOCALAPPDATA = $previousLocalAppData
    $env:USERPROFILE = $previousUserProfile
    $env:HOME = $previousHome
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Output 'PASS Test-EvalCapsule'
