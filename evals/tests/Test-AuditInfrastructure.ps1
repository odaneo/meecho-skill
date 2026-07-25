Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'TestSupport.psm1') -Force
$repoRoot = Get-MeechoRepoRoot
Import-Module (Join-Path $repoRoot 'evals/scripts/EvalAudit.psm1') -Force

$allowedEnvironmentNames = @(
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

$testRoot = New-MeechoTestRoot
$previousSecrets = [ordered]@{
    OPENAI_API_KEY = $env:OPENAI_API_KEY
    MEECHO_TOKEN = $env:MEECHO_TOKEN
}
$secretMarker = 'secret-' + [guid]::NewGuid().ToString('N')
try {
    $env:OPENAI_API_KEY = $secretMarker + '-openai'
    $env:MEECHO_TOKEN = $secretMarker + '-token'

    $allowedEnvironment = [ordered]@{
        SystemRoot = $env:SystemRoot
        WINDIR = $env:WINDIR
        COMSPEC = $env:COMSPEC
        PATHEXT = $env:PATHEXT
        PATH = $env:PATH
        TEMP = (Join-Path $testRoot 'temp')
        TMP = (Join-Path $testRoot 'temp')
        LOCALAPPDATA = (Join-Path $testRoot 'local')
        APPDATA = (Join-Path $testRoot 'roaming')
        USERPROFILE = (Join-Path $testRoot 'home')
        HOME = (Join-Path $testRoot 'home')
        CODEX_HOME = (Join-Path $testRoot 'codex-home')
        CODEX_SQLITE_HOME = (Join-Path $testRoot 'state')
    }
    foreach ($path in @(
        $allowedEnvironment.TEMP,
        $allowedEnvironment.LOCALAPPDATA,
        $allowedEnvironment.APPDATA,
        $allowedEnvironment.USERPROFILE,
        $allowedEnvironment.CODEX_HOME,
        $allowedEnvironment.CODEX_SQLITE_HOME
    ) | Sort-Object -Unique) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }

    $stepRoot = Join-Path $testRoot 'logs'
    $command = @'
[Console]::Out.WriteLine((Get-ChildItem Env: | ForEach-Object Name | Sort-Object) -join ',')
[Console]::Error.WriteLine('stderr-marker')
exit 7
'@
    $result = Invoke-MeechoAuditedProcess `
        -FilePath (Join-Path $PSHOME 'pwsh.exe') `
        -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $command) `
        -Environment $allowedEnvironment `
        -StepLogRoot $stepRoot `
        -StepName 'environment-probe'

    Assert-Equal 7 $result.ExitCode 'Real child exit code must propagate.'
    Assert-True (Test-Path -LiteralPath $result.StdoutPath -PathType Leaf) 'stdout log missing.'
    Assert-True (Test-Path -LiteralPath $result.StderrPath -PathType Leaf) 'stderr log missing.'
    Assert-True ((Get-Content -LiteralPath $result.StderrPath -Raw -Encoding UTF8).Contains('stderr-marker')) 'stderr was not captured separately.'
    Assert-False ((Get-Content -LiteralPath $result.StdoutPath -Raw -Encoding UTF8).Contains('stderr-marker')) 'stderr leaked into stdout.'

    $childNames = @(
        (Get-Content -LiteralPath $result.StdoutPath -Raw -Encoding UTF8).Trim() -split ','
    )
    foreach ($required in $allowedEnvironment.Keys) {
        Assert-True ($childNames -contains $required) "Whitelisted variable missing in child: $required"
    }
    foreach ($forbidden in 'OPENAI_API_KEY', 'MEECHO_TOKEN') {
        Assert-False ($childNames -contains $forbidden) "Sensitive parent variable leaked: $forbidden"
    }

    $record = Read-MeechoJson -Path $result.RecordPath
    Assert-SequenceEqual @($allowedEnvironment.Keys | Sort-Object) @($record.environmentNames | Sort-Object) 'Process record must store environment names only.'
    foreach ($name in $record.environmentNames) {
        Assert-True ($name -in $allowedEnvironmentNames) "ProcessStartInfo received an unapproved environment name: $name"
    }
    $allLogs = (
        Get-ChildItem -LiteralPath $stepRoot -Recurse -File |
            ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 }
    ) -join "`n"
    Assert-False ($allLogs.Contains($secretMarker)) 'A secret marker appeared in audit logs.'

    $rejectedRoot = Join-Path $testRoot 'rejected-environment'
    $environmentWithExtraName = [ordered]@{}
    foreach ($entry in $allowedEnvironment.GetEnumerator()) {
        $environmentWithExtraName[$entry.Key] = $entry.Value
    }
    $environmentWithExtraName.MEECHO_DEBUG = '1'
    Assert-Throws {
        Invoke-MeechoAuditedProcess `
            -FilePath (Join-Path $PSHOME 'pwsh.exe') `
            -ArgumentList @('-NoLogo', '-NoProfile', '-Command', 'exit 0') `
            -Environment $environmentWithExtraName `
            -StepLogRoot $rejectedRoot `
            -StepName 'must-not-run'
    } 'Audited child execution must reject every non-plan environment name.' 'not in the audited allowlist'
    Assert-False (Test-Path -LiteralPath (Join-Path $rejectedRoot 'must-not-run.record.json')) 'Rejected environment must not produce a successful process record.'

    $inventoryRoot = Join-Path $testRoot 'inventory'
    New-Item -ItemType Directory -Path (Join-Path $inventoryRoot 'empty') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $inventoryRoot 'nested') -Force | Out-Null
    $contentMarker = 'content-' + [guid]::NewGuid().ToString('N')
    Set-Content -LiteralPath (Join-Path $inventoryRoot 'visible.txt') -Value $contentMarker -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $inventoryRoot 'project-token-not-a-secret.txt') -Value 'ordinary prose' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $inventoryRoot 'auth.json') -Value ($secretMarker + '-auth') -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $inventoryRoot 'nested/auth.json') -Value 'nested ordinary fixture' -Encoding UTF8

    $defaultInventory = Get-MeechoFileInventory -Path $inventoryRoot
    Assert-True (@($defaultInventory | Where-Object path -ceq 'empty').Count -eq 1) 'Inventory must record an empty directory.'
    Assert-True (@($defaultInventory | Where-Object path -ceq 'auth.json').Count -eq 1) 'Inventory must not silently drop auth.json without an explicit exact exclusion.'
    Assert-True (@($defaultInventory | Where-Object path -ceq 'project-token-not-a-secret.txt').Count -eq 1) 'Broad key/secret/token matching must not hide ordinary files.'
    foreach ($entry in $defaultInventory) {
        Assert-True ($entry.type -in @('directory', 'file')) 'Every inventory entry needs a file-system type.'
        Assert-False ([string]::IsNullOrWhiteSpace([string]$entry.path)) 'Every inventory entry needs a relative path.'
        Assert-Matches ([string]$entry.sha256) '^[a-f0-9]{64}$' 'Every inventory entry needs a stable SHA-256.'
    }

    $explicitInventory = Get-MeechoFileInventory `
        -Path $inventoryRoot `
        -ExcludedRelativePath @('auth.json')
    Assert-False (@($explicitInventory | Where-Object path -ceq 'auth.json').Count -gt 0) 'An explicitly excluded exact auth path must be absent.'
    Assert-True (@($explicitInventory | Where-Object path -ceq 'nested/auth.json').Count -eq 1) 'Exact authentication exclusions must not expand to same-name files elsewhere.'
    Assert-False (($explicitInventory | ConvertTo-Json -Depth 20).Contains($contentMarker)) 'Inventory must not include file contents.'

    $before = Get-MeechoFileInventory -Path $inventoryRoot -ExcludedRelativePath @('auth.json')
    New-Item -ItemType Directory -Path (Join-Path $inventoryRoot 'new-empty-directory') | Out-Null
    $after = Get-MeechoFileInventory -Path $inventoryRoot -ExcludedRelativePath @('auth.json')
    $comparison = Compare-MeechoFileInventory -Before $before -After $after
    Assert-False $comparison.Equal 'Inventory comparison must detect an added empty directory.'
    Assert-True ($comparison.Added -contains 'new-empty-directory') 'The added empty directory must be named in the comparison.'

    $timestampOnlyInventory = @(
        $before | ForEach-Object {
            [pscustomobject][ordered]@{
                type = $_.type
                path = $_.path
                length = $_.length
                lastWriteTimeUtc = '2099-01-01T00:00:00.0000000Z'
                sha256 = $_.sha256
            }
        }
    )
    Assert-Equal (
        Get-MeechoInventoryContentSha256 -Inventory $before
    ) (
        Get-MeechoInventoryContentSha256 -Inventory $timestampOnlyInventory
    ) 'Fresh control/treatment profile identity must ignore last-write timestamps.'
    Assert-False (
        Compare-MeechoFileInventory `
            -Before $before `
            -After $timestampOnlyInventory
    ).Equal 'Full before/after mutation checks must still detect timestamp-only changes.'

    $evidencePath = Join-Path $testRoot 'inventory-evidence/profile-before-inventory.json'
    $projectedInventory = @(
        ConvertTo-MeechoInventoryEvidence -Inventory $before
    )
    Assert-Equal @($before).Count $projectedInventory.Count 'Evidence projection must preserve every inventory entry.'
    foreach ($entry in $projectedInventory) {
        Assert-SequenceEqual @(
            'type',
            'path',
            'length',
            'sha256'
        ) @($entry.PSObject.Properties.Name) 'Inventory evidence must expose exactly four safe fields.'
        Assert-False ([System.IO.Path]::IsPathFullyQualified([string]$entry.path)) 'Inventory evidence paths must remain relative.'
        Assert-False ([string]$entry.path -match '(^|/)\.\.(/|$)') 'Inventory evidence paths must not traverse upward.'
    }

    $writtenEvidence = Write-MeechoInventoryEvidence `
        -Inventory $before `
        -Path $evidencePath
    Assert-True (Test-Path -LiteralPath $evidencePath -PathType Leaf) 'Inventory evidence was not written.'
    Assert-Matches ([string]$writtenEvidence.Sha256) '^[a-f0-9]{64}$' 'Inventory evidence needs a file hash.'
    Assert-Matches ([string]$writtenEvidence.InventorySha256) '^[a-f0-9]{64}$' 'Inventory evidence needs a content-identity hash.'
    $loadedEvidence = @(
        Get-Content -LiteralPath $evidencePath -Raw -Encoding UTF8 |
            ConvertFrom-Json -Depth 20
    )
    Assert-Equal (
        Get-MeechoInventoryContentSha256 -Inventory $loadedEvidence
    ) $writtenEvidence.InventorySha256 'Persisted inventory evidence must reproduce its declared content-identity hash.'
    Assert-Equal (
        Get-MeechoInventoryContentSha256 -Inventory $before
    ) $writtenEvidence.InventorySha256 'Evidence projection must retain the original content identity.'
    $evidenceJson = Get-Content -LiteralPath $evidencePath -Raw -Encoding UTF8
    Assert-False $evidenceJson.Contains('lastWriteTimeUtc') 'Inventory evidence must not persist timestamps.'
    Assert-False $evidenceJson.Contains($contentMarker) 'Inventory evidence must not persist file contents.'
    Assert-False $evidenceJson.Contains($inventoryRoot) 'Inventory evidence must not persist an absolute root.'

    $evidenceFileHashBeforeRefusal = (
        Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    Assert-Throws {
        Write-MeechoInventoryEvidence -Inventory $after -Path $evidencePath
    } 'Inventory evidence must never overwrite an existing destination.' 'INVENTORY_EVIDENCE_ALREADY_EXISTS'
    Assert-Equal $evidenceFileHashBeforeRefusal (
        Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256
    ).Hash.ToLowerInvariant() 'A refused second write must leave the original evidence unchanged.'

    Assert-Throws {
        ConvertTo-MeechoInventoryEvidence -Inventory @(
            [pscustomobject][ordered]@{
                type = 'file'
                path = (Join-Path $inventoryRoot 'visible.txt')
                length = 1
                sha256 = ('a' * 64)
            }
        )
    } 'Inventory evidence must reject absolute paths.' 'INVENTORY_EVIDENCE_INVALID_PATH'

    $profileEvidenceRoot = Join-Path $testRoot 'profile-evidence'
    $profileRoot = Join-Path $profileEvidenceRoot 'profile'
    [void][IO.Directory]::CreateDirectory($profileRoot)
    $profileContentPath = Join-Path $profileRoot 'preferences.md'
    [IO.File]::WriteAllText(
        $profileContentPath,
        'before-profile-content',
        [Text.UTF8Encoding]::new($false)
    )
    $profileBeforeInventory = @(Get-MeechoFileInventory -Path $profileRoot)
    $profileBeforeEvidencePath = Join-Path (
        Join-Path $profileEvidenceRoot 'artifacts'
    ) 'profile-before-inventory.json'
    $profileAfterEvidencePath = Join-Path (
        Join-Path $profileEvidenceRoot 'artifacts'
    ) 'profile-after-inventory.json'
    $profileBeforeEvidence = Write-MeechoInventoryEvidence `
        -Inventory $profileBeforeInventory `
        -Path $profileBeforeEvidencePath
    Assert-False (
        Test-Path -LiteralPath $profileAfterEvidencePath
    ) 'A missing profile-after inventory must remain observable before the terminal snapshot.'

    [IO.File]::WriteAllText(
        $profileContentPath,
        'after-profile-content',
        [Text.UTF8Encoding]::new($false)
    )
    $profileAfterInventory = @(Get-MeechoFileInventory -Path $profileRoot)
    $profileAfterEvidence = Write-MeechoInventoryEvidence `
        -Inventory $profileAfterInventory `
        -Path $profileAfterEvidencePath
    Assert-True (
        Test-Path -LiteralPath $profileAfterEvidencePath -PathType Leaf
    ) 'The terminal profile-after inventory is missing.'
    Assert-False (
        $profileBeforeEvidence.InventorySha256 -ceq
        $profileAfterEvidence.InventorySha256
    ) 'A profile content change must change the persisted content-identity digest.'
    Assert-Equal (
        Get-MeechoInventoryContentSha256 -Inventory $profileAfterInventory
    ) $profileAfterEvidence.InventorySha256 'The profile-after digest must be recomputable from its fixed evidence file.'
    $profileAfterFileHash = (
        Get-FileHash -LiteralPath $profileAfterEvidencePath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    Assert-Throws {
        Write-MeechoInventoryEvidence `
            -Inventory $profileBeforeInventory `
            -Path $profileAfterEvidencePath
    } 'A second terminal profile-after snapshot must not overwrite the first one.' 'INVENTORY_EVIDENCE_ALREADY_EXISTS'
    Assert-Equal $profileAfterFileHash (
        Get-FileHash -LiteralPath $profileAfterEvidencePath -Algorithm SHA256
    ).Hash.ToLowerInvariant() 'A refused profile-after rewrite must preserve the original evidence.'

    $atomicManifestPath = Join-Path $testRoot 'atomic-manifest/run-manifest.json'
    $originalManifest = [ordered]@{
        schemaVersion = 1
        kind = 'atomic-writer-probe'
        status = 'original'
    }
    Write-MeechoRunManifest -Manifest $originalManifest -Path $atomicManifestPath
    $originalManifestHash = (
        Get-FileHash -LiteralPath $atomicManifestPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    $manifestLock = [IO.File]::Open(
        $atomicManifestPath,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::None
    )
    try {
        Assert-Throws {
            Write-MeechoRunManifest `
                -Manifest ([ordered]@{
                    schemaVersion = 1
                    kind = 'atomic-writer-probe'
                    status = 'replacement'
                }) `
                -Path $atomicManifestPath
        } 'A failed atomic manifest replacement must surface an error.'
    }
    finally {
        $manifestLock.Dispose()
    }
    Assert-Equal $originalManifestHash (
        Get-FileHash -LiteralPath $atomicManifestPath -Algorithm SHA256
    ).Hash.ToLowerInvariant() 'A failed atomic manifest replacement must preserve the previous complete file.'
    Assert-Equal 0 @(
        Get-ChildItem `
            -LiteralPath (Split-Path -Parent $atomicManifestPath) `
            -Filter '.*.tmp' `
            -File
    ).Count 'A failed atomic manifest replacement must clean its temporary file.'

    Assert-True (Test-MeechoStepRecord -RecordPath $result.RecordPath) 'Untampered step record must validate.'
    $stepRecord = Read-MeechoJson -Path $result.RecordPath
    Assert-Matches ([string]$stepRecord.commandSha256) '^[a-f0-9]{64}$' 'A launched executable needs a path-free binary hash.'
    $originalCommandSha256 = [string]$stepRecord.commandSha256
    $stepRecord.commandSha256 = 'not-a-sha256'
    $stepRecord | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $result.RecordPath -Encoding UTF8
    Assert-False (Test-MeechoStepRecord -RecordPath $result.RecordPath) 'Malformed executable hash must fail step-record validation.'
    $stepRecord.commandSha256 = $originalCommandSha256
    $stepRecord | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $result.RecordPath -Encoding UTF8
    Assert-True (Test-MeechoStepRecord -RecordPath $result.RecordPath) 'Restoring the executable hash should restore the step-record contract.'
    Add-Content -LiteralPath $result.StdoutPath -Value 'tampered' -Encoding UTF8
    Assert-False (Test-MeechoStepRecord -RecordPath $result.RecordPath) 'Tampered stdout must fail checksum validation.'
}
finally {
    foreach ($entry in $previousSecrets.GetEnumerator()) {
        if ($null -eq $entry.Value) {
            Remove-Item -LiteralPath "Env:$($entry.Key)" -ErrorAction SilentlyContinue
        }
        else {
            Set-Item -LiteralPath "Env:$($entry.Key)" -Value $entry.Value
        }
    }
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Output 'PASS Test-AuditInfrastructure'
