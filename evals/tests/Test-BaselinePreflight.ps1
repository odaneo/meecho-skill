Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'TestSupport.psm1') -Force
$repoRoot = Get-MeechoRepoRoot
$runnerPath = Join-Path $repoRoot 'evals/scripts/Invoke-Baseline.ps1'
Import-Module (Join-Path $repoRoot 'evals/scripts/EvalAudit.psm1') -Force

$runnerSource = Get-Content -LiteralPath $runnerPath -Raw -Encoding UTF8
Assert-False (
    $runnerSource -match '(?m)^\s*function\s+Write-BaselineManifest\b'
) 'Every parameter-failure terminal manifest must use the shared atomic manifest writer.'
Assert-False (
    $runnerSource -match '(?ms)Set-Content\s+-LiteralPath\s+\$manifestPath\b'
) 'No terminal manifest path may be written with Set-Content.'
Assert-Matches $runnerSource (
    '(?ms)\$profileAfterEvidence\s*=\s*Write-MeechoInventoryEvidence\s+' +
    '`?\s*-Inventory\s+\$profileAfter\s+`?\s*-Path\s+' +
    '\(Join-Path\s+\$context\.StepLogRoot\s+''profile-after-inventory\.json''\)'
) 'Each case must persist its terminal profile inventory at the fixed after path.'
Assert-Matches $runnerSource (
    '(?m)^\s*profileAfterSha256\s*=\s*\$profileAfterEvidence\.InventorySha256\s*$'
) 'result.profileAfterSha256 must come from the persisted after evidence.'
Assert-Matches $runnerSource (
    '(?m)^\s*finalProfileSha256\s*=\s*\$profileAfterEvidence\.InventorySha256\s*$'
) 'Each case must expose the same persisted terminal profile digest.'
Assert-Matches $runnerSource (
    '(?m)^\s*''profile-after-inventory''\s*=\s*\$profileAfterEvidence\.Path\s*$'
) 'Each case must register the fixed profile-after inventory artifact.'

function Assert-RealProfileInventoryEvidence {
    param(
        [Parameter(Mandatory)]
        [object] $Manifest,

        [Parameter(Mandatory)]
        [string] $Label
    )

    foreach ($phase in 'Before', 'After') {
        $referenceProperty = "realProfile${phase}Inventory"
        $digestProperty = "realProfile${phase}Sha256"
        $referenceEntry = $Manifest.PSObject.Properties[$referenceProperty]
        Assert-False ($null -eq $referenceEntry) "$Label must declare $referenceProperty."
        $reference = $referenceEntry.Value
        Assert-True (Test-Path -LiteralPath $reference.path -PathType Leaf) "$Label $phase inventory evidence is missing."
        Assert-Matches ([string]$reference.sha256) '^[a-f0-9]{64}$' "$Label $phase evidence needs a file hash."
        Assert-Equal ([string]$reference.sha256) (
            Get-FileHash -LiteralPath $reference.path -Algorithm SHA256
        ).Hash.ToLowerInvariant() "$Label $phase evidence file hash does not match."
        $inventory = @(
            Get-Content -LiteralPath $reference.path -Raw -Encoding UTF8 |
                ConvertFrom-Json -Depth 20
        )
        foreach ($entry in $inventory) {
            Assert-SequenceEqual @(
                'type',
                'path',
                'length',
                'sha256'
            ) @($entry.PSObject.Properties.Name) "$Label $phase inventory contains an unsafe field."
            Assert-False ([IO.Path]::IsPathFullyQualified([string]$entry.path)) "$Label $phase inventory contains an absolute path."
        }
        $recomputed = Get-MeechoInventoryContentSha256 -Inventory $inventory
        Assert-Equal ([string]$reference.inventorySha256) $recomputed "$Label $phase inventory digest cannot be recomputed."
        Assert-Equal ([string]$Manifest.$digestProperty) $recomputed "$Label $phase manifest digest is not bound to its inventory."
        $json = Get-Content -LiteralPath $reference.path -Raw -Encoding UTF8
        Assert-False $json.Contains('lastWriteTimeUtc') "$Label $phase inventory leaked timestamps."
        Assert-False $json.Contains('"content"') "$Label $phase inventory leaked a content field."
    }
}

