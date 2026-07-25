[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('control', 'treatment')]
    [string] $Mode,

    [switch] $Login
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'EvalCapsule.psm1') -Force

$runId = (
    (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ') +
    '-' +
    [guid]::NewGuid().ToString('N').Substring(0, 8)
)
$contexts = @(
    foreach ($permissionMode in @('read', 'allow', 'deny')) {
        New-MeechoEvalContext `
            -Mode $Mode `
            -RunId $runId `
            -CaseId preflight `
            -ScenarioId $permissionMode `
            -Model 'preflight-capability-only' `
            -ReasoningEffort high `
            -PermissionMode $permissionMode
    }
)
$loginContext = $contexts[0]

$module = Get-Module EvalCapsule -ErrorAction Stop
$loginResult = $null
if ($Login) {
    $loginResult = & $module {
        param($EvalContext)
        Invoke-MeechoEvalLogin -Context $EvalContext
    } $loginContext
}

if ($loginResult -and (
    -not $loginResult.Started -or
    $loginResult.TimedOut -or
    $loginResult.ExitCode -ne 0
)) {
    $failureCode = if ($loginResult.FailureCode) {
        $loginResult.FailureCode
    }
    else {
        'CLI_LOGIN_FAILED'
    }
    $preflight = [pscustomobject] [ordered] @{
        Passed = $false
        Status = 'BLOCKED_NOT_RUN'
        Checks = @(
            [pscustomobject] [ordered] @{
                Name = 'isolated-login'
                Passed = $false
                Detail = $failureCode
            }
        )
        Failures = @($failureCode)
    }
    $scenarioResults = @()
}
else {
    $scenarioResults = [Collections.Generic.List[object]]::new()
    foreach ($context in $contexts) {
        $result = Test-MeechoEvalPreflight -Context $context
        $scenarioResults.Add([pscustomobject] [ordered] @{
            ScenarioId = $context.ScenarioId
            PermissionMode = $context.PermissionMode
            Passed = $result.Passed
            Status = $result.Status
            Checks = @($result.Checks)
            Failures = @($result.Failures)
            StepLogRoot = $context.StepLogRoot
        })
        if (-not $result.Passed) {
            break
        }
    }

    $firstFailure = @($scenarioResults | Where-Object { -not $_.Passed }) |
        Select-Object -First 1
    $allReady = $scenarioResults.Count -eq 3 -and -not $firstFailure
    $aggregateChecks = @(
        foreach ($scenario in $scenarioResults) {
            foreach ($check in $scenario.Checks) {
                [pscustomobject] [ordered] @{
                    Name = "$($scenario.ScenarioId)/$($check.Name)"
                    Passed = $check.Passed
                    Detail = $check.Detail
                }
            }
        }
    )
    $preflight = [pscustomobject] [ordered] @{
        Passed = $allReady
        Status = if ($allReady) { 'ready' } else { $firstFailure.Status }
        Checks = $aggregateChecks
        Failures = if ($allReady) { @() } else { @($firstFailure.Failures) }
    }
}

$environmentNames = @()
try {
    $environmentNames = @(
        & $module {
            param($EvalContext)
            Get-MeechoChildEnvironmentNames -Context $EvalContext
        } $loginContext
    )
}
catch {
    # The preflight result already records a missing or unlaunchable CLI.
}

$manifestPath = Join-Path $loginContext.StepLogRoot 'preflight-manifest.json'
$manifest = [ordered] @{
    schemaVersion = 1
    kind = 'meecho-eval-capsule-preflight'
    runId = $runId
    mode = $Mode
    status = $preflight.Status
    configSha256 = $loginContext.ConfigSha256
    environmentNames = @($environmentNames)
    checks = @($preflight.Checks)
    failures = @($preflight.Failures)
    scenarios = @($scenarioResults)
}
$manifest |
    ConvertTo-Json -Depth 30 |
    Set-Content -LiteralPath $manifestPath -Encoding UTF8

Write-Output $preflight.Status
if (-not $preflight.Passed) {
    if ($preflight.Status -ceq 'AUTH_REQUIRED') {
        exit 2
    }
    exit 3
}
