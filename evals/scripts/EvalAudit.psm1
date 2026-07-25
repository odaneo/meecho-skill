Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:MeechoUtf8NoBom = [System.Text.UTF8Encoding]::new($false)
$script:MeechoSensitiveNamePattern = '(?i)(OPENAI_|KEY|SECRET|TOKEN|CREDENTIAL|AUTH\.JSON)'
$script:MeechoReparseAuditCache = $null
$script:MeechoAllowedEnvironmentNames = @(
    'SystemRoot',
    'WINDIR',
    'COMSPEC',
    'PATHEXT',
    'PATH',
    'TEMP',
    'TMP',
    'LOCALAPPDATA',
    'APPDATA',
    'ProgramData',
    'ProgramFiles',
    'ProgramFiles(x86)',
    'CommonProgramFiles',
    'CommonProgramFiles(x86)',
    'USERNAME',
    'USERDOMAIN',
    'USERPROFILE',
    'HOME',
    'CODEX_HOME',
    'CODEX_SQLITE_HOME'
)
$script:MeechoRequiredRewrittenEnvironmentNames = @(
    'TEMP',
    'TMP',
    'LOCALAPPDATA',
    'APPDATA',
    'USERPROFILE',
    'HOME',
    'CODEX_HOME',
    'CODEX_SQLITE_HOME'
)

function Get-MeechoSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Get-MeechoTextSha256 {
    param(
        [AllowEmptyString()]
        [string] $Text
    )

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $script:MeechoUtf8NoBom.GetBytes($Text)
        return [Convert]::ToHexString(
            $algorithm.ComputeHash($bytes)
        ).ToLowerInvariant()
    }
    finally {
        $algorithm.Dispose()
    }
}

function Get-MeechoAllowedEnvironmentNames {
    return @($script:MeechoAllowedEnvironmentNames)
}

function Get-MeechoRequiredEnvironmentNames {
    return @($script:MeechoRequiredRewrittenEnvironmentNames)
}

function Test-MeechoEnvironmentNameContract {
    param(
        [AllowEmptyCollection()]
        [object[]] $Names,

        [switch] $RequireRewritten
    )

    $allowed = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($name in $script:MeechoAllowedEnvironmentNames) {
        [void]$allowed.Add($name)
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($value in @($Names)) {
        $name = [string]$value
        if ([string]::IsNullOrWhiteSpace($name) -or
            -not $allowed.Contains($name) -or
            -not $seen.Add($name)) {
            return $false
        }
    }
    if ($RequireRewritten) {
        foreach ($requiredName in $script:MeechoRequiredRewrittenEnvironmentNames) {
            if (-not $seen.Contains($requiredName)) {
                return $false
            }
        }
    }
    return $true
}

function Test-MeechoSensitiveName {
    param(
        [AllowEmptyString()]
        [string] $Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }

    return $Name -match $script:MeechoSensitiveNamePattern
}

function Write-MeechoUtf8File {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [AllowEmptyString()]
        [string] $Text
    )

    [System.IO.File]::WriteAllText($Path, $Text, $script:MeechoUtf8NoBom)
}

function Get-MeechoNormalizedPath {
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'Path must not be empty.'
    }

    return [System.IO.Path]::GetFullPath($Path).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
}