function Invoke-BaselineChild {
    param(
        [string[]] $Arguments,
        [string] $LocalAppData,
        [string] $PathPrefix,
        [string] $UserProfile,
        [switch] $RemoveLocalAppData
    )

    $captureRoot = if ($RemoveLocalAppData) {
        [IO.Path]::GetTempPath()
    }
    else {
        $LocalAppData
    }
    $stdoutPath = Join-Path $captureRoot ('stdout-' + [guid]::NewGuid().ToString('N') + '.txt')
    $stderrPath = Join-Path $captureRoot ('stderr-' + [guid]::NewGuid().ToString('N') + '.txt')
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Join-Path $PSHOME 'pwsh.exe'
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    if ($RemoveLocalAppData) {
        [void]$startInfo.Environment.Remove('LOCALAPPDATA')
    }
    else {
        $startInfo.Environment['LOCALAPPDATA'] = $LocalAppData
    }
    if (-not [string]::IsNullOrWhiteSpace($PathPrefix)) {
        $startInfo.Environment['PATH'] = $PathPrefix + [IO.Path]::PathSeparator +
            [Environment]::GetEnvironmentVariable('PATH')
    }
    if (-not [string]::IsNullOrWhiteSpace($UserProfile)) {
        $startInfo.Environment['USERPROFILE'] = $UserProfile
        $startInfo.Environment['HOME'] = $UserProfile
    }
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $runnerPath) + $Arguments) {
        [void] $startInfo.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($startInfo)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $timedOut = -not $process.WaitForExit(90000)
    if ($timedOut) {
        $process.Kill($true)
        $process.WaitForExit()
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $exitCode = if ($timedOut) { 124 } else { $process.ExitCode }
    if ($timedOut) {
        $stderr = ($stderr.TrimEnd() + "`nBaseline child timed out after 90 seconds.").TrimStart()
    }
    Set-Content -LiteralPath $stdoutPath -Value $stdout -Encoding UTF8
    Set-Content -LiteralPath $stderrPath -Value $stderr -Encoding UTF8
    $process.Dispose()
    return [pscustomobject]@{
        ExitCode = $exitCode
        Stdout = $stdout
        Stderr = $stderr
        TimedOut = $timedOut
    }
}

function New-MeechoFakeCodex {
    param([Parameter(Mandatory)][string] $Root)

    $projectRoot = Join-Path $Root 'fake-codex-project'
    [void][IO.Directory]::CreateDirectory($projectRoot)
    $projectPath = Join-Path $projectRoot 'codex.csproj'
    $sourcePath = Join-Path $projectRoot 'Program.cs'
    [IO.File]::WriteAllText(
        $projectPath,
        @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net8.0</TargetFramework>
    <AssemblyName>codex</AssemblyName>
    <UseAppHost>true</UseAppHost>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
  </PropertyGroup>
</Project>
'@,
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText(
        $sourcePath,
        @'
using System.Text;

static void ApplyRequestedMutation()
{
    var requestPath = Path.Combine(AppContext.BaseDirectory, "mutate-target.txt");
    if (!File.Exists(requestPath))
    {
        return;
    }
    var targetPath = File.ReadAllText(requestPath, Encoding.UTF8).Trim();
    if (targetPath.Length == 0)
    {
        return;
    }
    Directory.CreateDirectory(Path.GetDirectoryName(targetPath)!);
    File.WriteAllText(targetPath, "changed-by-fake-codex", new UTF8Encoding(false));
}

ApplyRequestedMutation();
if (args.Contains("--version"))
{
    Console.WriteLine("codex-cli 0.145.0");
    return 0;
}
if (args.Contains("exec") && args.Contains("--help"))
{
    Console.WriteLine("--ephemeral --ignore-rules --json --model --output-last-message");
    return 0;
}
if (args.Contains("login") && args.Contains("status"))
{
    Console.Error.WriteLine("Not logged in");
    return 1;
}
Console.Error.WriteLine("Unexpected fake Codex arguments");
return 64;
'@,
        [Text.UTF8Encoding]::new($false)
    )

    $buildStartInfo = [Diagnostics.ProcessStartInfo]::new()
    $buildStartInfo.FileName = (Get-Command dotnet -CommandType Application -ErrorAction Stop).Source
    $buildStartInfo.WorkingDirectory = $projectRoot
    $buildStartInfo.UseShellExecute = $false
    $buildStartInfo.RedirectStandardOutput = $true
    $buildStartInfo.RedirectStandardError = $true
    foreach ($argument in @(
        'build',
        $projectPath,
        '--configuration',
        'Release',
        '--nologo',
        '--verbosity',
        'quiet',
        '-p:RestoreIgnoreFailedSources=true'
    )) {
        [void] $buildStartInfo.ArgumentList.Add($argument)
    }
    $buildProcess = [Diagnostics.Process]::Start($buildStartInfo)
    $buildStdoutTask = $buildProcess.StandardOutput.ReadToEndAsync()
    $buildStderrTask = $buildProcess.StandardError.ReadToEndAsync()
    $buildTimedOut = -not $buildProcess.WaitForExit(90000)
    if ($buildTimedOut) {
        $buildProcess.Kill($true)
        $buildProcess.WaitForExit()
    }
    $buildStdout = $buildStdoutTask.GetAwaiter().GetResult()
    $buildStderr = $buildStderrTask.GetAwaiter().GetResult()
    $buildExitCode = if ($buildTimedOut) { 124 } else { $buildProcess.ExitCode }
    $buildProcess.Dispose()
    Assert-False $buildTimedOut 'The fake Codex build timed out.'
    Assert-Equal 0 $buildExitCode "The fake Codex build failed: $buildStdout $buildStderr"

    $outputRoot = Join-Path $projectRoot 'bin/Release/net8.0'
    Assert-True (Test-Path -LiteralPath (Join-Path $outputRoot 'codex.exe') -PathType Leaf) 'The fake Codex apphost was not built.'
    return $outputRoot
}

$testRoot = New-MeechoTestRoot
try {
    $fakeCodexRoot = New-MeechoFakeCodex -Root $testRoot

    $summaryFailureLocalAppData = Join-Path $testRoot 'summary-failure-local'
    $summaryFailureUserProfile = Join-Path $testRoot 'summary-failure-user'
    $invalidSummaryPath = Join-Path $testRoot 'summary-is-a-directory'
    [void][IO.Directory]::CreateDirectory($summaryFailureLocalAppData)
    [void][IO.Directory]::CreateDirectory($summaryFailureUserProfile)
    [void][IO.Directory]::CreateDirectory($invalidSummaryPath)
    $summaryFailure = Invoke-BaselineChild `
        -Arguments @(
            '-Model', 'gpt-test',
            '-ReasoningEffort', 'high',
            '-PreflightOnly',
            '-SummaryPath', $invalidSummaryPath
        ) `
        -LocalAppData $summaryFailureLocalAppData `
        -PathPrefix $fakeCodexRoot `
        -UserProfile $summaryFailureUserProfile
    Assert-False $summaryFailure.TimedOut 'The summary-failure behavior test timed out.'
    Assert-Equal 3 $summaryFailure.ExitCode 'A summary failure must override AUTH_REQUIRED with exit 3.'
    $summaryFailureResult = $summaryFailure.Stdout.Trim() | ConvertFrom-Json -Depth 20
    Assert-Equal 'BLOCKED_NOT_RUN' $summaryFailureResult.Status 'A summary failure must override AUTH_REQUIRED in stdout.'
    $summaryFailureManifest = Read-MeechoJson -Path $summaryFailureResult.ManifestPath
    Assert-Equal 'BLOCKED_NOT_RUN' $summaryFailureManifest.status 'A summary failure must override AUTH_REQUIRED in the manifest.'
    Assert-True (@($summaryFailureManifest.failures) -contains 'AUTH_REQUIRED') 'The underlying authentication failure must remain auditable.'
    Assert-True (@($summaryFailureManifest.failures) -contains 'SUMMARY_VALIDATION_FAILED') 'The summary failure was not recorded.'
    Assert-True ([string]::IsNullOrWhiteSpace($summaryFailure.Stderr)) 'A handled summary failure must not leak raw stderr.'
    Assert-RealProfileInventoryEvidence -Manifest $summaryFailureManifest -Label 'Summary-failure terminal run'

    $profileMutationLocalAppData = Join-Path $testRoot 'profile-mutation-local'
    $profileMutationUserProfile = Join-Path $testRoot 'profile-mutation-user'
    [void][IO.Directory]::CreateDirectory($profileMutationLocalAppData)
    [void][IO.Directory]::CreateDirectory($profileMutationUserProfile)
    $mutationTarget = Join-Path $profileMutationUserProfile '.meecho/unexpected.txt'
    [IO.File]::WriteAllText(
        (Join-Path $fakeCodexRoot 'mutate-target.txt'),
        $mutationTarget,
        [Text.UTF8Encoding]::new($false)
    )
    $profileMutationSummary = Join-Path $testRoot 'profile-mutation-summary.md'
    $profileMutation = Invoke-BaselineChild `
        -Arguments @(
            '-Model', 'gpt-test',
            '-ReasoningEffort', 'high',
            '-PreflightOnly',
            '-SummaryPath', $profileMutationSummary
        ) `
        -LocalAppData $profileMutationLocalAppData `
        -PathPrefix $fakeCodexRoot `
        -UserProfile $profileMutationUserProfile
    Assert-False $profileMutation.TimedOut 'The real-profile mutation behavior test timed out.'
    Assert-Equal 3 $profileMutation.ExitCode 'A real-profile mutation must override AUTH_REQUIRED with exit 3.'
    $profileMutationResult = $profileMutation.Stdout.Trim() | ConvertFrom-Json -Depth 20
    Assert-Equal 'BLOCKED_NOT_RUN' $profileMutationResult.Status 'A real-profile mutation must override AUTH_REQUIRED in stdout.'
    $profileMutationManifest = Read-MeechoJson -Path $profileMutationResult.ManifestPath
    Assert-Equal 'BLOCKED_NOT_RUN' $profileMutationManifest.status 'A real-profile mutation must override AUTH_REQUIRED in the manifest.'
    Assert-True (@($profileMutationManifest.failures) -contains 'AUTH_REQUIRED') 'The mutation test must retain the underlying authentication failure.'
    Assert-True (@($profileMutationManifest.failures) -contains 'REAL_PROFILE_CHANGED') 'The real-profile mutation was not recorded.'
    Assert-False ($profileMutationManifest.realProfileBeforeSha256 -eq $profileMutationManifest.realProfileAfterSha256) 'The mutation test must prove its before/after inventory changed.'
    Assert-RealProfileInventoryEvidence -Manifest $profileMutationManifest -Label 'Profile-mutation terminal run'
    Remove-Item -LiteralPath (Join-Path $fakeCodexRoot 'mutate-target.txt') -Force

    $missingLocalAppData = Invoke-BaselineChild `
        -Arguments @('-Model', 'gpt-test', '-ReasoningEffort', 'high', '-PreflightOnly') `
        -RemoveLocalAppData `
        -UserProfile (Join-Path $testRoot 'missing-local-user')
    Assert-True ($missingLocalAppData.ExitCode -ne 0) 'Missing LOCALAPPDATA must block without a naked exception.'
    $missingLocalResult = $missingLocalAppData.Stdout.Trim() | ConvertFrom-Json -Depth 20
    Assert-Equal 'BLOCKED_NOT_RUN' $missingLocalResult.Status 'Missing LOCALAPPDATA needs a structured blocked result.'
    Assert-True (Test-Path -LiteralPath $missingLocalResult.ManifestPath -PathType Leaf) 'Bootstrap failure must persist a local manifest.'
    $missingLocalManifest = Read-MeechoJson -Path $missingLocalResult.ManifestPath
    Assert-Equal 'meecho-eval-bootstrap' $missingLocalManifest.kind 'Bootstrap failure must not impersonate a standard run manifest.'
    Assert-RealProfileInventoryEvidence -Manifest $missingLocalManifest -Label 'Missing-LOCALAPPDATA bootstrap'
    Assert-True ([string]::IsNullOrWhiteSpace($missingLocalAppData.Stderr)) 'Bootstrap failure must not leak as raw stderr.'

    $unsafeRunId = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $unsafeLocalAppData = Join-Path $repoRoot "evals/logs/$unsafeRunId/unsafe-localappdata"
    New-Item -ItemType Directory -Path $unsafeLocalAppData -Force | Out-Null
    $unsafe = Invoke-BaselineChild `
        -Arguments @('-Model', 'gpt-test', '-ReasoningEffort', 'high', '-PreflightOnly') `
        -LocalAppData $unsafeLocalAppData `
        -UserProfile (Join-Path $testRoot 'unsafe-user')
    $unsafeResult = $unsafe.Stdout.Trim() | ConvertFrom-Json -Depth 20
    Assert-Equal 'BLOCKED_NOT_RUN' $unsafeResult.Status 'Repository-overlapping capsule roots must be blocked.'
    Assert-False (Test-Path -LiteralPath (Join-Path $unsafeLocalAppData 'MeechoDev')) 'Unsafe capsule paths must be rejected before creating any external-state tree.'
    Assert-RealProfileInventoryEvidence `
        -Manifest (Read-MeechoJson -Path $unsafeResult.ManifestPath) `
        -Label 'Unsafe-capsule bootstrap'

    $missing = Invoke-BaselineChild `
        -Arguments @('-PreflightOnly') `
        -LocalAppData $testRoot `
        -UserProfile (Join-Path $testRoot 'missing-input-user')
    Assert-True ($missing.ExitCode -ne 0) 'Missing model and reasoning must fail.'
    $missingResult = $missing.Stdout.Trim() | ConvertFrom-Json -Depth 20
    Assert-Equal 'BLOCKED_NOT_RUN' $missingResult.Status 'Missing required inputs must use the blocked status.'
    Assert-Matches $missingResult.RunId '^\d{8}T\d{9}Z-[0-9a-f]{8}$' 'A failed invocation still needs an auditable run id.'
    Assert-True (Test-Path -LiteralPath $missingResult.ManifestPath -PathType Leaf) 'Missing-argument failure must write a preflight manifest.'
    $missingManifest = Read-MeechoJson -Path $missingResult.ManifestPath
    Assert-Equal 'meecho-eval-bootstrap' $missingManifest.kind 'Invalid invocation inputs belong to the explicit bootstrap manifest kind.'
    Assert-True (@($missingManifest.failures) -contains 'MODEL_REQUIRED') 'Missing model failure was not recorded.'
    Assert-True (@($missingManifest.failures) -contains 'REASONING_REQUIRED') 'Missing reasoning failure was not recorded.'
    Assert-RealProfileInventoryEvidence -Manifest $missingManifest -Label 'Missing-input terminal run'

    $wrongReasoning = Invoke-BaselineChild `
        -Arguments @('-Model', 'gpt-test', '-ReasoningEffort', 'medium', '-PreflightOnly') `
        -LocalAppData $testRoot `
        -UserProfile (Join-Path $testRoot 'wrong-reasoning-user')
    Assert-True ($wrongReasoning.ExitCode -ne 0) 'Reasoning other than high must fail preflight.'
    $wrongResult = $wrongReasoning.Stdout.Trim() | ConvertFrom-Json -Depth 20
    Assert-Equal 'BLOCKED_NOT_RUN' $wrongResult.Status 'Reasoning mismatch must block execution.'
    $wrongManifest = Read-MeechoJson -Path $wrongResult.ManifestPath
    Assert-True (@($wrongManifest.failures) -contains 'REASONING_MUST_BE_HIGH') 'Reasoning mismatch was not recorded.'
    Assert-RealProfileInventoryEvidence -Manifest $wrongManifest -Label 'Wrong-reasoning terminal run'

    $summaryPath = Join-Path $testRoot 'blocked-summary.md'
    $isolated = Invoke-BaselineChild `
        -Arguments @('-Model', 'gpt-test', '-ReasoningEffort', 'high', '-PreflightOnly', '-SummaryPath', $summaryPath) `
        -LocalAppData $testRoot `
        -UserProfile (Join-Path $testRoot 'isolated-user')
    Assert-True ($isolated.ExitCode -ne 0) 'A fresh isolated CODEX_HOME should not silently run cases without a ready preflight.'
    $isolatedResult = $isolated.Stdout.Trim() | ConvertFrom-Json -Depth 20
    Assert-True ($isolatedResult.Status -in @('AUTH_REQUIRED', 'BLOCKED_NOT_RUN')) 'Fresh capsule must report an exact non-ready status.'
    $isolatedManifest = Read-MeechoJson -Path $isolatedResult.ManifestPath
    Assert-Equal 0 @($isolatedManifest.cases).Count 'No case output may exist after a non-ready preflight.'
    Assert-Matches ([string]$isolatedManifest.realProfileBeforeSha256) '^[a-f0-9]{64}$' 'A formal preflight must inventory the real profile before running.'
    Assert-Equal $isolatedManifest.realProfileBeforeSha256 $isolatedManifest.realProfileAfterSha256 'A blocked preflight must prove the real profile remained unchanged.'
    Assert-RealProfileInventoryEvidence -Manifest $isolatedManifest -Label 'Isolated preflight terminal run'
    Assert-False (($isolatedManifest | ConvertTo-Json -Depth 50) -match 'Get-LocalUser|ProfileList|evals[\\/]sandboxes|isolation-config') 'Dedicated Windows-user semantics leaked into the new manifest.'
    $permissionPreflights = @($isolatedManifest.permissionPreflights)
    Assert-SequenceEqual @('read', 'allow', 'deny') @(
        $permissionPreflights | ForEach-Object permissionMode
    ) 'Baseline must run all three permission canaries before any behavior case.'
    foreach ($permissionPreflight in $permissionPreflights) {
        Assert-True (
            [string]$permissionPreflight.status -in @('ready', 'AUTH_REQUIRED', 'BLOCKED_NOT_RUN')
        ) 'Each permission preflight must report an exact capsule status.'
    }
    $stepRecordPaths = @($isolatedManifest.steps | ForEach-Object recordPath)
    foreach ($permissionMode in 'read', 'allow', 'deny') {
        Assert-True (
            @($stepRecordPaths | Where-Object {
                [string]$_ -match "[\\/]preflight[\\/]$permissionMode[\\/]"
            }).Count -gt 0
        ) "The $permissionMode preflight must leave an audited step record."
    }
    Assert-True (Test-Path -LiteralPath $summaryPath -PathType Leaf) 'A non-ready formal preflight must still update the redacted summary.'
    $summary = Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8
    Assert-True ($summary.Contains($isolatedResult.Status)) 'Blocked/auth status was not written to the redacted summary.'
    Assert-True ($summary.Contains($isolatedResult.RunId)) 'Blocked/auth run id was not written to the redacted summary.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Output 'PASS Test-BaselinePreflight'
