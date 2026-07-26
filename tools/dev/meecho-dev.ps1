[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('doctor', 'validate', 'reinstall', 'smoke')]
    [string] $Command
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$pluginRoot = Join-Path $repoRoot 'plugins\meecho'
$manifestPath = Join-Path $pluginRoot '.codex-plugin\plugin.json'
$marketplacePath = Join-Path $repoRoot '.agents\plugins\marketplace.json'
$skillPath = Join-Path $pluginRoot 'skills\meecho\SKILL.md'
$startedAt = [DateTime]::UtcNow
$runId = '{0}-{1}' -f (
    $startedAt.ToString('yyyyMMddTHHmmssfffZ'),
    $Command.ToLowerInvariant()
)
$runDirectory = Join-Path $repoRoot "evals\logs\dev\$runId"
New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
$textLogPath = Join-Path $runDirectory 'command.txt'
$resultPath = Join-Path $runDirectory 'result.json'

function Get-RequiredCommand {
    param(
        [Parameter(Mandatory)]
        [string] $Name
    )

    $commandInfo = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $commandInfo) {
        throw "找不到命令：$Name"
    }
    return $commandInfo.Source
}

function Get-DevelopmentPython {
    $userProfile = [Environment]::GetFolderPath('UserProfile')
    $bundledPython = Join-Path $userProfile (
        '.cache\codex-runtimes\codex-primary-runtime\' +
        'dependencies\python\python.exe'
    )
    if (Test-Path -LiteralPath $bundledPython -PathType Leaf) {
        return $bundledPython
    }

    foreach ($name in @('python3', 'python')) {
        $commandInfo = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $commandInfo) {
            return $commandInfo.Source
        }
    }

    throw (
        '找不到供 reinstall 使用的开发 Python。普通用户不需要 Python；' +
        '该依赖只用于本地 Plugin 开发重装。'
    )
}

function Get-CachebusterScript {
    $userProfile = [Environment]::GetFolderPath('UserProfile')
    $path = Join-Path $userProfile (
        '.codex\skills\.system\plugin-creator\' +
        'scripts\update_plugin_cachebuster.py'
    )
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "找不到官方 Plugin cachebuster 工具：$path"
    }
    return $path
}

function Get-PluginInfo {
    foreach ($path in @($manifestPath, $marketplacePath, $skillPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "缺少仓库文件：$path"
        }
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $marketplace = Get-Content -LiteralPath $marketplacePath -Raw -Encoding UTF8 |
        ConvertFrom-Json

    if ($manifest.name -cne 'meecho' -or $marketplace.name -cne 'meecho') {
        throw 'Plugin 和 marketplace 的名称必须都是 meecho。'
    }

    $entries = @(
        @($marketplace.plugins) | Where-Object { $_.name -ceq 'meecho' }
    )
    if (
        $entries.Count -ne 1 -or
        $entries[0].source.path -cne './plugins/meecho'
    ) {
        throw 'marketplace 必须恰好指向 ./plugins/meecho。'
    }

    return [pscustomobject]@{
        PluginName = 'meecho'
        MarketplaceName = 'meecho'
        Version = [string] $manifest.version
    }
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory)]
        [string] $FilePath,

        [AllowEmptyCollection()]
        [string[]] $Arguments = @(),

        [Parameter(Mandatory)]
        [string] $Label
    )

    Write-Host "[$Label] $FilePath $($Arguments -join ' ')"
    $output = @(& $FilePath @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    foreach ($line in $output) {
        Write-Host ([string] $line)
    }
    if ($exitCode -ne 0) {
        throw "$Label 失败，退出码：$exitCode"
    }
    return $output
}

function Invoke-Doctor {
    $info = Get-PluginInfo
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw '本地开发工具需要 PowerShell 7 或更高版本。'
    }

    $git = Get-RequiredCommand 'git'
    $codex = Get-RequiredCommand 'codex'
    $python = Get-DevelopmentPython
    $cachebuster = Get-CachebusterScript

    $null = Invoke-Checked $git @('--version') 'Git'
    $null = Invoke-Checked $codex @('--version') 'Codex'
    $null = Invoke-Checked $python @('--version') '开发 Python'

    Write-Host "[PASS] PowerShell $($PSVersionTable.PSVersion)"
    Write-Host "[PASS] cachebuster：$cachebuster"
    Write-Host (
        "[PASS] $($info.PluginName)@$($info.MarketplaceName) " +
        "版本 $($info.Version)"
    )
}