function Test-MeechoPathUnder {
    param(
        [Parameter(Mandatory)]
        [string] $Child,

        [Parameter(Mandatory)]
        [string] $Parent,

        [switch] $AllowEqual
    )

    $childPath = Get-MeechoNormalizedPath -Path $Child
    $parentPath = Get-MeechoNormalizedPath -Path $Parent
    if ($AllowEqual -and $childPath.Equals($parentPath, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $prefix = $parentPath + [System.IO.Path]::DirectorySeparatorChar
    return $childPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-MeechoNoReparsePoint {
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $current = Get-MeechoNormalizedPath -Path $Path
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if ($null -ne $script:MeechoReparseAuditCache -and
            $script:MeechoReparseAuditCache.Contains($current)) {
            break
        }
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse points are forbidden in audited paths: $current"
            }
        }
        if ($null -ne $script:MeechoReparseAuditCache) {
            [void]$script:MeechoReparseAuditCache.Add($current)
        }

        $parent = [System.IO.Path]::GetDirectoryName($current)
        if ([string]::IsNullOrWhiteSpace($parent) -or
            $parent.Equals($current, [StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $current = $parent.TrimEnd(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar
        )
    }
}

function Get-MeechoFileInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [AllowEmptyCollection()]
        [string[]] $ExcludedRelativePath = @()
    )

    $root = Get-MeechoNormalizedPath -Path $Path
    Assert-MeechoNoReparsePoint -Path $root
    if (-not (Test-Path -LiteralPath $root)) {
        return @()
    }

    $rootItem = Get-Item -LiteralPath $root -Force -ErrorAction Stop
    if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Inventory root is a reparse point: $root"
    }

    $excluded = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($requestedPath in @($ExcludedRelativePath)) {
        $relative = ([string]$requestedPath) -replace '\\', '/'
        if ([string]::IsNullOrWhiteSpace($relative) -or
            [System.IO.Path]::IsPathFullyQualified($relative) -or
            $relative -match '(^|/)\.\.(/|$)' -or
            $relative.StartsWith('./', [StringComparison]::Ordinal)) {
            throw "Inventory exclusion is not an exact safe relative path: $requestedPath"
        }
        if (-not $excluded.Add($relative)) {
            throw "Inventory exclusion is duplicated: $relative"
        }
    }

    $items = [System.Collections.Generic.List[System.IO.FileSystemInfo]]::new()
    if ($rootItem -is [System.IO.FileInfo]) {
        if (-not $excluded.Contains($rootItem.Name)) {
            $items.Add($rootItem)
        }
    }
    else {
        $items.Add([System.IO.DirectoryInfo]$rootItem)
        $directories = [System.Collections.Generic.Stack[System.IO.DirectoryInfo]]::new()
        $directories.Push([System.IO.DirectoryInfo] $rootItem)
        while ($directories.Count -gt 0) {
            $directory = $directories.Pop()
            foreach ($child in Get-ChildItem -LiteralPath $directory.FullName -Force -ErrorAction Stop) {
                if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "Inventory encountered a reparse point: $($child.FullName)"
                }

                $relative = [System.IO.Path]::GetRelativePath(
                    $root,
                    $child.FullName
                ) -replace '\\', '/'
                if ($excluded.Contains($relative)) {
                    if ($child -is [System.IO.DirectoryInfo]) {
                        throw "Inventory exclusions may identify files only: $relative"
                    }
                    continue
                }

                $items.Add($child)
                if ($child -is [System.IO.DirectoryInfo]) {
                    $directories.Push($child)
                }
            }
        }
    }

    $inventory = foreach ($item in $items | Sort-Object FullName) {
        $relativePath = if ($rootItem -is [System.IO.FileInfo]) {
            $item.Name
        }
        elseif ($item.FullName.Equals($root, [StringComparison]::OrdinalIgnoreCase)) {
            '.'
        }
        else {
            [System.IO.Path]::GetRelativePath($root, $item.FullName) -replace '\\', '/'
        }
        $type = if ($item -is [System.IO.DirectoryInfo]) { 'directory' } else { 'file' }
        $sha256 = if ($type -ceq 'file') {
            Get-MeechoSha256 -Path $item.FullName
        }
        else {
            Get-MeechoTextSha256 -Text "directory:$relativePath"
        }

        [pscustomobject] [ordered]@{
            type = $type
            path = $relativePath
            length = if ($type -ceq 'file') { [long]$item.Length } else { [long]0 }
            lastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')
            sha256 = $sha256
        }
    }

    return @($inventory)
}

function Compare-MeechoFileInventory {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]] $Before = @(),

        [AllowEmptyCollection()]
        [object[]] $After = @()
    )

    $beforeMap = [System.Collections.Generic.Dictionary[string, object]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $afterMap = [System.Collections.Generic.Dictionary[string, object]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )

    foreach ($entry in @($Before)) {
        $path = [string] $entry.path
        if ([string]::IsNullOrWhiteSpace($path) -or $beforeMap.ContainsKey($path)) {
            throw 'Before inventory contains an empty or duplicate path.'
        }
        $beforeMap.Add($path, $entry)
    }
    foreach ($entry in @($After)) {
        $path = [string] $entry.path
        if ([string]::IsNullOrWhiteSpace($path) -or $afterMap.ContainsKey($path)) {
            throw 'After inventory contains an empty or duplicate path.'
        }
        $afterMap.Add($path, $entry)
    }

    $added = @($afterMap.Keys | Where-Object { -not $beforeMap.ContainsKey($_) } | Sort-Object)
    $removed = @($beforeMap.Keys | Where-Object { -not $afterMap.ContainsKey($_) } | Sort-Object)
    $changed = [System.Collections.Generic.List[string]]::new()
    foreach ($path in $beforeMap.Keys | Where-Object { $afterMap.ContainsKey($_) } | Sort-Object) {
        $left = $beforeMap[$path]
        $right = $afterMap[$path]
        if ([string] $left.type -cne [string] $right.type -or
            [string] $left.sha256 -cne [string] $right.sha256 -or
            [long] $left.length -ne [long] $right.length -or
            [string] $left.lastWriteTimeUtc -cne [string] $right.lastWriteTimeUtc) {
            $changed.Add($path)
        }
    }

    return [pscustomobject] [ordered]@{
        Equal = ($added.Count -eq 0 -and $removed.Count -eq 0 -and $changed.Count -eq 0)
        Added = $added
        Removed = $removed
        Changed = @($changed)
    }
}

