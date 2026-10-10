$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\WindowsTaskAdapter.psm1') -Force
$module=Get-Module WindowsTaskAdapter
$state=[pscustomobject]@{registered=0;started=0;status=0;recovery=0;failRecovery=$false}
& $module {
 param($s)
 $script:ClosureFixture=$s
 function script:Import-Module {param($Name,$ErrorAction)}
 function script:Get-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction) [pscustomobject]@{State='Ready'}}
 function script:Export-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction) '<fixture />'}
 function script:Register-HouseholdTaskCreateOnly {param($Definition) $script:ClosureFixture.registered++}
 function script:Start-HouseholdTaskPinned {param($Definition) $script:ClosureFixture.started++}
 function script:Get-HouseholdRuntimeState {param($Definition) $script:ClosureFixture.status++;'fixture-status'}
 function script:Invoke-WindowsPriorBootRecovery {
  param($Definition,[switch]$CheckOnly)
  if(!$CheckOnly){throw 'unexpected mutation'}
  $script:ClosureFixture.recovery++
  if($script:ClosureFixture.failRecovery){
   $failure=[InvalidOperationException]::new('private-provider-data')
   $failure.Data['RecoveryReasonCode']='RECOVERY_LISTENER_PRESENT'
   throw $failure
  }
 }
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
$state.failRecovery=$true
$detachedFailure=New-Module -ScriptBlock {
 param($a)
 if((& $a.CanRecoverPriorBoot)){throw 'failed proof accepted'}
 if((& $a.RecoveryFailureReason) -cne 'RECOVERY_LISTENER_PRESENT'){throw 'failure reason closure lost'}
} -ArgumentList $adapter
$state.failRecovery=$false
$detachedSuccess=New-Module -ScriptBlock {
 param($a)
 if(!(& $a.CanRecoverPriorBoot) -or $null -ne (& $a.RecoveryFailureReason)){throw 'old failure reason survived a successful proof'}
} -ArgumentList $adapter
'RESULT: 7/7 PASS; captured native adapter helpers execute outside caller import scope; no native mutation'
