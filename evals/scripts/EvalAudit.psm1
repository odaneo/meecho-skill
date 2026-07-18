Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-EvalRepositoryPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$Path
    )

    $root = [System.IO.Path]::GetFullPath($RepositoryRoot).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $rootPrefix = $root + [System.IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.Equals($root, [StringComparison]::OrdinalIgnoreCase) -and
        -not $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside RepositoryRoot: $Path"
    }
    return $fullPath
}

function New-EvalRunDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [scriptblock]$UtcNowProvider = { [datetimeoffset]::UtcNow },
        [scriptblock]$WaitAction = { param([string]$RunId) Start-Sleep -Milliseconds 50 }
    )

    $logsDirectory = Resolve-EvalRepositoryPath -RepositoryRoot $RepositoryRoot -Path (Join-Path $RepositoryRoot 'evals/logs')
    if (-not (Test-Path -LiteralPath $logsDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $logsDirectory -ErrorAction Stop | Out-Null
    }

    while ($true) {
        $utcNow = [datetimeoffset](& $UtcNowProvider)
        $runId = $utcNow.ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
        $runPath = Resolve-EvalRepositoryPath -RepositoryRoot $RepositoryRoot -Path (Join-Path $logsDirectory $runId)
        try {
            New-Item -ItemType Directory -Path $runPath -ErrorAction Stop | Out-Null
        } catch {
            if (Test-Path -LiteralPath $runPath -PathType Container) {
                & $WaitAction $runId
                continue
            }
            throw
        }

        New-Item -ItemType Directory -Path (Join-Path $runPath 'steps') -ErrorAction Stop | Out-Null
        return [pscustomobject]@{ Id = $runId; Path = $runPath }
    }
}

function ConvertTo-EvalOutputLines {
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return }
    $lines = @($Text -split "`r?`n")
    if ($lines.Count -gt 0 -and $lines[-1] -eq '') {
        if ($lines.Count -eq 1) { return }
        $lines = @($lines[0..($lines.Count - 2)])
    }
    return $lines
}

function Invoke-EvalProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory
    )

    $startUtc = [datetimeoffset]::UtcNow
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $startInfo.WorkingDirectory = $WorkingDirectory
    }
    foreach ($argument in $ArgumentList) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $endUtc = [datetimeoffset]::UtcNow
        return [pscustomobject]@{
            StartedAtUtc = $startUtc
            EndedAtUtc = $endUtc
            Stdout = @(ConvertTo-EvalOutputLines -Text $stdout)
            Stderr = @(ConvertTo-EvalOutputLines -Text $stderr)
            ExitCode = $process.ExitCode
        }
    } finally {
        $process.Dispose()
    }
}

function Write-EvalStepLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Action,
        [string[]]$Stdout = @(),
        [string[]]$Stderr = @(),
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][ValidateSet('passed', 'failed')][string]$Conclusion,
        [Parameter(Mandatory)][datetimeoffset]$StartedAtUtc,
        [Parameter(Mandatory)][datetimeoffset]$EndedAtUtc
    )

    if ([string]::IsNullOrWhiteSpace($Action)) { throw 'Step action must not be empty.' }
    if ($EndedAtUtc -lt $StartedAtUtc) { throw 'Step end time precedes its start time.' }
    $expectedConclusion = if ($ExitCode -eq 0) { 'passed' } else { 'failed' }
    if ($Conclusion -ne $expectedConclusion) { throw 'Step conclusion does not match exit code.' }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("utc_started=$($StartedAtUtc.ToUniversalTime().ToString('o'))")
    $lines.Add("action=$Action")
    $lines.Add('stdout:')
    foreach ($line in $Stdout) { $lines.Add("  $line") }
    $lines.Add('stderr:')
    foreach ($line in $Stderr) { $lines.Add("  $line") }
    $lines.Add("exit_code=$ExitCode")
    $lines.Add("conclusion=$Conclusion")
    $lines.Add("utc_finished=$($EndedAtUtc.ToUniversalTime().ToString('o'))")
    $lines | Set-Content -LiteralPath $Path -Encoding utf8
}

function ConvertFrom-EvalUtcTimestamp {
    param([Parameter(Mandatory)][string]$Value, [Parameter(Mandatory)][string]$FieldName)
    $parsed = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse(
        $Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$parsed
    ) -or $parsed.Offset -ne [timespan]::Zero) {
        throw "$FieldName must be an ISO UTC timestamp."
    }
    return $parsed
}

