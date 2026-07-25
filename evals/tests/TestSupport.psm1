Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-MeechoRepoRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

function Assert-True {
    param(
        [Parameter(Mandatory)]
        [bool] $Condition,

        [Parameter(Mandatory)]
        [string] $Message
    )

    if (-not $Condition) {
        throw "ASSERT TRUE FAILED: $Message"
    }
}

function Assert-False {
    param(
        [Parameter(Mandatory)]
        [bool] $Condition,

        [Parameter(Mandatory)]
        [string] $Message
    )

    if ($Condition) {
        throw "ASSERT FALSE FAILED: $Message"
    }
}

function Assert-Equal {
    param(
        [AllowNull()]
        $Expected,

        [AllowNull()]
        $Actual,

        [Parameter(Mandatory)]
        [string] $Message
    )

    if ($Expected -ne $Actual) {
        throw "ASSERT EQUAL FAILED: $Message`nExpected: $Expected`nActual:   $Actual"
    }
}

function Assert-SequenceEqual {
    param(
        [AllowEmptyCollection()]
        [object[]] $Expected,

        [AllowEmptyCollection()]
        [object[]] $Actual,

        [Parameter(Mandatory)]
        [string] $Message
    )

    $expectedJson = ConvertTo-Json @($Expected) -Compress -Depth 20
    $actualJson = ConvertTo-Json @($Actual) -Compress -Depth 20
    if ($expectedJson -cne $actualJson) {
        throw "ASSERT SEQUENCE FAILED: $Message`nExpected: $expectedJson`nActual:   $actualJson"
    }
}

function Assert-Matches {
    param(
        [AllowEmptyString()]
        [string] $Actual,

        [Parameter(Mandatory)]
        [string] $Pattern,

        [Parameter(Mandatory)]
        [string] $Message
    )

    if ($Actual -notmatch $Pattern) {
        throw "ASSERT MATCH FAILED: $Message`nPattern: $Pattern`nActual:  $Actual"
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory)]
        [scriptblock] $ScriptBlock,

        [Parameter(Mandatory)]
        [string] $Message,

        [string] $ErrorPattern
    )

    try {
        & $ScriptBlock
    }
    catch {
        if ($ErrorPattern -and $_.Exception.Message -notmatch $ErrorPattern) {
            throw "ASSERT THROWS FAILED: $Message`nWrong error: $($_.Exception.Message)"
        }
        return
    }

    throw "ASSERT THROWS FAILED: $Message`nNo exception was thrown."
}

function Assert-PathUnder {
    param(
        [Parameter(Mandatory)]
        [string] $Child,

        [Parameter(Mandatory)]
        [string] $Parent,

        [Parameter(Mandatory)]
        [string] $Message
    )

    $childPath = [IO.Path]::GetFullPath($Child).TrimEnd('\', '/')
    $parentPath = [IO.Path]::GetFullPath($Parent).TrimEnd('\', '/')
    $prefix = $parentPath + [IO.Path]::DirectorySeparatorChar
    if (-not $childPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "ASSERT PATH FAILED: $Message`nParent: $parentPath`nChild:  $childPath"
    }
}

function New-MeechoTestRoot {
    $path = Join-Path ([IO.Path]::GetTempPath()) ('meecho-task1-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path | Out-Null
    return $path
}

function Read-MeechoJson {
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 50
}

Export-ModuleMember -Function @(
    'Get-MeechoRepoRoot',
    'Assert-True',
    'Assert-False',
    'Assert-Equal',
    'Assert-SequenceEqual',
    'Assert-Matches',
    'Assert-Throws',
    'Assert-PathUnder',
    'New-MeechoTestRoot',
    'Read-MeechoJson'
)