function ConvertTo-MeechoInventoryEvidence {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]] $Inventory = @()
    )

    $seen = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $safeInventory = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @($Inventory)) {
        if ($null -eq $entry) {
            throw 'INVENTORY_EVIDENCE_INVALID_ENTRY'
        }
        $typeProperty = $entry.PSObject.Properties['type']
        $pathProperty = $entry.PSObject.Properties['path']
        $lengthProperty = $entry.PSObject.Properties['length']
        $sha256Property = $entry.PSObject.Properties['sha256']
        if ($null -eq $typeProperty -or
            $null -eq $pathProperty -or
            $null -eq $lengthProperty -or
            $null -eq $sha256Property) {
            throw 'INVENTORY_EVIDENCE_INVALID_ENTRY'
        }

        $type = [string]$typeProperty.Value
        if ($type -cnotin @('directory', 'file')) {
            throw 'INVENTORY_EVIDENCE_INVALID_TYPE'
        }

        $path = ([string]$pathProperty.Value) -replace '\\', '/'
        $pathInvalid = (
            [string]::IsNullOrWhiteSpace($path) -or
            [System.IO.Path]::IsPathFullyQualified($path) -or
            $path.StartsWith('/', [StringComparison]::Ordinal) -or
            $path -match '^[A-Za-z]:' -or
            $path -match '[:\x00-\x1f]'
        )
        if (-not $pathInvalid -and $path -cne '.') {
            $segments = @($path -split '/')
            $pathInvalid = (
                $segments.Count -eq 0 -or
                @($segments | Where-Object {
                    [string]::IsNullOrEmpty($_) -or $_ -in @('.', '..')
                }).Count -gt 0
            )
        }
        if ($pathInvalid) {
            throw 'INVENTORY_EVIDENCE_INVALID_PATH'
        }
        if (-not $seen.Add($path)) {
            throw 'INVENTORY_EVIDENCE_DUPLICATE_PATH'
        }

        $lengthValue = $lengthProperty.Value
        if ($lengthValue -isnot [byte] -and
            $lengthValue -isnot [sbyte] -and
            $lengthValue -isnot [int16] -and
            $lengthValue -isnot [uint16] -and
            $lengthValue -isnot [int32] -and
            $lengthValue -isnot [uint32] -and
            $lengthValue -isnot [int64] -and
            $lengthValue -isnot [uint64]) {
            throw 'INVENTORY_EVIDENCE_INVALID_LENGTH'
        }
        $length = try {
            [long]$lengthValue
        }
        catch {
            throw 'INVENTORY_EVIDENCE_INVALID_LENGTH'
        }
        if ($length -lt 0 -or ($type -ceq 'directory' -and $length -ne 0)) {
            throw 'INVENTORY_EVIDENCE_INVALID_LENGTH'
        }

        $sha256 = [string]$sha256Property.Value
        if ($sha256 -cnotmatch '^[a-f0-9]{64}$') {
            throw 'INVENTORY_EVIDENCE_INVALID_SHA256'
        }

        $safeInventory.Add([pscustomobject][ordered]@{
            type = $type
            path = $path
            length = $length
            sha256 = $sha256
        })
    }

    return @($safeInventory | Sort-Object path, type)
}

function Get-MeechoInventoryContentSha256 {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]] $Inventory = @()
    )

    $orderedIdentity = @(ConvertTo-MeechoInventoryEvidence -Inventory $Inventory)
    $json = ConvertTo-Json -InputObject $orderedIdentity -Compress -Depth 10
    return Get-MeechoTextSha256 -Text $json
}

function Write-MeechoInventoryEvidence {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]] $Inventory = @(),

        [Parameter(Mandatory)]
        [string] $Path
    )

    try {
        $fullPath = Get-MeechoNormalizedPath -Path $Path
        $parent = Split-Path -Parent $fullPath
        if ([string]::IsNullOrWhiteSpace($parent)) {
            throw 'invalid parent'
        }
        Assert-MeechoNoReparsePoint -Path $parent
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            [void][System.IO.Directory]::CreateDirectory($parent)
        }
        Assert-MeechoNoReparsePoint -Path $parent
        Assert-MeechoNoReparsePoint -Path $fullPath
    }
    catch {
        throw 'INVENTORY_EVIDENCE_PATH_INVALID'
    }

    if (Test-Path -LiteralPath $fullPath) {
        throw 'INVENTORY_EVIDENCE_ALREADY_EXISTS'
    }

    $projected = @(ConvertTo-MeechoInventoryEvidence -Inventory $Inventory)
    $json = ConvertTo-Json -InputObject $projected -Depth 10
    $temporaryPath = Join-Path $parent (
        ".$([System.IO.Path]::GetFileName($fullPath))." +
        "$([guid]::NewGuid().ToString('N')).tmp"
    )
    $stream = $null
    try {
        $stream = [System.IO.File]::Open(
            $temporaryPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        $bytes = $script:MeechoUtf8NoBom.GetBytes($json)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null

        if (Test-Path -LiteralPath $fullPath) {
            throw 'INVENTORY_EVIDENCE_ALREADY_EXISTS'
        }
        [System.IO.File]::Move($temporaryPath, $fullPath, $false)
    }
    catch {
        if ($null -ne $stream) {
            $stream.Dispose()
            $stream = $null
        }
        if ([string]$_.Exception.Message -ceq 'INVENTORY_EVIDENCE_ALREADY_EXISTS' -or
            (Test-Path -LiteralPath $fullPath)) {
            throw 'INVENTORY_EVIDENCE_ALREADY_EXISTS'
        }
        throw 'INVENTORY_EVIDENCE_WRITE_FAILED'
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }

    return [pscustomobject][ordered]@{
        Path = $fullPath
        Sha256 = Get-MeechoSha256 -Path $fullPath
        InventorySha256 = Get-MeechoInventoryContentSha256 -Inventory $projected
    }
}

