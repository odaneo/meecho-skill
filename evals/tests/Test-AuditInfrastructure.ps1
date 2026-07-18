[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $RepositoryRoot 'evals/scripts/EvalAudit.psm1'
if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
    throw 'The shared evaluation audit module is missing.'
}
Import-Module $modulePath -Force

function Assert-Condition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Test-CollisionAllocation {
    param([string]$Consumer)

    $root = Join-Path ([System.IO.Path]::GetTempPath()) "meecho-audit-$Consumer-$([guid]::NewGuid().ToString('N'))"
    try {
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'evals/logs') | Out-Null
        $collisionUtc = [datetime]::SpecifyKind([datetime]'2099-01-01T00:00:00', [DateTimeKind]::Utc)
        $collisionId = $collisionUtc.ToString('yyyyMMddTHHmmssZ')
        $oldRun = Join-Path $root "evals/logs/$collisionId"
        New-Item -ItemType Directory -Path $oldRun | Out-Null
        $sentinel = Join-Path $oldRun 'sentinel.txt'
        Set-Content -LiteralPath $sentinel -Value "untouched-$Consumer" -Encoding utf8
        $beforeHash = (Get-FileHash -LiteralPath $sentinel -Algorithm SHA256).Hash

        $times = [System.Collections.Generic.Queue[datetime]]::new()
        $times.Enqueue($collisionUtc)
        $times.Enqueue($collisionUtc.AddSeconds(1))
        $waited = [System.Collections.Generic.List[string]]::new()
        $nowProvider = { $times.Dequeue() }.GetNewClosure()
        $waitAction = { param([string]$RunId) $waited.Add($RunId) }.GetNewClosure()

        $allocated = New-EvalRunDirectory -RepositoryRoot $root -UtcNowProvider $nowProvider -WaitAction $waitAction
        Assert-Condition ($allocated.Id -eq '20990101T000001Z') "$Consumer reused the colliding run ID."
        Assert-Condition ($waited.Count -eq 1 -and $waited[0] -eq $collisionId) "$Consumer did not wait after the same-second collision."
        Assert-Condition ((Get-FileHash -LiteralPath $sentinel -Algorithm SHA256).Hash -eq $beforeHash) "$Consumer modified the old run directory."
        Assert-Condition (@(Get-ChildItem -LiteralPath $oldRun -Force).Count -eq 1) "$Consumer polluted the old run directory."
        Assert-Condition (Test-Path -LiteralPath (Join-Path $allocated.Path 'steps') -PathType Container) "$Consumer did not return a newly initialized run directory."
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

foreach ($consumer in 'Invoke-Baseline', 'Invoke-EvalValidation', 'Invoke-Task1Tests') {
    Test-CollisionAllocation -Consumer $consumer
}

$childPowerShell = Join-Path $PSHOME 'pwsh.exe'
$split = Invoke-EvalProcess -FilePath $childPowerShell -ArgumentList @(
    '-NoProfile',
    '-Command',
    "[Console]::Out.WriteLine('AUDIT-STDOUT'); [Console]::Error.WriteLine('AUDIT-STDERR')"
)
Assert-Condition ($split.ExitCode -eq 0) 'Deterministic child PowerShell failed.'
Assert-Condition (($split.Stdout -join "`n") -match '^AUDIT-STDOUT\s*$') 'stdout was not captured from the real stdout stream.'
Assert-Condition (($split.Stderr -join "`n") -match '^AUDIT-STDERR\s*$') 'stderr was not captured from the real stderr stream.'
Assert-Condition (($split.Stdout -join "`n") -notmatch 'AUDIT-STDERR') 'stderr leaked into stdout.'
Assert-Condition (($split.Stderr -join "`n") -notmatch 'AUDIT-STDOUT') 'stdout leaked into stderr.'
Assert-Condition ($split.StartedAtUtc -le $split.EndedAtUtc) 'Process timestamps are not ordered.'

function Write-JsonFile {
    param([object]$Value, [string]$Path)
    $Value | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding utf8
}

function New-ValidRunFixture {
    $fixture = Join-Path $RepositoryRoot "evals/logs/fixture-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path (Join-Path $fixture 'steps'), (Join-Path $fixture 'cases') | Out-Null
    $steps = @()
    $cases = @()
    $started = [datetimeoffset]'2099-01-01T00:00:00Z'
    $ended = [datetimeoffset]'2099-01-01T00:00:01Z'

    foreach ($number in 1..9) {
        $id = '{0:D2}' -f $number
        $stepLog = "steps/case-$id.log"
        Write-EvalStepLog -Path (Join-Path $fixture $stepLog) -Action "fixture case $id" -Stdout @("case-$id-output") -Stderr @() -ExitCode 0 -Conclusion 'passed' -StartedAtUtc $started -EndedAtUtc $ended
        $steps += [ordered]@{ name = "case-$id"; log = $stepLog; exitCode = 0; status = 'passed'; conclusion = 'passed' }
        $cases += [ordered]@{ caseId = $id; status = 'completed-needs-human-review'; exitCode = 0 }
        $caseDirectory = Join-Path $fixture "cases/$id"
        New-Item -ItemType Directory -Force -Path $caseDirectory | Out-Null
        Set-Content -LiteralPath (Join-Path $caseDirectory 'events.jsonl') -Value '{}' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $caseDirectory 'stderr.log') -Value '' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $caseDirectory 'final.md') -Value 'fixture final' -Encoding utf8
        Write-JsonFile -Path (Join-Path $caseDirectory 'result.json') -Value ([ordered]@{
            caseId = $id
            status = 'completed-needs-human-review'
            exitCode = 0
            observableAssertions = @([ordered]@{ id = "case-$id-observable-01"; text = 'fixture assertion'; status = 'needs-human-review' })
            rubric = @(1..17 | ForEach-Object { [ordered]@{ id = $_; score = 'needs-human-review' } })
        })
    }

    Write-JsonFile -Path (Join-Path $fixture 'run-manifest.json') -Value ([ordered]@{
        runId = '20990101T000000Z'
        startedAtUtc = $started.ToString('o')
        endedAtUtc = $ended.ToString('o')
        executionUser = 'fixture-user'
        gitCommit = 'fixture-commit'
        commandVersions = [ordered]@{ powershell = 'fixture' }
        isolationPrecheck = [ordered]@{ status = 'passed'; failures = @() }
        status = 'completed-needs-human-review'
        exitCode = 0
        steps = $steps
        cases = $cases
    })
    Write-EvalChecksums -RepositoryRoot $RepositoryRoot -RunDirectory $fixture
    return $fixture
}