function Invoke-Validate {
    $null = Get-PluginInfo
    $pwsh = (Get-Process -Id $PID).Path
    $tests = @(
        Get-ChildItem -LiteralPath (
            Join-Path $repoRoot 'evals\contracts'
        ) -Filter 'Test-*.ps1' -File |
            Sort-Object Name
    )
    if ($tests.Count -eq 0) {
        throw '没有找到静态契约检查。'
    }

    foreach ($test in $tests) {
        $null = Invoke-Checked $pwsh @(
            '-NoProfile',
            '-File',
            $test.FullName
        ) $test.BaseName
    }
    Write-Host "[PASS] 全部 $($tests.Count) 个静态契约检查通过。"
}

function Invoke-Reinstall {
    $info = Get-PluginInfo
    $codex = Get-RequiredCommand 'codex'
    $python = Get-DevelopmentPython
    $cachebuster = Get-CachebusterScript
    $pluginReference = "$($info.PluginName)@$($info.MarketplaceName)"

    $null = Invoke-Checked $codex @('--version') 'Codex 预检'
    $null = Invoke-Checked $python @(
        $cachebuster,
        $pluginRoot
    ) '更新 Plugin cachebuster'
    $null = Invoke-Checked $codex @(
        'plugin',
        'marketplace',
        'add',
        $repoRoot,
        '--json'
    ) '注册本地 marketplace'
    $null = Invoke-Checked $codex @(
        'plugin',
        'add',
        $pluginReference,
        '--json'
    ) '重装 Meecho Plugin'

    Write-Host '[PASS] 重装完成；请新建 Codex 任务加载更新后的 Skill。'
}

function Invoke-Smoke {
    $info = Get-PluginInfo
    $codex = Get-RequiredCommand 'codex'
    $output = Invoke-Checked $codex @(
        'plugin',
        'list',
        '--json'
    ) '读取已安装 Plugin'

    $catalog = (($output | ForEach-Object { [string] $_ }) -join "`n") |
        ConvertFrom-Json
    $matches = @(
        @($catalog.installed) | Where-Object {
            $_.name -ceq $info.PluginName -and
            $_.marketplaceName -ceq $info.MarketplaceName -and
            [bool] $_.installed
        }
    )
    if ($matches.Count -ne 1) {
        throw '没有找到已安装的 meecho@meecho。'
    }

    $enabled = $matches[0].PSObject.Properties['enabled']
    if ($null -ne $enabled -and -not [bool] $enabled.Value) {
        throw 'meecho@meecho 已安装但未启用。'
    }

    Write-Host (
        '[PASS] meecho@meecho 已安装并启用；' +
        '本检查没有调用 Skill 或读取私人档案。'
    )
}

$status = 'PASS'
$exitCode = 0
Start-Transcript -LiteralPath $textLogPath -Force | Out-Null
try {
    Write-Host "Meecho 本地开发命令：$Command"
    Write-Host "仓库：$repoRoot"
    switch ($Command) {
        'doctor' { Invoke-Doctor }
        'validate' { Invoke-Validate }
        'reinstall' { Invoke-Reinstall }
        'smoke' { Invoke-Smoke }
    }
}
catch {
    $status = 'FAIL'
    $exitCode = 1
    Write-Host "[FAIL] $($_.Exception.Message)"
}
finally {
    Stop-Transcript | Out-Null
    $finishedAt = [DateTime]::UtcNow
    [ordered]@{
        schema = 1
        command = $Command
        status = $status
        started_at = $startedAt.ToString('o')
        finished_at = $finishedAt.ToString('o')
        text_log = $textLogPath
    } | ConvertTo-Json | Set-Content -LiteralPath $resultPath -Encoding UTF8
    Write-Host "日志：$runDirectory"
}

exit $exitCode