function Invoke-MeechoAuditedProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $FilePath,

        [string[]] $ArgumentList = @(),

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Environment,

        [Parameter(Mandatory)]
        [string] $StepLogRoot,

        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z0-9][a-z0-9._-]*$')]
        [string] $StepName,

        [string] $WorkingDirectory,

        [ValidateRange(1, 3600)]
        [int] $TimeoutSeconds = 120
    )

    $logRoot = Get-MeechoNormalizedPath -Path $StepLogRoot
    Assert-MeechoNoReparsePoint -Path $logRoot
    if (-not (Test-Path -LiteralPath $logRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $logRoot -Force -ErrorAction Stop | Out-Null
    }
    Assert-MeechoNoReparsePoint -Path $logRoot

    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $workingRoot = Get-MeechoNormalizedPath -Path $WorkingDirectory
        if (-not (Test-Path -LiteralPath $workingRoot -PathType Container)) {
            throw "Working directory does not exist: $workingRoot"
        }
        Assert-MeechoNoReparsePoint -Path $workingRoot
    }

    $stdoutPath = Join-Path $logRoot "$StepName.stdout.log"
    $stderrPath = Join-Path $logRoot "$StepName.stderr.log"
    $exitCodePath = Join-Path $logRoot "$StepName.exit-code.txt"
    $checksumPath = Join-Path $logRoot "$StepName.sha256"
    $recordPath = Join-Path $logRoot "$StepName.record.json"
    foreach ($path in $stdoutPath, $stderrPath, $exitCodePath, $checksumPath, $recordPath) {
        if (Test-Path -LiteralPath $path) {
            throw "Audited step artifact already exists: $path"
        }
    }

    $effectiveEnvironment = [ordered]@{}
    foreach ($entry in $Environment.GetEnumerator()) {
        $name = [string] $entry.Key
        if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_()]*$') {
            throw "Invalid child environment variable name: $name"
        }
        if ($name -notin $script:MeechoAllowedEnvironmentNames) {
            throw "Child environment variable is not in the audited allowlist: $name"
        }
        $effectiveEnvironment[$name] = if ($null -eq $entry.Value) { '' } else { [string] $entry.Value }
    }
    if (-not (Test-MeechoEnvironmentNameContract `
        -Names @($effectiveEnvironment.Keys) `
        -RequireRewritten
    )) {
        throw 'Child environment is missing a required rewritten isolation variable.'
    }

    $startedAtUtc = [datetimeoffset]::UtcNow
    $stdout = ''
    $stderr = ''
    $exitCode = -1
    $timedOut = $false
    $process = $null
    try {
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $FilePath
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.CreateNoWindow = $true
        if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            $startInfo.WorkingDirectory = $workingRoot
        }
        foreach ($argument in @($ArgumentList)) {
            [void] $startInfo.ArgumentList.Add($argument)
        }

        $startInfo.Environment.Clear()
        foreach ($entry in $effectiveEnvironment.GetEnumerator()) {
            $startInfo.Environment[$entry.Key] = $entry.Value
        }

        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        [void] $process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $timedOut = $true
            $process.Kill($true)
            $process.WaitForExit()
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($timedOut) {
            $exitCode = 124
            $stderr = ($stderr.TrimEnd() + "`nProcess timed out after $TimeoutSeconds seconds.").TrimStart()
        }
        else {
            $exitCode = $process.ExitCode
        }
    }
    catch {
        $stderr = "Process launch failed ($($_.Exception.GetType().Name)): $($_.Exception.Message)"
        $exitCode = -1
    }
    finally {
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
    $endedAtUtc = [datetimeoffset]::UtcNow

    Write-MeechoUtf8File -Path $stdoutPath -Text $stdout
    Write-MeechoUtf8File -Path $stderrPath -Text $stderr
    Write-MeechoUtf8File -Path $exitCodePath -Text ([string] $exitCode)

    $stdoutHash = Get-MeechoSha256 -Path $stdoutPath
    $stderrHash = Get-MeechoSha256 -Path $stderrPath
    $exitCodeHash = Get-MeechoSha256 -Path $exitCodePath
    $checksumLines = @(
        "$stdoutHash  $([System.IO.Path]::GetFileName($stdoutPath))"
        "$stderrHash  $([System.IO.Path]::GetFileName($stderrPath))"
        "$exitCodeHash  $([System.IO.Path]::GetFileName($exitCodePath))"
    )
    Write-MeechoUtf8File -Path $checksumPath -Text (($checksumLines -join "`n") + "`n")

    $record = [ordered]@{
        schemaVersion = 1
        kind = 'meecho-eval-step'
        stepName = $StepName
        executable = [System.IO.Path]::GetFileName($FilePath)
        commandSha256 = if (Test-Path -LiteralPath $FilePath -PathType Leaf) {
            Get-MeechoSha256 -Path $FilePath
        }
        else {
            ''
        }
        argumentCount = @($ArgumentList).Count
        workingDirectoryConfigured = -not [string]::IsNullOrWhiteSpace($WorkingDirectory)
        startedAtUtc = $startedAtUtc.ToString('o')
        endedAtUtc = $endedAtUtc.ToString('o')
        exitCode = $exitCode
        timedOut = $timedOut
        environmentNames = @($effectiveEnvironment.Keys | Sort-Object)
        stdout = [ordered]@{
            path = [System.IO.Path]::GetFileName($stdoutPath)
            sha256 = $stdoutHash
        }
        stderr = [ordered]@{
            path = [System.IO.Path]::GetFileName($stderrPath)
            sha256 = $stderrHash
        }
        exitCodeArtifact = [ordered]@{
            path = [System.IO.Path]::GetFileName($exitCodePath)
            sha256 = $exitCodeHash
        }
        checksums = [ordered]@{
            path = [System.IO.Path]::GetFileName($checksumPath)
            sha256 = Get-MeechoSha256 -Path $checksumPath
        }
    }
    Write-MeechoUtf8File -Path $recordPath -Text (
        $record | ConvertTo-Json -Depth 20
    )

    return [pscustomobject] [ordered]@{
        ExitCode = $exitCode
        StartedAtUtc = $startedAtUtc.ToString('o')
        EndedAtUtc = $endedAtUtc.ToString('o')
        StdoutPath = $stdoutPath
        StderrPath = $stderrPath
        ExitCodePath = $exitCodePath
        ChecksumPath = $checksumPath
        RecordPath = $recordPath
    }
}

