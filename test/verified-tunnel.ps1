$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\VerifiedTunnel.psm1') -Force -DisableNameChecking
$module=Get-Module VerifiedTunnel
$root=Join-Path $PSScriptRoot ('.fixtures\verified-tunnel-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$cfg=[pscustomobject]@{tunnelExe='C:\fixture\tunnel-client.exe'}
$tunnel=[pscustomobject]@{alias='fixture';tunnelId='fixture-registration'}
$path=Get-TunnelOwnerPath $root $tunnel
$passed=0
& $module {
 function script:Get-ConsoleProcessIdentity { param([int]$ProcessId) if($script:IdentityDenied){throw 'PROCESS_QUERY_DENIED'};if($null -ne $script:FixtureIdentity -and $ProcessId -eq $script:FixtureIdentity.pid){$script:FixtureIdentity} }
 function script:New-Object {
  param([string]$TypeName,$ArgumentList)
  if($TypeName -cne 'Codexless.TunnelLifetime'){throw 'Unexpected native constructor'}
  $lease=[pscustomobject]@{CreatedAt=$script:NativeCreatedAt;Executable='C:\fixture\tunnel-client.exe';exitReady=$false;disposed=$false;waits=[Collections.Generic.List[int]]::new()}
  $lease | Add-Member ScriptMethod WaitForExit {param([int]$milliseconds) $this.waits.Add($milliseconds);$this.exitReady}
  $lease | Add-Member ScriptMethod Dispose {$this.disposed=$true}
  $script:Leases.Add($lease);$lease
 }
}
function Reset-Fixture {
 if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}
 $script:status=[pscustomobject]@{alias='fixture';tunnel_id='fixture-registration';process_running=$true;process=[pscustomobject]@{pid=77;alias='fixture';tunnel_id='fixture-registration'}}
 & $module {param($sid) $script:IdentityDenied=$false;$script:NativeCreatedAt='2026-10-03T00:00:01.1234567Z';$script:Leases=[Collections.Generic.List[object]]::new();$script:FixtureIdentity=[pscustomobject]@{pid=77;createdAt='2026-10-03T00:00:01.1234560Z';userSid=$sid;executable='C:\fixture\tunnel-client.exe'}} $sid
}
function Record-Fixture {Record-OwnedTunnel $root $cfg $tunnel $status ([DateTime]'2026-10-03T00:00:00Z')}
function Stopped-Status {[pscustomobject]@{alias='fixture';tunnel_id='fixture-registration';process_running=$false}}
function Assert([bool]$Value){if(!$Value){throw 'Assertion failed'}}
function Reject([scriptblock]$Body,[string]$Code){$failed=$false;try{& $Body}catch{$failed=$_.Exception.Message -like ($Code+'*')};if(!$failed){throw ('Expected rejection '+$Code)}}
function Test([string]$Name,[scriptblock]$Body){Reset-Fixture;& $Body;$script:passed++;Write-Output "PASS $Name"}
Test 'Alive receipt captures exact native lifetime and acquires a held binding' {
 Record-Fixture
 $saved=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
 Assert ($saved.pid -eq 77 -and $saved.nativeCreatedAt -ceq '2026-10-03T00:00:01.1234567Z')
 $binding=Open-OwnedTunnelLifetime $root $cfg $tunnel $status
 Assert ($null -ne $binding -and !$binding.lease.disposed -and (Test-Path -LiteralPath $path))
 $binding.lease.Dispose()
}
Test 'Unavailable or malformed liveness never opens a binding' {
 foreach($bad in @($null,[pscustomobject]@{},[pscustomobject]@{process_running='false'},[pscustomobject]@{process_running=0})) {Reject {Open-OwnedTunnelLifetime $root $cfg $tunnel $bad} 'TUNNEL_STATUS_UNKNOWN'}
}
Test 'Missing or invalid nested PID never opens a binding' {
 foreach($bad in @($null,[pscustomobject]@{},[pscustomobject]@{pid='bad'},[pscustomobject]@{pid=0})) {$status.process=$bad;Reject {Open-OwnedTunnelLifetime $root $cfg $tunnel $status} 'TUNNEL_LIFETIME_UNKNOWN'}
}
Test 'Wrong top-level alias or registration fails while alive and stopped' {
 foreach($alive in @($true,$false)) {
  $status.process_running=$alive;$status.alias='wrong';Reject {Open-OwnedTunnelLifetime $root $cfg $tunnel $status} 'TUNNEL_REGISTRATION_MISMATCH'
  $status.alias='fixture';$status.tunnel_id='wrong';Reject {Open-OwnedTunnelLifetime $root $cfg $tunnel $status} 'TUNNEL_REGISTRATION_MISMATCH';$status.tunnel_id='fixture-registration'
 }
}
Test 'Stopped status without registration cannot retire an owned receipt' {
 Record-Fixture
 Reject {Open-OwnedTunnelLifetime $root $cfg $tunnel ([pscustomobject]@{process_running=$false})} 'TUNNEL_REGISTRATION_MISMATCH'
 Assert (Test-Path -LiteralPath $path)
}
Test 'Wrong nested alias or backend registration rejects a live runtime' {
 $status.process.alias='wrong';Reject {Open-OwnedTunnelLifetime $root $cfg $tunnel $status} 'TUNNEL_REGISTRATION_MISMATCH'
 $status.process.alias='fixture';$status.process.tunnel_id='wrong';Reject {Open-OwnedTunnelLifetime $root $cfg $tunnel $status} 'TUNNEL_REGISTRATION_MISMATCH'
}
Test 'Reused PID creation time rejects the live receipt' {
 Record-Fixture;& $module {$script:FixtureIdentity.createdAt='2026-10-03T00:01:01.1234560Z'}
 Reject {Open-OwnedTunnelLifetime $root $cfg $tunnel $status} 'TUNNEL_LIFETIME_MISMATCH'
 Assert (Test-Path -LiteralPath $path)
}
Test 'Mismatch in exact native lifetime disposes rejected handle and retains receipt' {
 Record-Fixture;& $module {$script:NativeCreatedAt='2026-10-03T00:00:01.1234568Z'}
 Reject {Open-OwnedTunnelLifetime $root $cfg $tunnel $status} 'TUNNEL_LIFETIME_MISMATCH'
 Assert ((& $module {$script:Leases[$script:Leases.Count-1].disposed}) -and (Test-Path -LiteralPath $path))
}
Test 'Stopped metadata cannot retire a still-live saved process' {
 Record-Fixture;Reject {Open-OwnedTunnelLifetime $root $cfg $tunnel (Stopped-Status)} 'TUNNEL_LIFETIME_UNPROVEN'
 Assert (Test-Path -LiteralPath $path)
}
Test 'Absent old process retires only its saved receipt without opening a lease' {
 Record-Fixture;& $module {$script:FixtureIdentity=$null}
 Assert ($null -eq (Open-OwnedTunnelLifetime $root $cfg $tunnel (Stopped-Status)))
 Assert (!(Test-Path -LiteralPath $path) -and (& $module {$script:Leases.Count}) -eq 1)
}
Test 'Later reused PID proves old lifetime gone without signaling the new process' {
 Record-Fixture;& $module {$script:FixtureIdentity.createdAt='2026-10-03T00:01:01.1234560Z'}
 Assert ($null -eq (Open-OwnedTunnelLifetime $root $cfg $tunnel (Stopped-Status)))
 Assert (!(Test-Path -LiteralPath $path) -and (& $module {$script:Leases.Count}) -eq 1)
}
Test 'Unavailable old process identity cannot retire its receipt' {
 Record-Fixture;& $module {$script:IdentityDenied=$true}
 Reject {Open-OwnedTunnelLifetime $root $cfg $tunnel (Stopped-Status)} 'PROCESS_QUERY_DENIED'
 Assert (Test-Path -LiteralPath $path)
}
Test 'Post-stop timeout retains receipt and exact lease for the caller' {
 Record-Fixture;$binding=Open-OwnedTunnelLifetime $root $cfg $tunnel $status
 Reject {Complete-OwnedTunnelStop $binding} 'TUNNEL_STOP_LIFETIME_REMAINS'
 Assert ((Test-Path -LiteralPath $path) -and !$binding.lease.disposed -and $binding.lease.waits.Contains(30000))
 $binding.lease.Dispose()
}
Test 'Confirmed exact process exit permits receipt retirement' {
 Record-Fixture;$binding=Open-OwnedTunnelLifetime $root $cfg $tunnel $status;$binding.lease.exitReady=$true
 Complete-OwnedTunnelStop $binding
 Assert (!(Test-Path -LiteralPath $path));$binding.lease.Dispose()
}
Test 'Changed receipt after stop is retained instead of removing another lifetime' {
 Record-Fixture;$binding=Open-OwnedTunnelLifetime $root $cfg $tunnel $status;$binding.lease.exitReady=$true
 $changed=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json;$changed.pid=88;$changed | ConvertTo-Json | Set-Content -LiteralPath $path
 Reject {Complete-OwnedTunnelStop $binding} 'TUNNEL_STOP_RECEIPT_CHANGED'
 Assert (Test-Path -LiteralPath $path);$binding.lease.Dispose()
}
Write-Output ("RESULT: {0}/{0} PASS; process identity and lifetime APIs mocked, workspace receipt I/O only" -f $passed)
