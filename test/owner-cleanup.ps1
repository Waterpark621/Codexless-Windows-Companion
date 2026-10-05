$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\UserSessionTask.psm1') -Force
$fixture=Join-Path $PSScriptRoot ('.fixtures\owner-cleanup-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$results=[Collections.Generic.List[string]]::new()
function Assert-True([bool]$Value){if(!$Value){throw 'assertion failed'}}
function Assert-Throws([scriptblock]$Body,[string]$Code){try{& $Body | Out-Null}catch{if($_.Exception.Message.Contains($Code)){return};throw};throw "Expected $Code"}
function Test([string]$Name,[scriptblock]$Body){& $Body;$results.Add($Name);Write-Output "PASS $Name"}
$identity=[pscustomobject]@{pid=101;createdAt='2026-10-03T00:00:00.0000000Z';userSid='S-1-5-21-111-222-333-1001'}
function New-OwnerFixture {
 $folder=Join-Path $fixture ([Guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $folder | Out-Null
 $identity | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $folder 'task-owner.json') -Encoding utf8
 '101' | Set-Content -LiteralPath (Join-Path $folder 'host.pid') -Encoding ascii
 return $folder
}
Test 'Failed cleanup preserves exact owner and host tracking' {
 $folder=New-OwnerFixture
 Complete-HouseholdOwnerTracking $folder $identity $false
 Assert-True ((Test-Path -LiteralPath (Join-Path $folder 'task-owner.json')) -and (Test-Path -LiteralPath (Join-Path $folder 'host.pid')))
}
Test 'Successful cleanup removes only matching owner tracking' {
 $folder=New-OwnerFixture;'keep' | Set-Content -LiteralPath (Join-Path $folder 'unrelated.txt')
 Complete-HouseholdOwnerTracking $folder $identity $true
 Assert-True (!(Test-Path -LiteralPath (Join-Path $folder 'task-owner.json')) -and !(Test-Path -LiteralPath (Join-Path $folder 'host.pid')) -and (Test-Path -LiteralPath (Join-Path $folder 'unrelated.txt')))
}
Test 'Pending wrapper evidence rejects cleanup completion without deleting owner' {
 foreach($name in @('codexless-console-owner.json','codexless.pid')){
  $folder=New-OwnerFixture;'pending' | Set-Content -LiteralPath (Join-Path $folder $name)
  Assert-Throws {Complete-HouseholdOwnerTracking $folder $identity $true} 'HOUSEHOLD_CLEANUP_INCOMPLETE'
  Assert-True (Test-Path -LiteralPath (Join-Path $folder 'task-owner.json'))
 }
}
Test 'Reused PID and foreign identity cannot remove saved ownership' {
 foreach($field in @('pid','createdAt','userSid')){
  $folder=New-OwnerFixture;$foreign=$identity.PSObject.Copy();$foreign.$field=if($field -eq 'pid'){102}else{'unrelated'}
  Assert-Throws {Complete-HouseholdOwnerTracking $folder $foreign $true} 'HOUSEHOLD_CLEANUP_OWNER_INVALID'
  Assert-True ((Test-Path -LiteralPath (Join-Path $folder 'task-owner.json')) -and (Test-Path -LiteralPath (Join-Path $folder 'host.pid')))
 }
}
Test 'Changed host PID retains both owner records' {
 $folder=New-OwnerFixture;'102' | Set-Content -LiteralPath (Join-Path $folder 'host.pid')
 Assert-Throws {Complete-HouseholdOwnerTracking $folder $identity $true} 'HOUSEHOLD_CLEANUP_OWNER_INVALID'
 Assert-True ((Test-Path -LiteralPath (Join-Path $folder 'task-owner.json')) -and (Test-Path -LiteralPath (Join-Path $folder 'host.pid')))
}
Test 'Sanitized degraded marker blocks removal even if all processes appear stopped' {
 $folder=New-OwnerFixture
 Write-HouseholdCleanupState $folder 'console-stop' 101
 $saved=Get-HouseholdCleanupState $folder
 Assert-True ($saved.reasonCode -ceq 'HOUSEHOLD_VERIFIED_RECOVERY_REQUIRED')
 Assert-Throws {Complete-HouseholdOwnerTracking $folder $identity $true} 'HOUSEHOLD_CLEANUP_DEGRADED'
 $raw=Get-Content -LiteralPath (Join-Path $folder 'household-cleanup-state.json') -Raw
 Assert-True ($raw -notmatch 'commandLine|userSid|profile|key|exception')
 Assert-True (Test-Path -LiteralPath (Join-Path $folder 'task-owner.json'))
}
Test 'Existing marker keeps its first failure evidence' {
 $folder=New-OwnerFixture;Write-HouseholdCleanupState $folder 'tunnel-stop' 101
 $before=Get-Content -LiteralPath (Join-Path $folder 'household-cleanup-state.json') -Raw
 Write-HouseholdCleanupState $folder 'task-host' 102
 Assert-True ($before -ceq (Get-Content -LiteralPath (Join-Path $folder 'household-cleanup-state.json') -Raw))
}
Test 'Malformed marker remains a sanitized recovery fence' {
 $folder=New-OwnerFixture;'{"state":"foreign-private-value"}' | Set-Content -LiteralPath (Join-Path $folder 'household-cleanup-state.json')
 $saved=Get-HouseholdCleanupState $folder
 Assert-True ($saved.reasonCode -ceq 'HOUSEHOLD_CLEANUP_STATE_INVALID' -and (ConvertTo-Json $saved) -notmatch 'foreign-private-value')
 Assert-Throws {Complete-HouseholdOwnerTracking $folder $identity $true} 'HOUSEHOLD_CLEANUP_DEGRADED'
}
Write-Output ("RESULT: {0}/{0} PASS; workspace receipt I/O only; no task/process/runtime actions" -f $results.Count)