function Resolve-MeechoRecordArtifact {
    param(
        [Parameter(Mandatory)]
        [string] $RecordRoot,

        [Parameter(Mandatory)]
        [string] $RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        [System.IO.Path]::IsPathFullyQualified($RelativePath) -or
        (Test-MeechoSensitiveName -Name $RelativePath)) {
        throw 'Step artifact path is not a safe relative path.'
    }

    $fullPath = Get-MeechoNormalizedPath -Path (Join-Path $RecordRoot $RelativePath)
    if (-not (Test-MeechoPathUnder -Child $fullPath -Parent $RecordRoot)) {
        throw 'Step artifact path escapes its record directory.'
    }
    Assert-MeechoNoReparsePoint -Path $fullPath
    return $fullPath
}

function Test-MeechoStepRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RecordPath
    )

    try {
        $fullRecordPath = Get-MeechoNormalizedPath -Path $RecordPath
        Assert-MeechoNoReparsePoint -Path $fullRecordPath
        if (-not (Test-Path -LiteralPath $fullRecordPath -PathType Leaf)) {
            return $false
        }

        $record = Get-Content -LiteralPath $fullRecordPath -Raw -Encoding UTF8 |
            ConvertFrom-Json -Depth 30
        if ([int] $record.schemaVersion -ne 1 -or [string] $record.kind -cne 'meecho-eval-step') {
            return $false
        }
        if ([string] $record.stepName -notmatch '^[a-z0-9][a-z0-9._-]*$') {
            return $false
        }
        if ($record.PSObject.Properties.Name -contains 'commandSha256' -and
            -not [string]::IsNullOrWhiteSpace([string]$record.commandSha256) -and
            [string]$record.commandSha256 -cnotmatch '^[a-f0-9]{64}$') {
            return $false
        }
        if (-not (Test-MeechoEnvironmentNameContract `
            -Names @($record.environmentNames) `
            -RequireRewritten
        )) {
            return $false
        }

        $recordRoot = Split-Path -Parent $fullRecordPath
        $artifacts = @(
            [pscustomobject]@{ Value = $record.stdout; Label = 'stdout' }
            [pscustomobject]@{ Value = $record.stderr; Label = 'stderr' }
            [pscustomobject]@{ Value = $record.exitCodeArtifact; Label = 'exitCodeArtifact' }
        )
        $artifactPaths = [System.Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase
        )
        foreach ($artifact in $artifacts) {
            if ([string] $artifact.Value.sha256 -notmatch '^[a-f0-9]{64}$') {
                return $false
            }
            $artifactPath = Resolve-MeechoRecordArtifact `
                -RecordRoot $recordRoot `
                -RelativePath ([string] $artifact.Value.path)
            if (-not $artifactPaths.Add($artifactPath) -or
                -not (Test-Path -LiteralPath $artifactPath -PathType Leaf) -or
                (Get-MeechoSha256 -Path $artifactPath) -cne [string] $artifact.Value.sha256) {
                return $false
            }
        }

        $exitText = Get-Content -LiteralPath (
            Resolve-MeechoRecordArtifact -RecordRoot $recordRoot -RelativePath ([string] $record.exitCodeArtifact.path)
        ) -Raw -Encoding UTF8
        $loggedExitCode = 0
        if (-not [int]::TryParse($exitText.Trim(), [ref] $loggedExitCode) -or
            $loggedExitCode -ne [int] $record.exitCode) {
            return $false
        }

        if ([string] $record.checksums.sha256 -notmatch '^[a-f0-9]{64}$') {
            return $false
        }
        $checksumsPath = Resolve-MeechoRecordArtifact `
            -RecordRoot $recordRoot `
            -RelativePath ([string] $record.checksums.path)
        if (-not (Test-Path -LiteralPath $checksumsPath -PathType Leaf) -or
            (Get-MeechoSha256 -Path $checksumsPath) -cne [string] $record.checksums.sha256) {
            return $false
        }

        $declaredChecksums = @(
            Get-Content -LiteralPath $checksumsPath -Encoding UTF8 |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
        if ($declaredChecksums.Count -ne 3) {
            return $false
        }
        foreach ($line in $declaredChecksums) {
            if ($line -notmatch '^([a-f0-9]{64})  ([^\\/]+)$') {
                return $false
            }
            $declaredPath = Resolve-MeechoRecordArtifact -RecordRoot $recordRoot -RelativePath $Matches[2]
            if (-not $artifactPaths.Contains($declaredPath) -or
                (Get-MeechoSha256 -Path $declaredPath) -cne $Matches[1]) {
                return $false
            }
        }

        return $true
    }
    catch {
        return $false
    }
}

