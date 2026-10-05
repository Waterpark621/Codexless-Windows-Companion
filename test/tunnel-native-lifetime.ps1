param([string]$QualifiedTunnelExe)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\VerifiedTunnel.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '..\BoundedNative.psm1') -Force
$module=Get-Module VerifiedTunnel
$root=Join-Path $PSScriptRoot ('.fixtures\native-lifetime-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root|Out-Null
$node=(Get-Command node.exe).Source
$hash=(Get-FileHash -LiteralPath $node -Algorithm SHA256).Hash.ToLowerInvariant()
$profile=Join-Path $root 'profiles'
$quit=Join-Path $profile 'exit.flag';New-Item -ItemType Directory -Path $profile|Out-Null
[IO.File]::WriteAllText((Join-Path $root 'run'),@'
const fs=require('node:fs'),path=require('node:path');
const profile=process.argv[3];
const timer=setInterval(()=>{if(fs.existsSync(path.join(profile,'exit.flag'))){clearInterval(timer);process.exit(0)}},25);
setTimeout(()=>process.exit(0),12000);
'@)
$parent=Join-Path $root 'parent.mjs'
[IO.File]::WriteAllText($parent,@'
import {spawn} from 'node:child_process';
const child=spawn(process.execPath,['run','--profile-dir',process.argv[2],'--profile','fixture'],{stdio:'ignore',detached:true});
child.unref();process.stdout.write(JSON.stringify({pid:child.pid}));setTimeout(()=>process.exit(0),200);
'@)
$passed=0;$binding=$null;$childId=0;$guardId=0
try {
 $launch=Invoke-BoundedNative $node $hash @($parent,$profile) $root
 if(!$launch.Ok){throw 'native launch fixture failed'}
 $childId=[int](($launch.Stdout|ConvertFrom-Json).pid);$launch.Stdout=$null
 # Only the generation and pin inputs are synthetic; real CIM/owner/native
 # process handles and Windows argv parsing exercise the production proofs.
 & $module {param($root,$profile,$hash)
  $script:FixtureContext=[pscustomobject]@{stateRoot=$root;profileRoot=$profile;generationSha256=('a'*64)};$script:FixtureHash=$hash
  function script:Get-TunnelGenerationProof {param($Config,$Tunnel) $script:FixtureContext}
  function script:Assert-TunnelExecutable {param($Config) $script:FixtureHash}
 } $root $profile $hash
 $cfg=[pscustomobject]@{tunnelExe=$node};$tunnel=[pscustomobject]@{alias='fixture';tunnelId='fixture-registration'}
 $status=[pscustomobject]@{alias='fixture';tunnel_id='fixture-registration';process_running=$true;healthy=$true;ready=$true;process=[pscustomobject]@{alias='fixture';tunnel_id='fixture-registration';pid=$childId;mode='process'}}
 Record-OwnedTunnel $root $cfg $tunnel $status $launch
 $binding=Open-OwnedTunnelLifetime $root $cfg $tunnel $status
 if($binding.lease.WaitForExit(0)){throw 'native child ended before proof'}
 $passed++;Write-Output 'PASS real Windows parent interval, argv, SID and held native lifetime proof'
 $guardScript=Join-Path $root 'guard.mjs'
 [IO.File]::WriteAllText($guardScript,"setTimeout(()=>process.exit(0),2200);")
 $guard=Invoke-BoundedNative $node $hash @($guardScript) $root -TimeoutMs 500 -GuardHandle $binding.lease.NativeHandle
 $guardId=$guard.ProcessId
 if(!$guard.GuardTransferred -or !$guard.TimedOut -or !$guard.LifetimeMayRemain){throw 'guarded timeout proof failed'}
 $passed++;Write-Output 'PASS bounded suspended child receives native guard before execution and retains it on timeout'
 New-Item -ItemType File -Path $quit|Out-Null
 Complete-OwnedTunnelStop $binding
 if(Test-Path -LiteralPath $binding.path){throw 'receipt retirement failed'}
 $passed++;Write-Output 'PASS exact cooperative disposable child exit and unchanged receipt retirement'
 $nativeTime=$binding.lease.CreatedAt;$binding.lease.Dispose();$binding=$null
 $retained=[Codexless.TunnelLifetime]::QueryRetainedCreationTime($childId)
 if($retained -cne $nativeTime){throw 'transferred guard did not preserve exact retired PID'};$passed++;Write-Output 'PASS remote native guard preserves retired process object after caller closes its lease'
}finally {
 if(!(Test-Path -LiteralPath $quit)){New-Item -ItemType File -Path $quit|Out-Null}
 if($binding){$binding.lease.Dispose()}
 if($guardId){$p=Get-Process -Id $guardId -ErrorAction SilentlyContinue;if($p){try{if(!$p.WaitForExit(10000)){throw 'guard fixture did not exit'}}finally{$p.Dispose()}}}
 if($childId){$p=Get-Process -Id $childId -ErrorAction SilentlyContinue;if($p){try{if(!$p.WaitForExit(15000)){throw 'fixture did not exit'}}finally{$p.Dispose()}}}
}
if($QualifiedTunnelExe){
 $pin='fcc85a69ec0ad82518e4f8964f60c45e31787957782a0fc9c1b0c44e82d61b9b'
 $environment=@{TUNNEL_CLIENT_STATE_DIR=(Join-Path $root 'official-state');TUNNEL_CLIENT_PROFILE_DIR=(Join-Path $root 'official-profiles')}
 $version=Invoke-BoundedNative $QualifiedTunnelExe $pin @('--version') $root -Environment $environment
 if(!$version.Ok -or $version.Stdout -notmatch '0\.0\.14'){throw 'approved client unsupported'}
 $passed++;Write-Output 'PASS independently acquired pinned official full client version execution'
 New-Item -ItemType Directory -Path $environment.TUNNEL_CLIENT_STATE_DIR|Out-Null
 [IO.File]::WriteAllText((Join-Path $environment.TUNNEL_CLIENT_STATE_DIR 'aliases.yaml'),'{"fixture":{"alias":"fixture","tunnel_id":"tunnel_fixture"}}')
 [IO.File]::WriteAllText((Join-Path $environment.TUNNEL_CLIENT_STATE_DIR 'processes.yaml'),'{"fixture":{"alias":"fixture","tunnel_id":"tunnel_fixture","mode":"stopped","pid":0}}')
 $status=Invoke-BoundedNative $QualifiedTunnelExe $pin @('runtimes','status','fixture','--json') $root -Environment $environment
 if(!$status.Ok){throw 'official isolated status failed'}
 $parsed=$status.Stdout|ConvertFrom-Json
 if($parsed.alias -cne 'fixture' -or $parsed.tunnel_id -cne 'tunnel_fixture' -or $parsed.process_running -isnot [bool] -or $parsed.process_running){throw 'official status contract mismatch'}
 $passed++;Write-Output 'PASS official bounded JSON status in isolated synthetic state without keys'
}
Write-Output ("RESULT: {0}/{0} PASS; real disposable child lifetime; optional pinned client read-only status; no backend/connect/live-state actions" -f $passed)
