$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\PrivateConsole.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\VerifiedTunnel.psm1') -Force -DisableNameChecking
$root=Join-Path $PSScriptRoot ('fixtures-tunnel-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$node=(Get-Command node.exe -ErrorAction Stop).Source
$scriptPath=Join-Path $root 'fixture.mjs'
@'
import fs from 'node:fs';
fs.writeFileSync(process.argv[2],JSON.stringify({pid:process.pid}));
const timer=setTimeout(()=>process.exit(3),45000);
process.once('SIGINT',()=>{clearTimeout(timer);process.exit(0);});
'@ | Set-Content -LiteralPath $scriptPath -Encoding utf8
$ready=Join-Path $root 'ready.json'
$console=Join-Path $root 'console.json'
$after=[DateTime]::UtcNow
$receipt=Start-PrivateConsoleProcess $node ('"'+$scriptPath+'" "'+$ready+'"') $root $console
$deadline=[DateTime]::UtcNow.AddSeconds(10)
while(!(Test-Path -LiteralPath $ready)){if([DateTime]::UtcNow -ge $deadline){throw 'FIXTURE_TIMEOUT'};Start-Sleep -Milliseconds 100}
$cfg=[pscustomobject]@{tunnelExe=$node}
$tunnel=[pscustomobject]@{alias='benign-fixture';tunnelId='fixture-registration'}
$status=[pscustomobject]@{alias=$tunnel.alias;process_running=$true;tunnel_id=$tunnel.tunnelId;process=[pscustomobject]@{pid=$receipt.pid;tunnel_id=$tunnel.tunnelId;alias=$tunnel.alias}}
$binding=$null
try{
 Record-OwnedTunnel $root $cfg $tunnel $status $after
 $saved=Get-Content -LiteralPath (Get-TunnelOwnerPath $root $tunnel) -Raw | ConvertFrom-Json
 if(!$saved.nativeCreatedAt -or $saved.pid -ne $receipt.pid){throw 'RECEIPT_INVALID'}
 $binding=Open-OwnedTunnelLifetime $root $cfg $tunnel $status
 if($binding.lease.WaitForExit(0)){throw 'LEASE_NOT_ALIVE'}
 'PASS exact native process lifetime acquired and held'
 $deadStatus=[pscustomobject]@{alias=$tunnel.alias;tunnel_id=$tunnel.tunnelId;process_running=$false}
 try{Open-OwnedTunnelLifetime $root $cfg $tunnel $deadStatus;throw 'EXPECTED_FAIL_CLOSED'}catch{if($_.Exception.Message -notlike 'TUNNEL_LIFETIME_UNPROVEN*'){throw}}
 'PASS stopped-status cannot retire an actually alive owned process'
 Request-PrivateConsoleStop $console (Join-Path $PSScriptRoot '..\Signal-PrivateConsole.ps1') 15
 Complete-OwnedTunnelStop $binding
 if(Test-Path -LiteralPath (Get-TunnelOwnerPath $root $tunnel)){throw 'RECEIPT_REMAINS'}
 'PASS held lifetime signals exit and only matching receipt is removed'
 'RESULT: 3/3 PASS; benign Node fixture only'
}finally{
 if($null -ne $binding){$binding.lease.Dispose()}
 if(Test-Path -LiteralPath $console){Request-PrivateConsoleStop $console (Join-Path $PSScriptRoot '..\Signal-PrivateConsole.ps1') 15}
}
