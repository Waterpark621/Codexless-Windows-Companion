$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\CompanionRuntime.psm1') -Force
$module=Get-Module CompanionRuntime;$passed=0
$cfg=[pscustomobject]@{companionRoot='C:\fixture\root';tunnelExe='C:\fixture\tunnel-client.exe'}
$tunnel=[pscustomobject]@{alias='fixture';tunnelId='fixture-registration'}
& $module {
 function script:Get-TunnelRuntimeContext {param($Config,$Tunnel) [pscustomobject]@{stateRoot='C:\fixture\state';profileRoot='C:\fixture\profiles'}}
 function script:Invoke-BoundedNative {param($Executable,$ExpectedSha256,$Arguments,$WorkingDirectory,$TimeoutMs,$OutputLimit,$Environment)
  if($Executable -cne 'C:\fixture\tunnel-client.exe' -or $ExpectedSha256 -cne 'fcc85a69ec0ad82518e4f8964f60c45e31787957782a0fc9c1b0c44e82d61b9b' -or $TimeoutMs -ne 5000 -or $OutputLimit -ne 65536 -or ($Arguments -join '|') -cne 'runtimes|status|fixture|--json' -or $Environment.ContainsKey('CONTROL_PLANE_API_KEY') -or $Environment.TUNNEL_CLIENT_STATE_DIR -cne 'C:\fixture\state' -or $Environment.TUNNEL_CLIENT_PROFILE_DIR -cne 'C:\fixture\profiles'){throw 'bounded status contract'}
  $script:Calls++;$script:NativeResult
 }
}
function Assert([bool]$v){if(!$v){throw 'assertion failed'}}
function Test([string]$name,[scriptblock]$body){& $module {$script:Calls=0;$script:NativeResult=[pscustomobject]@{Ok=$true;Stdout='{"alias":"fixture","tunnel_id":"fixture-registration","process_running":true,"healthy":true,"ready":true}';Code='NATIVE_OK'}};& $body;$script:passed++;Write-Output "PASS $name"}
Test 'Successful exact bounded status parses and readiness requires healthy runtime' {$s=Get-TunnelStatus $cfg $tunnel;Assert ($s.alias -ceq 'fixture' -and $s.process_running);Assert (Test-TunnelReady $cfg $tunnel);Assert (& $module {$script:Calls -eq 2})}
foreach($code in @('NATIVE_TIMEOUT','NATIVE_OUTPUT_LIMIT','NATIVE_EXECUTABLE_MISMATCH','NATIVE_EXIT_FAILED','NATIVE_SECURITY_POLICY_UNSUPPORTED')){Test "Failed $code stdout is never parsed" {& $module {param($c) $script:NativeResult.Ok=$false;$script:NativeResult.Code=$c} $code;Assert ($null -eq (Get-TunnelStatus $cfg $tunnel));Assert (!(Test-TunnelReady $cfg $tunnel))}}
foreach($json in @('{','{}','{"alias":"foreign","tunnel_id":"fixture-registration","process_running":true}','{"alias":"fixture","tunnel_id":"foreign","process_running":true}','{"alias":"fixture","tunnel_id":"fixture-registration","process_running":"true"}')){Test 'Malformed or wrong identity bounded stdout never authorizes readiness' {& $module {param($s) $script:NativeResult.Stdout=$s} $json;Assert ($null -eq (Get-TunnelStatus $cfg $tunnel))}}
Test 'Ready but unhealthy status fails readiness' {& $module {$script:NativeResult.Stdout='{"alias":"fixture","tunnel_id":"fixture-registration","process_running":true,"healthy":false,"ready":true}'};Assert (!(Test-TunnelReady $cfg $tunnel))}
Write-Output ("RESULT: {0}/{0} PASS; bounded native adapter mocked; no native or tunnel actions" -f $passed)
