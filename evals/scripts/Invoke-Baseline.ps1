[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [string]$IsolationConfigPath = (Join-Path $RepositoryRoot 'evals/sandboxes/isolation-config.json')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'EvalAudit.psm1') -Force

function Save-Json($Value, [string]$Path) { $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding utf8 }
function Add-Step([string]$Name, [string]$Action, [string[]]$Stdout, [string[]]$Stderr, [int]$ExitCode, [datetimeoffset]$StartedAtUtc, [datetimeoffset]$EndedAtUtc) {
    $log = "steps/$Name.log"
    $conclusion = if($ExitCode -eq 0){'passed'}else{'failed'}
    Write-EvalStepLog -Path (Join-Path $run.Path $log) -Action $Action -Stdout $Stdout -Stderr $Stderr -ExitCode $ExitCode -Conclusion $conclusion -StartedAtUtc $StartedAtUtc -EndedAtUtc $EndedAtUtc
    $manifest.steps += [ordered]@{name=$Name;log=$log;exitCode=$ExitCode;status=$conclusion;conclusion=$conclusion}
}
function Finish([string]$Status, [int]$ExitCode) { $manifest.status=$Status;$manifest.exitCode=$ExitCode;$manifest.endedAtUtc=[datetimeoffset]::UtcNow.ToString('o');Save-Json $manifest $manifestPath;Write-EvalChecksums -RepositoryRoot $RepositoryRoot -RunDirectory $run.Path;Write-Output "BASELINE_RUN_ID=$($run.Id) STATUS=$Status";exit $ExitCode }
function Get-Inventory([string]$Path) { if(-not(Test-Path -LiteralPath $Path)){return @()}; @(Get-ChildItem -LiteralPath $Path -Recurse -Force -File | ForEach-Object {[ordered]@{path=$_.FullName.Substring($Path.Length).TrimStart('\','/');size=$_.Length;mtimeUtc=$_.LastWriteTimeUtc.ToString('o');sha256=(Get-FileHash $_ -Algorithm SHA256).Hash.ToLowerInvariant()}}) }
function Get-Section([string]$Text,[string]$Heading){$m=[regex]::Match($Text,"(?ms)^## $([regex]::Escape($Heading))\s*\r?\n(.*?)(?=^## |\z)");if(-not $m.Success){throw "Missing $Heading"};$m.Groups[1].Value.Trim()}
function Stage-Case([string]$CaseId,[string]$CaseText,[string]$Sandbox) {
    New-Item -ItemType Directory -Force -Path $Sandbox | Out-Null
    $source=Join-Path $RepositoryRoot 'evals/fixtures/synthetic-corpus'; Copy-Item (Join-Path $source 'high-school') (Join-Path $Sandbox 'high-school') -Recurse -Force
    if($CaseId -in @('02','06')){Copy-Item (Join-Path $source 'adult-contrast') (Join-Path $Sandbox 'adult-contrast') -Recurse -Force}
    if($CaseId -eq '05'){Set-Content (Join-Path $Sandbox 'input.md') '窗外下雨，作业还没写完。' -Encoding utf8}
    if($CaseId -eq '03'){foreach($p in 'alpha','beta','gamma'){New-Item -ItemType Directory -Force -Path (Join-Path $Sandbox $p)|Out-Null;Set-Content (Join-Path $Sandbox "$p/README.md") "Independent $p project." -Encoding utf8}}
}

$run=New-EvalRunDirectory -RepositoryRoot $RepositoryRoot;$manifestPath=Join-Path $run.Path 'run-manifest.json';$current=[System.Security.Principal.WindowsIdentity]::GetCurrent();$git=Invoke-EvalProcess -FilePath 'git' -ArgumentList @('-C',$RepositoryRoot,'rev-parse','HEAD');$gitCommit=if($git.ExitCode -eq 0){($git.Stdout -join "`n").Trim()}else{'unavailable'};$manifest=[ordered]@{runId=$run.Id;startedAtUtc=[datetimeoffset]::UtcNow.ToString('o');endedAtUtc=$null;executionUser=$current.Name;executionSid=$current.User.Value;gitCommit=$gitCommit;commandVersions=@{};isolationPrecheck=@{};status='running';exitCode=$null;steps=@();cases=@()};Save-Json $manifest $manifestPath
$preflightStarted=[datetimeoffset]::UtcNow
$fail=[System.Collections.Generic.List[string]]::new();$facts=[System.Collections.Generic.List[string]]::new();$account=Get-LocalUser -Name 'meecho-eval' -ErrorAction SilentlyContinue
if($null -eq $account){$fail.Add('dedicated-account-missing')}elseif($account.SID.Value -ne $current.User.Value){$fail.Add('current-sid-does-not-match-meecho-eval')}
if(-not(Test-Path -LiteralPath $IsolationConfigPath)){$fail.Add('isolation-config-missing')}else{try{$cfg=Get-Content $IsolationConfigPath -Raw|ConvertFrom-Json;if([string]::IsNullOrWhiteSpace($cfg.developerProfileSid)-or [string]::IsNullOrWhiteSpace($cfg.developerHomeCanary)) {throw 'missing required fields'};$key="HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($cfg.developerProfileSid)";$devHome=[Environment]::ExpandEnvironmentVariables((Get-ItemProperty $key -ErrorAction Stop).ProfileImagePath);$repoFull=(Resolve-Path $RepositoryRoot).Path;if($repoFull.StartsWith($devHome,[StringComparison]::OrdinalIgnoreCase)){$fail.Add('repository-is-under-developer-home')};$canary=Join-Path $devHome $cfg.developerHomeCanary;try{Get-ChildItem -LiteralPath $canary -Force -ErrorAction Stop|Out-Null;$fail.Add('developer-canary-readable')}catch [System.UnauthorizedAccessException]{$facts.Add('developer-canary=access-denied')}catch [System.Management.Automation.ItemNotFoundException]{$fail.Add('developer-canary-not-found')}catch{$fail.Add('developer-canary-ambiguous-error')}}catch{$fail.Add('isolation-config-invalid')}}
$manifest.isolationPrecheck=[ordered]@{status=$(if($fail.Count){'failed'}else{'passed'});accountSid=$(if($account){$account.SID.Value}else{'unavailable'});currentSid=$current.User.Value;checks=@($facts);failures=@($fail)};$preflightEnded=[datetimeoffset]::UtcNow;Add-Step '01-isolation-preflight' 'Resolve dedicated SID, developer profile path, and deny canary' @($facts) @($fail) $(if($fail.Count){3}else{0}) $preflightStarted $preflightEnded;if($fail.Count){Finish 'BLOCKED_NOT_RUN' 3}
foreach($cmd in @(@('codex','--version'),@('codex','login','status'),@('codex','plugin','list'))){$result=Invoke-EvalProcess -FilePath $cmd[0] -ArgumentList @($cmd[1..($cmd.Count-1)]);$code=$result.ExitCode;$name=($cmd -join '-').Replace(' ','-');Add-Step "02-$name" ($cmd -join ' ') $result.Stdout $result.Stderr $code $result.StartedAtUtc $result.EndedAtUtc;$combined=@($result.Stdout)+@($result.Stderr);$manifest.commandVersions[$name]=($combined -join ' ');if($code -ne 0 -or ($combined -join ' ') -match '(?i)meecho|not logged in'){$fail.Add("codex-readiness-$name")}}
$homeScanStarted=[datetimeoffset]::UtcNow;$codexHome=if($env:CODEX_HOME){$env:CODEX_HOME}else{Join-Path $env:USERPROFILE '.codex'};$hits=@();if(Test-Path $codexHome){$hits=@(Get-ChildItem $codexHome -Recurse -Force -ErrorAction SilentlyContinue|Where-Object Name -match '(?i)meecho');if($hits.Count){$fail.Add('meecho-present-in-codex-home')}};$homeScanEnded=[datetimeoffset]::UtcNow;Add-Step '03-codex-home-scan' 'Scan current user Codex home for Meecho names' @("matches=$($hits.Count)") @() $(if($hits.Count){3}else{0}) $homeScanStarted $homeScanEnded;if($fail.Count){$manifest.isolationPrecheck.failures=@($fail);Finish 'BLOCKED_NOT_RUN' 3}
foreach($n in 1..9){
    $id='{0:D2}' -f $n
    $case=Get-ChildItem (Join-Path $RepositoryRoot 'evals/cases') -Filter "$id-*.md"|Select-Object -First 1
    $dir=Join-Path $run.Path "cases/$id"
    $box=Join-Path $RepositoryRoot "evals/sandboxes/case-$id"
    New-Item -ItemType Directory -Force -Path $dir|Out-Null
    Stage-Case $id (Get-Content $case -Raw) $box
    $profileRoot=Join-Path $env:USERPROFILE '.meecho'
    $before=[ordered]@{project=Get-Inventory $box;profile=Get-Inventory $profileRoot}
    $text=Get-Content $case -Raw
    $prompt="$(Get-Section $text 'User request')`n`n允许读取范围：$(Get-Section $text 'Accessible files')"
    $events=Join-Path $dir 'events.jsonl'
    $stderr=Join-Path $dir 'stderr.log'
    $final=Join-Path $dir 'final.md'
    $mode=if($id -in '02','07','08','09'){'workspace-write'}else{'read-only'}
    $codex=Invoke-EvalProcess -FilePath 'codex' -WorkingDirectory $box -ArgumentList @('exec','--ephemeral','--json','--ignore-user-config','--ignore-rules','--sandbox',$mode,'--skip-git-repo-check','-C',$box,'-o',$final,$prompt)
    $codex.Stdout|Set-Content -LiteralPath $events -Encoding utf8
    $codex.Stderr|Set-Content -LiteralPath $stderr -Encoding utf8
    $code=$codex.ExitCode
    if(-not(Test-Path $final)){Set-Content $final ''}
    $after=[ordered]@{project=Get-Inventory $box;profile=Get-Inventory $profileRoot}
    $assert=@([ordered]@{id="case-$id-observable-01";text=(Get-Section $text 'Observable assertions');status='needs-human-review'})
    $rubric=@(1..17|ForEach-Object{[ordered]@{id=$_;score='needs-human-review'}})
    Save-Json ([ordered]@{caseId=$id;status=$(if($code){'failed'}else{'completed-needs-human-review'});observableAssertions=$assert;rubric=$rubric;inventoryBefore=$before;inventoryAfter=$after;inventoryChanged=(@($before.project|ConvertTo-Json -Compress) -ne @($after.project|ConvertTo-Json -Compress));exitCode=$code}) (Join-Path $dir 'result.json')
    Add-Step "case-$id" "codex exec --ephemeral --json --ignore-user-config --ignore-rules --sandbox $mode" $codex.Stdout $codex.Stderr $code $codex.StartedAtUtc $codex.EndedAtUtc
    $manifest.cases+=@([ordered]@{caseId=$id;status=$(if($code){'failed'}else{'completed-needs-human-review'});exitCode=$code})
    Save-Json $manifest $manifestPath
}
Finish $(if(@($manifest.cases|Where-Object exitCode -ne 0).Count){'failed'}else{'completed-needs-human-review'}) $(if(@($manifest.cases|Where-Object exitCode -ne 0).Count){1}else{0})