function Test-MeechoManifestTextSafety {
    param(
        [Parameter(Mandatory)]
        [string] $Json
    )

    if ($Json -match '(?i)auth\.json' -or
        $Json -match '(?i)"(?:[^"]*(?:key|secret|token|credential)[^"]*)"\s*:' -or
        $Json -match '(?i)"environment"\s*:\s*\{') {
        return $false
    }
    return $true
}

function Get-MeechoPropertyValue {
    param(
        [Parameter(Mandatory)]
        [object] $InputObject,

        [Parameter(Mandatory)]
        [string] $Name,

        [AllowNull()]
        [object] $DefaultValue = $null
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $DefaultValue
    }
    return $property.Value
}

function Write-MeechoRunManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Manifest,

        [Parameter(Mandatory)]
        [string] $Path
    )

    $fullPath = Get-MeechoNormalizedPath -Path $Path
    $parent = Split-Path -Parent $fullPath
    Assert-MeechoNoReparsePoint -Path $parent
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
    }
    Assert-MeechoNoReparsePoint -Path $parent

    $json = $Manifest | ConvertTo-Json -Depth 50
    if (-not (Test-MeechoManifestTextSafety -Json $json)) {
        throw 'Run manifest contains a forbidden environment map or sensitive name.'
    }

    $temporaryPath = Join-Path $parent (
        ".$([System.IO.Path]::GetFileName($fullPath)).$([guid]::NewGuid().ToString('N')).tmp"
    )
    try {
        Write-MeechoUtf8File -Path $temporaryPath -Text $json
        [System.IO.File]::Move($temporaryPath, $fullPath, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Resolve-MeechoManifestReference {
    param(
        [Parameter(Mandatory)]
        [string] $ManifestRoot,

        [Parameter(Mandatory)]
        [string] $Path
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or (Test-MeechoSensitiveName -Name $Path)) {
        throw 'Manifest reference is empty or sensitive.'
    }
    $fullPath = if ([System.IO.Path]::IsPathFullyQualified($Path)) {
        Get-MeechoNormalizedPath -Path $Path
    }
    else {
        Get-MeechoNormalizedPath -Path (Join-Path $ManifestRoot $Path)
    }
    Assert-MeechoNoReparsePoint -Path $fullPath
    return $fullPath
}

function Test-MeechoRunLogContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ManifestPath
    )

    $issues = [System.Collections.Generic.List[string]]::new()
    $status = 'UNKNOWN'
    $complete = $false
    $previousReparseAuditCache = $script:MeechoReparseAuditCache
    $script:MeechoReparseAuditCache = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    try {
        $fullManifestPath = Get-MeechoNormalizedPath -Path $ManifestPath
        Assert-MeechoNoReparsePoint -Path $fullManifestPath
        if (-not (Test-Path -LiteralPath $fullManifestPath -PathType Leaf)) {
            throw 'Run manifest does not exist.'
        }
        $json = Get-Content -LiteralPath $fullManifestPath -Raw -Encoding UTF8
        if (-not (Test-MeechoManifestTextSafety -Json $json)) {
            throw 'Run manifest contains forbidden sensitive fields.'
        }
        $manifest = $json | ConvertFrom-Json -Depth 50
        $manifestRoot = Split-Path -Parent $fullManifestPath

        if ([int](Get-MeechoPropertyValue -InputObject $manifest -Name 'schemaVersion' -DefaultValue 0) -ne 1 -or
            [string](Get-MeechoPropertyValue -InputObject $manifest -Name 'kind' -DefaultValue '') -cne 'meecho-eval-run') {
            $issues.Add('schema-or-kind')
        }
        $runId = [string](
            Get-MeechoPropertyValue -InputObject $manifest -Name 'runId' -DefaultValue ''
        )
        if ($runId -notmatch '^\d{8}T\d{9}Z-[0-9a-f]{8}$') {
            $issues.Add('runId')
        }
        $mode = [string](
            Get-MeechoPropertyValue -InputObject $manifest -Name 'mode' -DefaultValue ''
        )
        if ($mode -notin @('control', 'treatment')) {
            $issues.Add('mode')
        }
        $status = [string](
            Get-MeechoPropertyValue -InputObject $manifest -Name 'status' -DefaultValue ''
        )
        if ($status -notin @('COMPLETE', 'AUTH_REQUIRED', 'BLOCKED_NOT_RUN')) {
            $issues.Add('status')
        }
        $complete = $status -ceq 'COMPLETE'

        $capsuleRootValue = [string](
            Get-MeechoPropertyValue -InputObject $manifest -Name 'capsuleRoot' -DefaultValue ''
        )
        $repoRootValue = [string](
            Get-MeechoPropertyValue -InputObject $manifest -Name 'repoRoot' -DefaultValue ''
        )
        if ([string]::IsNullOrWhiteSpace($capsuleRootValue)) {
            $issues.Add('capsuleRoot')
        }
        if ([string]::IsNullOrWhiteSpace($repoRootValue)) {
            $issues.Add('repoRoot')
        }
        $capsuleRoot = Resolve-MeechoManifestReference `
            -ManifestRoot $manifestRoot `
            -Path $capsuleRootValue
        $repoRoot = Resolve-MeechoManifestReference `
            -ManifestRoot $manifestRoot `
            -Path $repoRootValue
        if (-not (Test-Path -LiteralPath $capsuleRoot -PathType Container)) {
            $issues.Add('capsuleRoot-not-directory')
        }
        if (-not (Test-Path -LiteralPath $repoRoot -PathType Container)) {
            $issues.Add('repoRoot-not-directory')
        }
        if ((Test-MeechoPathUnder -Child $capsuleRoot -Parent $repoRoot -AllowEqual) -or
            (Test-MeechoPathUnder -Child $repoRoot -Parent $capsuleRoot -AllowEqual)) {
            $issues.Add('capsule-repository-overlap')
        }
        $runLogRoot = Get-MeechoNormalizedPath -Path (
            Join-Path $repoRoot "evals/logs/$runId"
        )
        $modeLogRoot = Get-MeechoNormalizedPath -Path (
            Join-Path $runLogRoot $mode
        )
        Assert-MeechoNoReparsePoint -Path $runLogRoot

        $manifestEnvironmentNames = @(
            Get-MeechoPropertyValue `
                -InputObject $manifest `
                -Name 'environmentNames' `
                -DefaultValue @()
        )
        if (-not (Test-MeechoEnvironmentNameContract `
            -Names $manifestEnvironmentNames `
            -RequireRewritten
        )) {
            $issues.Add('environmentNames')
        }

        $manifestSteps = @(
            Get-MeechoPropertyValue -InputObject $manifest -Name 'steps' -DefaultValue @()
        )
        if ($manifestSteps.Count -eq 0) {
            $issues.Add('run-without-step-evidence')
        }
        foreach ($step in $manifestSteps) {
            $recordPath = Resolve-MeechoManifestReference `
                -ManifestRoot $manifestRoot `
                -Path ([string](
                    Get-MeechoPropertyValue -InputObject $step -Name 'recordPath' -DefaultValue ''
                ))
            if (-not (Test-MeechoPathUnder -Child $recordPath -Parent $modeLogRoot)) {
                $issues.Add('step-record-outside-mode-log-root')
            }
            if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) {
                $issues.Add('missing-step-record')
                continue
            }
            $recordSha256 = [string](
                Get-MeechoPropertyValue -InputObject $step -Name 'recordSha256' -DefaultValue ''
            )
            if ($recordSha256 -notmatch '^[a-f0-9]{64}$' -or
                (Get-MeechoSha256 -Path $recordPath) -cne $recordSha256) {
                $issues.Add('step-record-sha256')
                continue
            }
            if (-not (Test-MeechoStepRecord -RecordPath $recordPath)) {
                $issues.Add('step-record-artifacts')
            }
        }

        $manifestCases = @(
            Get-MeechoPropertyValue -InputObject $manifest -Name 'cases' -DefaultValue @()
        )
        $mutablePaths = [System.Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase
        )
        $caseKeys = [System.Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase
        )
        foreach ($case in $manifestCases) {
            $caseId = [string](
                Get-MeechoPropertyValue -InputObject $case -Name 'caseId' -DefaultValue ''
            )
            $scenarioId = [string](
                Get-MeechoPropertyValue -InputObject $case -Name 'scenarioId' -DefaultValue ''
            )
            if ($caseId -notmatch '^case-\d{2}$' -or
                $scenarioId -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' -or
                -not $caseKeys.Add("$caseId/$scenarioId")) {
                $issues.Add('case-scenario-identity')
            }

            $caseEnvironmentNames = @(
                Get-MeechoPropertyValue `
                    -InputObject $case `
                    -Name 'environmentNames' `
                    -DefaultValue @()
            )
            if (-not (Test-MeechoEnvironmentNameContract `
                -Names $caseEnvironmentNames `
                -RequireRewritten
            )) {
                $issues.Add('case-environmentNames')
            }

            $expectedScenarioRoot = Get-MeechoNormalizedPath -Path (
                Join-Path $capsuleRoot "runs/$runId/$mode/$caseId/$scenarioId"
            )
            $expectedStepLogRoot = Get-MeechoNormalizedPath -Path (
                Join-Path $repoRoot "evals/logs/$runId/$mode/$caseId/$scenarioId"
            )
            $expectedPaths = [ordered]@{
                scenarioRoot = $expectedScenarioRoot
                scenarioUserHome = (Join-Path $expectedScenarioRoot 'user-home')
                scenarioWorkspace = (Join-Path $expectedScenarioRoot 'workspace')
                codexSqliteHome = (Join-Path $expectedScenarioRoot 'state')
                scenarioTemp = (Join-Path $expectedScenarioRoot 'temp')
                stepLogRoot = $expectedStepLogRoot
            }
            $resolvedPaths = [ordered]@{}
            foreach ($field in $expectedPaths.Keys) {
                $propertyValue = [string](
                    Get-MeechoPropertyValue -InputObject $case -Name $field -DefaultValue ''
                )
                if ([string]::IsNullOrWhiteSpace($propertyValue)) {
                    $issues.Add("missing-$field")
                    continue
                }
                $resolvedPath = Resolve-MeechoManifestReference `
                    -ManifestRoot $manifestRoot `
                    -Path $propertyValue
                $resolvedPaths[$field] = $resolvedPath
                if (-not $resolvedPath.Equals(
                    (Get-MeechoNormalizedPath -Path $expectedPaths[$field]),
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                    $issues.Add("$field-layout")
                }
                if (-not $mutablePaths.Add($resolvedPath)) {
                    $issues.Add('duplicate-mutable-path')
                }
                if ($complete -and
                    -not (Test-Path -LiteralPath $resolvedPath -PathType Container)) {
                    $issues.Add("missing-$field")
                }
            }

            $stepLogRoot = if ($resolvedPaths.Contains('stepLogRoot')) {
                [string]$resolvedPaths.stepLogRoot
            }
            else {
                $expectedStepLogRoot
            }
            $artifactKinds = [System.Collections.Generic.HashSet[string]]::new(
                [StringComparer]::OrdinalIgnoreCase
            )
            $artifactPaths = [System.Collections.Generic.HashSet[string]]::new(
                [StringComparer]::OrdinalIgnoreCase
            )
            foreach ($artifact in @(
                Get-MeechoPropertyValue -InputObject $case -Name 'artifacts' -DefaultValue @()
            )) {
                $kind = [string](
                    Get-MeechoPropertyValue -InputObject $artifact -Name 'kind' -DefaultValue ''
                )
                if ([string]::IsNullOrWhiteSpace($kind) -or
                    -not $artifactKinds.Add($kind)) {
                    $issues.Add('duplicate-artifact-kind')
                    continue
                }
                $artifactPath = Resolve-MeechoManifestReference `
                    -ManifestRoot $manifestRoot `
                    -Path ([string](
                        Get-MeechoPropertyValue -InputObject $artifact -Name 'path' -DefaultValue ''
                    ))
                if (-not $artifactPaths.Add($artifactPath)) {
                    $issues.Add('duplicate-artifact-path')
                }
                if (-not (Test-MeechoPathUnder -Child $artifactPath -Parent $stepLogRoot)) {
                    $issues.Add('artifact-outside-step-log-root')
                }
                if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
                    $issues.Add('missing-artifact')
                    continue
                }
                $artifactSha256 = [string](
                    Get-MeechoPropertyValue -InputObject $artifact -Name 'sha256' -DefaultValue ''
                )
                if ($artifactSha256 -notmatch '^[a-f0-9]{64}$' -or
                    (Get-MeechoSha256 -Path $artifactPath) -cne $artifactSha256) {
                    $issues.Add('artifact-sha256')
                }
            }
            if ($complete) {
                foreach ($requiredKind in 'jsonl', 'stderr', 'final', 'result') {
                    if (-not $artifactKinds.Contains($requiredKind)) {
                        $issues.Add("missing-artifact-$requiredKind")
                    }
                }
            }
        }

        if ($complete -and $manifestCases.Count -eq 0) {
            $issues.Add('complete-run-without-cases')
        }
        $manifestFailures = @(
            Get-MeechoPropertyValue -InputObject $manifest -Name 'failures' -DefaultValue @()
        )
        if (-not $complete -and $manifestFailures.Count -eq 0) {
            $issues.Add('terminal-run-without-failure')
        }
    }
    catch {
        $issues.Add($_.Exception.Message)
    }
    finally {
        $script:MeechoReparseAuditCache = $previousReparseAuditCache
    }

    return [pscustomobject] [ordered]@{
        Valid = $issues.Count -eq 0
        Status = $status
        Complete = ($issues.Count -eq 0 -and $complete)
        Failures = @($issues)
    }
}

Export-ModuleMember -Function @(
    'Get-MeechoSha256',
    'ConvertTo-MeechoInventoryEvidence',
    'Get-MeechoInventoryContentSha256',
    'Write-MeechoInventoryEvidence',
    'Get-MeechoAllowedEnvironmentNames',
    'Get-MeechoRequiredEnvironmentNames',
    'Test-MeechoEnvironmentNameContract',
    'Get-MeechoNormalizedPath',
    'Test-MeechoPathUnder',
    'Assert-MeechoNoReparsePoint',
    'Get-MeechoFileInventory',
    'Compare-MeechoFileInventory',
    'Invoke-MeechoAuditedProcess',
    'Test-MeechoStepRecord',
    'Write-MeechoRunManifest',
    'Resolve-MeechoManifestReference',
    'Test-MeechoRunLogContract'
)