function Invoke-Validator {
    param([string]$Fixture, [bool]$ShouldPass, [string]$Scenario)

    $validator = Join-Path $RepositoryRoot 'evals/scripts/Invoke-EvalValidation.ps1'
    $result = Invoke-EvalProcess -FilePath $childPowerShell -ArgumentList @(
        '-NoProfile', '-File', $validator, '-RepositoryRoot', $RepositoryRoot, '-VerifyRunDirectory', $Fixture
    )
    if ($ShouldPass) {
        Assert-Condition ($result.ExitCode -eq 0) "$Scenario was rejected: $($result.Stderr -join ' | ')"
    } else {
        Assert-Condition ($result.ExitCode -ne 0) "$Scenario was accepted."
    }
}

$fixture = New-ValidRunFixture
try {
    Invoke-Validator -Fixture $fixture -ShouldPass $true -Scenario 'A genuinely valid fixture'

    $firstStep = Join-Path $fixture 'steps/case-01.log'
    @(Get-Content -LiteralPath $firstStep | Where-Object { $_ -notlike 'action=*' }) |
        Set-Content -LiteralPath $firstStep -Encoding utf8
    Write-EvalChecksums -RepositoryRoot $RepositoryRoot -RunDirectory $fixture
    Invoke-Validator -Fixture $fixture -ShouldPass $false -Scenario 'A step log missing action'

    Write-EvalStepLog -Path $firstStep -Action 'fixture case 01' -Stdout @('case-01-output') -Stderr @() -ExitCode 0 -Conclusion 'passed' -StartedAtUtc ([datetimeoffset]'2099-01-01T00:00:00Z') -EndedAtUtc ([datetimeoffset]'2099-01-01T00:00:01Z')
    Write-EvalChecksums -RepositoryRoot $RepositoryRoot -RunDirectory $fixture
    $checksumPath = Join-Path $fixture 'checksums.sha256'
    $checksumLines = @(Get-Content -LiteralPath $checksumPath)
    $checksumLines[0] = $checksumLines[0] -replace '^[a-f0-9]{64}', ('0' * 64)
    $checksumLines | Set-Content -LiteralPath $checksumPath -Encoding utf8
    Invoke-Validator -Fixture $fixture -ShouldPass $false -Scenario 'A fake checksum'

    Write-EvalChecksums -RepositoryRoot $RepositoryRoot -RunDirectory $fixture
    $checksumLines = @(Get-Content -LiteralPath $checksumPath)
    $withoutRubric = @($checksumLines | Where-Object { $_ -notmatch '\s\sevals/rubric\.md$' })
    Assert-Condition ($withoutRubric.Count -eq ($checksumLines.Count - 1)) 'The fixture checksum set did not contain the required rubric input.'
    $withoutRubric | Set-Content -LiteralPath $checksumPath -Encoding utf8
    Invoke-Validator -Fixture $fixture -ShouldPass $false -Scenario 'A checksum set missing a required file'
} finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}