function Read-EvalStepLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $lines = @(Get-Content -LiteralPath $Path)
    if ($lines.Count -lt 8) { throw 'Step log is missing required fields or sections.' }
    if ($lines[0] -notmatch '^utc_started=(.+)$') { throw 'Step log is missing utc_started.' }
    $started = ConvertFrom-EvalUtcTimestamp -Value $Matches[1] -FieldName 'utc_started'
    if ($lines[1] -notmatch '^action=(.+)$' -or [string]::IsNullOrWhiteSpace($Matches[1])) { throw 'Step log is missing a non-empty action.' }
    $action = $Matches[1]
    if ($lines[2] -ne 'stdout:') { throw 'Step log is missing the stdout section.' }

    $stderrIndex = -1
    for ($index = 3; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -eq 'stderr:') { $stderrIndex = $index; break }
    }
    if ($stderrIndex -lt 0) { throw 'Step log is missing the stderr section.' }
    if ($lines[-3] -notmatch '^exit_code=(-?\d+)$') { throw 'Step log is missing a numeric exit_code.' }
    $exitCode = [int]$Matches[1]
    if ($lines[-2] -notmatch '^conclusion=(passed|failed)$') { throw 'Step log has an invalid conclusion.' }
    $conclusion = $Matches[1]
    if ($lines[-1] -notmatch '^utc_finished=(.+)$') { throw 'Step log is missing utc_finished.' }
    $ended = ConvertFrom-EvalUtcTimestamp -Value $Matches[1] -FieldName 'utc_finished'
    if ($ended -lt $started) { throw 'Step log end time precedes its start time.' }
    if (($exitCode -eq 0 -and $conclusion -ne 'passed') -or ($exitCode -ne 0 -and $conclusion -ne 'failed')) {
        throw 'Step log conclusion does not match exit_code.'
    }
    if ($stderrIndex -gt ($lines.Count - 4)) { throw 'Step log fields are out of order.' }

    $stdout = if ($stderrIndex -gt 3) { @($lines[3..($stderrIndex - 1)] | ForEach-Object { if ($_.StartsWith('  ')) { $_.Substring(2) } else { throw 'stdout content is not encoded as a section line.' } }) } else { @() }
    $stderr = if (($lines.Count - 4) -gt $stderrIndex) { @($lines[($stderrIndex + 1)..($lines.Count - 4)] | ForEach-Object { if ($_.StartsWith('  ')) { $_.Substring(2) } else { throw 'stderr content is not encoded as a section line.' } }) } else { @() }
    return [pscustomobject]@{
        StartedAtUtc = $started
        EndedAtUtc = $ended
        Action = $action
        Stdout = $stdout
        Stderr = $stderr
        ExitCode = $exitCode
        Conclusion = $conclusion
    }
}

function Get-EvalChecksumExpectedFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$RunDirectory
    )

    $root = Resolve-EvalRepositoryPath -RepositoryRoot $RepositoryRoot -Path $RepositoryRoot
    $run = Resolve-EvalRepositoryPath -RepositoryRoot $RepositoryRoot -Path $RunDirectory
    $requiredPaths = @(
        (Join-Path $root 'evals/fixtures/synthetic-corpus'),
        (Join-Path $root 'evals/cases'),
        (Join-Path $root 'evals/rubric.md'),
        $run
    )
    foreach ($requiredPath in $requiredPaths) {
        if (-not (Test-Path -LiteralPath $requiredPath)) { throw "Required checksum input is missing: $requiredPath" }
    }

    $files = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root 'evals/fixtures/synthetic-corpus') -Recurse -File) { $files.Add($file) }
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root 'evals/cases') -File) { $files.Add($file) }
    $files.Add((Get-Item -LiteralPath (Join-Path $root 'evals/rubric.md')))
    foreach ($file in Get-ChildItem -LiteralPath $run -Recurse -File | Where-Object { $_.Name -ne 'checksums.sha256' }) { $files.Add($file) }

    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $files) {
        $normalized = Resolve-EvalRepositoryPath -RepositoryRoot $root -Path $file.FullName
        if (-not $seen.Add($normalized)) { throw "Duplicate expected checksum path: $normalized" }
        Get-Item -LiteralPath $normalized
    }
}

function Write-EvalChecksums {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$RunDirectory
    )

    $root = Resolve-EvalRepositoryPath -RepositoryRoot $RepositoryRoot -Path $RepositoryRoot
    $run = Resolve-EvalRepositoryPath -RepositoryRoot $root -Path $RunDirectory
    $lines = foreach ($file in Get-EvalChecksumExpectedFiles -RepositoryRoot $root -RunDirectory $run | Sort-Object FullName) {
        $relative = [System.IO.Path]::GetRelativePath($root, $file.FullName) -replace '\\', '/'
        "$((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant())  $relative"
    }
    $lines | Set-Content -LiteralPath (Join-Path $run 'checksums.sha256') -Encoding utf8
}

Export-ModuleMember -Function @(
    'Resolve-EvalRepositoryPath',
    'New-EvalRunDirectory',
    'Invoke-EvalProcess',
    'Write-EvalStepLog',
    'Read-EvalStepLog',
    'Get-EvalChecksumExpectedFiles',
    'Write-EvalChecksums'
)
