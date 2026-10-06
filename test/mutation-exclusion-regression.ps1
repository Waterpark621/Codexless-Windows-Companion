$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module (Join-Path $repo 'MutationLock.psm1') -Force
Import-Module (Join-Path $repo 'WindowsTaskAdapter.psm1') -Force
Import-Module (Join-Path $repo 'UserSessionTask.psm1') -Force
Import-Module (Join-Path $repo 'CompanionRuntime.psm1') -Force
$fixture=Join-Path $PSScriptRoot ('.fixtures\mutation-exclusion-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force|Out-Null
$root=Join-Path $fixture 'root';New-Item -ItemType Directory -Path $root|Out-Null
$ready=Join-Path $fixture 'ready';$release=Join-Path $fixture 'release'
$holder=Join-Path $fixture 'holder.ps1'
@'
param([string]$Module,[string]$Root,[string]$Ready,[string]$Release)
$ErrorActionPreference='Stop'
Import-Module $Module -Force
Invoke-CompanionMutationLocked $Root {
 [IO.File]::WriteAllText($Ready,'ready')
 $deadline=[DateTime]::UtcNow.AddSeconds(90)
 while(!(Test-Path -LiteralPath $Release)){
  if([DateTime]::UtcNow -ge $deadline){throw 'fixture lease expired'}
  Start-Sleep -Milliseconds 50
 }
}
'@|Set-Content -LiteralPath $holder -Encoding utf8
$probe=Join-Path $root 'probe.ps1'
@'
param([string]$LauncherDirectory,[string]$UserSid,[string]$TaskName,[string]$TransactionId,[string]$GenerationId)
[IO.File]::WriteAllText((Join-Path $LauncherDirectory 'started.marker'),'unexpected-start')
'@|Set-Content -LiteralPath $probe -Encoding utf8
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$definition=New-HouseholdTaskDefinition -UserSid $sid -LauncherDirectory $root -HostScript $probe -PowerShellExe $exe -TaskName ('Codexless-NativeAdapter-Test-'+[Guid]::NewGuid().ToString('N')) -TransactionId ([Guid]::NewGuid().ToString('N')) -GenerationId ([Guid]::NewGuid().ToString('N'))
$registered=$false;$child=$null;$passed=0;$failed=0
function Check-Exclusion([string]$Name,[scriptblock]$Body,[scriptblock]$Mutated) {
 $refused=$false
 try{& $Body|Out-Null}catch{if($_.Exception.Message -like 'MUTATION_CONCURRENT_OPERATION*'){$refused=$true}else{throw}}
 if($refused -and !(& $Mutated)){$script:passed++;Write-Output "PASS $Name"}
 else{$script:failed++;Write-Output "FAIL $Name [E6_MUTATION_ENTERED_WHILE_OTHER_PROCESS_HELD_LOCK]"}
}
try {
 Register-HouseholdTaskCreateOnly $definition;$registered=$true
 $args=@('-NoProfile','-NonInteractive','-File',('"'+$holder+'"'),'-Module',('"'+(Join-Path $repo 'MutationLock.psm1')+'"'),'-Root',('"'+$root+'"'),'-Ready',('"'+$ready+'"'),'-Release',('"'+$release+'"'))
 $child=Start-Process $exe -ArgumentList $args -WindowStyle Hidden -PassThru
 $deadline=[DateTime]::UtcNow.AddSeconds(15)
 while(!(Test-Path -LiteralPath $ready)){if([DateTime]::UtcNow -ge $deadline){throw 'holder did not acquire lock'};Start-Sleep -Milliseconds 50}
 $baseline=$false
 try{Invoke-CompanionMutationLocked $root {throw 'entered'}}catch{$baseline=$_.Exception.Message -like 'MUTATION_CONCURRENT_OPERATION*'}
 if(!$baseline){throw 'test precondition: second process does not own shared lock'}
 $fixtureOwner=[pscustomobject]@{pid=101;createdAt='2026-10-03T00:00:00.0000000Z';userSid='S-1-5-21-111-222-333-1001'}
 $fixtureOwner|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $root 'task-owner.json')
 '101'|Set-Content -LiteralPath (Join-Path $root 'host.pid')
 Check-Exclusion 'Exported cleanup marker writer respects root mutation lock' {Write-HouseholdCleanupState $root 'task-host' 101} {Test-Path -LiteralPath (Join-Path $root 'household-cleanup-state.json')}
 Check-Exclusion 'Exported owner tracking retirement respects root mutation lock' {Complete-HouseholdOwnerTracking $root $fixtureOwner $true} {!(Test-Path -LiteralPath (Join-Path $root 'task-owner.json'))}
 $cfg=[pscustomobject]@{companionRoot=$root;tunnelExe=$exe};$tunnel=[pscustomobject]@{alias='fixture';tunnelId='fixture-only'}
 Check-Exclusion 'Exported native tunnel stop respects root mutation lock' {Invoke-TunnelNative $cfg $tunnel @('runtimes','stop','fixture','--json')} {$false}
 Check-Exclusion 'Exported tunnel connect respects root mutation lock' {Connect-TunnelRuntime $cfg $tunnel 'fixture-only-key'} {$false}
 $windows=New-WindowsTaskAdapter $definition
 Check-Exclusion 'Native adapter stop callback respects root mutation lock' {& $windows.RequestGracefulStop} {Test-Path -LiteralPath (Join-Path $root 'stop.flag')}
 $state=[pscustomobject]@{started=$false}
 $adapter=@{
  GetTask={ [pscustomobject]@{xml=$definition.Xml} }.GetNewClosure()
  GetStatus={ [pscustomobject]@{taskState='Ready';hostPresent=$false;listenerPresent=$false;tunnelPresent=$false;cleanupRequired=$false} }
  StartTask={$state.started=$true}.GetNewClosure()
 }
 Check-Exclusion 'Exported lifecycle Start respects root mutation lock' {Invoke-HouseholdLifecycle Start $definition $adapter} {$state.started}
 Check-Exclusion 'Native pinned Scheduler Start respects root mutation lock' {Start-HouseholdTaskPinned $definition} {
  $deadline=[DateTime]::UtcNow.AddSeconds(10)
  while(!(Test-Path -LiteralPath (Join-Path $root 'started.marker')) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 100}
  Test-Path -LiteralPath (Join-Path $root 'started.marker')
 }
} finally {
 [IO.File]::WriteAllText($release,'release')
 if($child){if(!$child.WaitForExit(15000)){throw 'holder retained; no force termination'};$child.Dispose()}
 if($registered){
  $deadline=[DateTime]::UtcNow.AddSeconds(15)
  while((Get-ScheduledTask -TaskName $definition.Name -TaskPath '\').State -eq 'Running'){
   if([DateTime]::UtcNow -ge $deadline){throw 'probe retained; no force termination'}
   Start-Sleep -Milliseconds 100
  }
  Unregister-HouseholdTaskPinned $definition
 }
 $resolved=[IO.Path]::GetFullPath($fixture)
 $allowed=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '.fixtures')).TrimEnd('\')+'\'
 if(!$resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'fixture cleanup escaped test root'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Output "RESULT: $passed PASS; $failed FAIL; same-session real two-process exclusion; no cross-session claim"
if($failed){exit 1}
