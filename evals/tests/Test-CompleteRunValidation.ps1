[CmdletBinding()]
param([string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop';$runner=Join-Path $RepositoryRoot 'evals/scripts/Invoke-EvalValidation.ps1';$name="fixture-$([guid]::NewGuid().ToString('N'))";$fixture=Join-Path $RepositoryRoot "evals/logs/$name"
function Invoke-Validator([bool]$ExpectedPass){& pwsh -NoProfile -File $runner -RepositoryRoot $RepositoryRoot -VerifyRunDirectory $fixture;$code=$LASTEXITCODE;if($ExpectedPass -and $code){throw 'Valid fixture was rejected.'};if(-not $ExpectedPass -and -not $code){throw 'Invalid fixture was accepted.'}}
try{
 New-Item -ItemType Directory -Force -Path "$fixture/steps","$fixture/cases"|Out-Null
 @{runId='20990101T000000Z';steps=@();cases=@()}|ConvertTo-Json|Set-Content "$fixture/run-manifest.json";Set-Content "$fixture/checksums.sha256" 'fixture'
 Invoke-Validator $false
 $steps=@();$cases=@();1..9|ForEach-Object{$id='{0:D2}'-f $_;$steps+=@{name="case-$id";log="steps/case-$id.log";exitCode=0};$cases+=@{caseId=$id;exitCode=0};New-Item -ItemType Directory -Force -Path "$fixture/cases/$id"|Out-Null;Set-Content "$fixture/steps/case-$id.log" 'real step output';Set-Content "$fixture/cases/$id/events.jsonl" '{}';Set-Content "$fixture/cases/$id/stderr.log" '';Set-Content "$fixture/cases/$id/final.md" 'final';@{caseId=$id;observableAssertions=@(@{id="case-$id-observable-01";text='assertion';status='needs-human-review'});rubric=@(1..17|ForEach-Object{@{id=$_;score='needs-human-review'}})}|ConvertTo-Json -Depth 5|Set-Content "$fixture/cases/$id/result.json"}
 @{runId='20990101T000000Z';startedAtUtc='2099-01-01T00:00:00Z';endedAtUtc='2099-01-01T00:01:00Z';executionUser='test';gitCommit='test';commandVersions=@{powershell='test'};isolationPrecheck=@{status='passed'};status='completed-needs-human-review';exitCode=0;steps=$steps;cases=$cases}|ConvertTo-Json -Depth 8|Set-Content "$fixture/run-manifest.json"
 $files=Get-ChildItem $fixture -Recurse -File|Where-Object Name -ne 'checksums.sha256';$files|ForEach-Object{"$((Get-FileHash $_ -Algorithm SHA256).Hash.ToLowerInvariant())  $($_.FullName.Substring($RepositoryRoot.Length).TrimStart('\','/') -replace '\\','/')"}|Set-Content "$fixture/checksums.sha256"
 Invoke-Validator $true;Write-Output 'Complete run log validation rejects fake logs/checksums and accepts a recomputable fixture.'
}finally{Remove-Item $fixture -Recurse -Force -ErrorAction SilentlyContinue}
