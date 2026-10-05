$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\VerifiedTunnel.psm1') -Force -DisableNameChecking
$module=Get-Module VerifiedTunnel
$root=Join-Path $PSScriptRoot ('.fixtures\managed-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root|Out-Null
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$passed=0
& $module {
 function script:Get-TunnelGenerationProof {param($Config,$Tunnel) $script:Context}
 function script:Get-TunnelRuntimeContext {param($Config,$Tunnel) $script:Context}
 function script:Assert-TunnelExecutable {param($Config) 'fcc85a69ec0ad82518e4f8964f60c45e31787957782a0fc9c1b0c44e82d61b9b'}
 function script:Get-CimInstance {param($ClassName,$Filter,$OperationTimeoutSec,$ErrorAction) if($script:Foreign){[pscustomobject]@{ProcessId=88}}}
 function script:Get-ConsoleProcessIdentity {param($ProcessId) if($ProcessId -eq 100){return $script:Owner};if($ProcessId -eq 77){return $script:Child}}
 function script:Get-TunnelStatus {param($Config,$Tunnel) $script:Status}
 function script:Connect-TunnelRuntime {
  param($Config,$Tunnel,$PlainKey)
  $script:ConnectCalls++
  if($PlainKey -cne 'fixture-key'){throw 'key contract'}
  if($script:ConnectFailure){throw $script:ConnectFailure}
  [pscustomobject]@{Ok=$true;ProcessId=900;CreatedAt='2026-10-03T00:00:00.0000000Z';ExitedAt='2026-10-03T00:00:02.0000000Z'}
 }
 function script:New-Object {param($TypeName,$ArgumentList)
  if($TypeName -cne 'Codexless.TunnelLifetime'){throw 'unexpected native construction'}
  $lease=[pscustomobject]@{NativeHandle=[IntPtr]1;CreatedAt='2026-10-03T00:00:01.1234567Z';Executable='C:\fixture\tunnel-client.exe';Disposed=$false;Exited=$false}
  $lease|Add-Member ScriptMethod WaitForExit {param($ms) $this.Exited}
  $lease|Add-Member ScriptMethod Dispose {$this.Disposed=$true}
  $script:Lease=$lease;$lease
 }
 function script:Invoke-TunnelNative {
  param($Config,$Tunnel,$Arguments,$TimeoutMs,$PlainKey,$StateRoot,$GuardHandle)
  $script:StopCalls++
  if($GuardHandle -ne [IntPtr]1 -or $TimeoutMs -ne 5000 -or ($Arguments -join '|') -cne 'runtimes|stop|fixture|--json' -or $PlainKey){throw 'stop contract'}
  $processes=Get-Content -LiteralPath (Join-Path $StateRoot 'processes.yaml') -Raw|ConvertFrom-Json
  if($processes.fixture.pid -ne 77 -or $processes.fixture.mode -cne 'process'){throw 'stop snapshot contract'}
  if($script:ChangeReceipt){[IO.File]::AppendAllText($script:Receipt,' ')}
  $script:Lease.Exited=$script:StopExit
  [pscustomobject]@{GuardTransferred=$true;Ok=$script:StopOk;Stdout=$script:StopOutput;Code='NATIVE_TIMEOUT'}
 }
}
function New-Fixture {
 $folder=Join-Path $root ([Guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $folder|Out-Null
 $script:cfg=[pscustomobject]@{companionRoot=$folder;tunnelExe='C:\fixture\tunnel-client.exe'}
 $script:tunnel=[pscustomobject]@{alias='fixture';tunnelId='fixture-registration'}
 $script:receipt=Get-TunnelOwnerPath $folder $tunnel
 & $module {param($folder,$sid,$receipt)
  $state=Join-Path $folder 'native';$profile=Join-Path $state 'profiles'
  $script:Owner=[pscustomobject]@{pid=100;createdAt='2026-10-03T00:00:00.0000000Z';userSid=$sid}
  $script:Context=[pscustomobject]@{owner=$script:Owner;stateRoot=$state;profileRoot=$profile;intentPath=(Join-Path $state 'connect-intent.json');generationSha256=('a'*64)}
  $script:Child=[pscustomobject]@{pid=77;parentPid=900;createdAt='2026-10-03T00:00:01.1234560Z';userSid=$sid;executable='C:\fixture\tunnel-client.exe';commandLine=('"C:\fixture\tunnel-client.exe" run --profile-dir "'+$profile+'" --profile fixture')}
  $script:Status=[pscustomobject]@{alias='fixture';tunnel_id='fixture-registration';process_running=$true;healthy=$true;ready=$true;process=[pscustomobject]@{alias='fixture';tunnel_id='fixture-registration';pid=77;mode='process'}}
  $script:ConnectCalls=0;$script:StopCalls=0;$script:Foreign=$false;$script:ConnectFailure='';$script:ChangeReceipt=$false;$script:StopOk=$true;$script:StopExit=$true;$script:Receipt=$receipt
  $script:StopOutput='{"alias":"fixture","tunnel_id":"fixture-registration","stopped":true}'
 } $folder $sid $receipt
}
function Assert([bool]$v){if(!$v){throw 'assertion failed'}}
function Refuses([scriptblock]$body,[string]$code){$failed=$false;try{& $body|Out-Null}catch{$failed=$_.Exception.Message -like ($code+'*')};Assert $failed}
function Test([string]$name,[scriptblock]$body){New-Fixture;& $body;$script:passed++;Write-Output "PASS $name"}
function Start-Fixture {Start-OwnedTunnel $cfg.companionRoot $cfg $tunnel 'fixture-key'}
function Stop-Fixture {Stop-OwnedTunnel $cfg.companionRoot $cfg $tunnel}
Test 'Fresh exact generation connects once and writes receipt after all proofs' {Assert (Start-Fixture);Assert (Test-Path -LiteralPath $receipt);Assert (& $module {$script:ConnectCalls -eq 1})}
Test 'Same generation never connects a replacement' {Start-Fixture|Out-Null;Refuses {Start-Fixture} 'TUNNEL_CONNECT_GENERATION_FENCED';Assert (& $module {$script:ConnectCalls -eq 1})}
Test 'Foreign full client blocks before namespace mutation' {& $module {$script:Foreign=$true};Refuses {Start-Fixture} 'TUNNEL_FOREIGN_PROCESS_PRESENT';Assert (!(Test-Path -LiteralPath $receipt));Assert (& $module {!(Test-Path -LiteralPath $script:Context.stateRoot)})}
foreach($failure in @('TUNNEL_CONNECT_UNCERTAIN','TUNNEL_SECURITY_POLICY_UNSUPPORTED')){Test "$failure stays fenced and never claims ownership" {& $module {param($f) $script:ConnectFailure=$f} $failure;Refuses {Start-Fixture} $failure;Assert (!(Test-Path -LiteralPath $receipt));Assert (& $module {Test-Path -LiteralPath $script:Context.intentPath});Refuses {Start-Fixture} 'TUNNEL_CONNECT_GENERATION_FENCED'}}
Test 'Unknown post-connect status retains fence without ownership' {& $module {$script:Status=$null};Refuses {Start-Fixture} 'TUNNEL_STATUS_UNKNOWN';Assert (!(Test-Path -LiteralPath $receipt));Refuses {Start-Fixture} 'TUNNEL_CONNECT_GENERATION_FENCED'}
Test 'Healthy but foreign managed child is rejected after connect' {& $module {$script:Child.parentPid=901};Refuses {Start-Fixture} 'TUNNEL_LAUNCH_PROVENANCE_INVALID';Assert (!(Test-Path -LiteralPath $receipt))}
Test 'Unready managed child is not receipted' {& $module {$script:Status.ready=$false};Refuses {Start-Fixture} 'TUNNEL_LAUNCH_PROVENANCE_INVALID';Assert (!(Test-Path -LiteralPath $receipt))}
Test 'Official bounded stop uses exact isolated PID snapshot and retires receipt only after exit' {Start-Fixture|Out-Null;Stop-Fixture;Assert (!(Test-Path -LiteralPath $receipt));Assert (& $module {$script:StopCalls -eq 1 -and $script:Lease.Disposed})}
Test 'Native stop timeout retains unchanged evidence' {Start-Fixture|Out-Null;$before=[IO.File]::ReadAllText($receipt);& $module {$script:StopOk=$false};Refuses {Stop-Fixture} 'TUNNEL_STOP_NATIVE_UNCERTAIN';Assert ([IO.File]::ReadAllText($receipt) -ceq $before);Assert (& $module {$script:Lease.Disposed})}
Test 'Successful CLI with still-alive exact process retains receipt' {Start-Fixture|Out-Null;& $module {$script:StopExit=$false};Refuses {Stop-Fixture} 'TUNNEL_STOP_LIFETIME_REMAINS';Assert (Test-Path -LiteralPath $receipt)}
foreach($output in @('{}','{"alias":"foreign","tunnel_id":"fixture-registration","stopped":true}','{"alias":"fixture","tunnel_id":"fixture-registration","stopped":false}')){Test 'Ambiguous native stop output never retires receipt' {Start-Fixture|Out-Null;& $module {param($s) $script:StopOutput=$s} $output;$failed=$false;try{Stop-Fixture}catch{$failed=$true};Assert $failed;Assert (Test-Path -LiteralPath $receipt)}}
Test 'Any receipt-byte change across official stop remains fenced' {Start-Fixture|Out-Null;& $module {$script:ChangeReceipt=$true};Refuses {Stop-Fixture} 'TUNNEL_STOP_RECEIPT_CHANGED';Assert (Test-Path -LiteralPath $receipt)}
Test 'Generation namespace remains fenced after successful stop' {Start-Fixture|Out-Null;Stop-Fixture;Refuses {Start-Fixture} 'TUNNEL_CONNECT_GENERATION_FENCED'}
Write-Output ("RESULT: {0}/{0} PASS; managed CLI/native lifetime adapters mocked; disposable receipt and stop snapshot I/O only" -f $passed)