$failureTest = Join-Path ([System.IO.Path]::GetTempPath()) "meecho-deterministic-failure-$([guid]::NewGuid().ToString('N')).ps1"
try {
    @(
        "[Console]::Out.WriteLine('TASK-STDOUT')"
        "[Console]::Error.WriteLine('TASK-STDERR')"
        'exit 7'
    ) | Set-Content -LiteralPath $failureTest -Encoding utf8
    $taskRunner = Join-Path $RepositoryRoot 'evals/scripts/Invoke-Task1Tests.ps1'
    $taskResult = Invoke-EvalProcess -FilePath $childPowerShell -ArgumentList @(
        '-NoProfile', '-File', $taskRunner, '-RepositoryRoot', $RepositoryRoot, '-TestFiles', $failureTest
    )
    Assert-Condition ($taskResult.ExitCode -ne 0) 'The unified test runner returned success after a test failed.'
    $runMatch = [regex]::Match(($taskResult.Stdout -join "`n"), 'TASK1_TEST_RUN_ID=(\d{8}T\d{6}Z)')
    Assert-Condition $runMatch.Success 'The unified test runner did not report its run ID.'
    $taskRun = Join-Path $RepositoryRoot "evals/logs/$($runMatch.Groups[1].Value)"
    $taskManifest = Get-Content -LiteralPath (Join-Path $taskRun 'run-manifest.json') -Raw | ConvertFrom-Json
    Assert-Condition ($taskManifest.exitCode -eq 1 -and $taskManifest.status -eq 'failed') 'The unified test manifest did not preserve final failure.'
    $taskStep = Read-EvalStepLog -Path (Join-Path $taskRun $taskManifest.steps[0].log)
    Assert-Condition (($taskStep.Stdout -join "`n") -match 'TASK-STDOUT') 'The unified runner lost child stdout.'
    Assert-Condition (($taskStep.Stderr -join "`n") -match 'TASK-STDERR') 'The unified runner lost child stderr.'
    Assert-Condition (($taskStep.Stdout -join "`n") -notmatch 'TASK-STDERR') 'The unified runner mixed stderr into stdout.'
    Assert-Condition (($taskStep.Stderr -join "`n") -notmatch 'TASK-STDOUT') 'The unified runner mixed stdout into stderr.'
    Assert-Condition ($taskStep.ExitCode -eq 7) 'The unified runner step log lost the real child exit code.'
} finally {
    Remove-Item -LiteralPath $failureTest -Force -ErrorAction SilentlyContinue
}

Write-Output 'Shared audit infrastructure behavior passed.'
