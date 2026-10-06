$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\WindowsTaskAdapter.psm1') -Force
$module=Get-Module WindowsTaskAdapter
$state=[pscustomobject]@{registered=0;started=0;status=0;recovery=0}
& $module {
 param($s)
 $script:ClosureFixture=$s
 function script:Import-Module {param($Name,$ErrorAction)}
 function script:Get-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction) [pscustomobject]@{State='Ready'}}
 function script:Export-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction) '<fixture />'}
 function script:Register-HouseholdTaskCreateOnly {param($Definition) $script:ClosureFixture.registered++}
 function script:Start-HouseholdTaskPinned {param($Definition) $script:ClosureFixture.started++}
 function script:Get-HouseholdRuntimeState {param($Definition) $script:ClosureFixture.status++;'fixture-status'}
 function script:Invoke-WindowsPriorBootRecovery {param($Definition,[switch]$CheckOnly) if(!$CheckOnly){throw 'unexpected mutation'};$script:ClosureFixture.recovery++}
} $state
$adapter=New-WindowsTaskAdapter ([pscustomobject]@{Name='Codexless-Closure-Fixture';LauncherDirectory='C:\fixture'})
# Execute from a separate dynamic module with no imports of the helper commands.
$detached=New-Module -ScriptBlock {
 param($a)
 if((& $a.GetTask).xml -cne '<fixture />'){throw 'task closure failed'}
 & $a.RegisterTask ([pscustomobject]@{})
 & $a.StartTask
 if((& $a.GetStatus) -cne 'fixture-status'){throw 'status closure failed'}
 if(!(& $a.CanRecoverPriorBoot)){throw 'read-only recovery closure failed'}
} -ArgumentList $adapter
if($state.registered -ne 1 -or $state.started -ne 1 -or $state.status -ne 1 -or $state.recovery -ne 1){throw 'closure helper dispatch failed'}
'RESULT: 5/5 PASS; captured native adapter helpers execute outside caller import scope; no native mutation'
