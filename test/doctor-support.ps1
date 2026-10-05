$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\DoctorSupport.psm1') -Force
$module=Get-Module DoctorSupport
$root=Join-Path $PSScriptRoot ('.fixtures\doctor-support-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $root|Out-Null
foreach($f in @('settings.json','task-owner.json','codexless-console-owner.json')){'{}'|Set-Content -LiteralPath (Join-Path $root $f) -Encoding ascii}
'101'|Set-Content -LiteralPath (Join-Path $root 'host.pid') -Encoding ascii
'202'|Set-Content -LiteralPath (Join-Path $root 'codexless.pid') -Encoding ascii

$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$psExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$cfg=[pscustomobject]@{
  port=17690
  nodeExe='fixture-node.exe'
  tunnels=@([pscustomobject]@{alias='fixture';tunnelId='fixture-id'})
}
$script:passed=0
function Assert([bool]$v){if(!$v){throw 'assertion failed'}}
function Test([string]$name,[scriptblock]$body){& $body;$script:passed++;Write-Output ('PASS '+$name)}

& $module {
  $script:listenerOk=$true
  $script:wrapperParent=101
  $script:tunnelOwned=$true
  $script:tunnelStatus=[pscustomobject]@{process_running=$true;ready=$true}
  $script:browserResult=[pscustomobject]@{exitCode=0;output='{"ok":true,"browserStatus":"ok","chromeSkill":"ok","nodeRepl":"ok","supportedBackendCount":2,"selectionRequired":true}'}
  function script:Test-HouseholdOwnerIdentity { param($Receipt,$Process,$Definition) $null -ne $Process -and $Process.pid -eq 101 }
  function script:Test-PrivateConsoleReceipt { param($Receipt,$Identity,$CurrentUserSid) $null -ne $Identity -and $Identity.pid -eq 202 }
  function script:Test-PrivateConsoleListener { param($ReceiptPath,$Port) $script:listenerOk }
  function script:Get-ConsoleProcessIdentity {
    param([int]$ProcessId)
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $psExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if($ProcessId -eq 101){return [pscustomobject]@{pid=101;parentPid=50;userSid=$sid;executable=$psExe;commandLine='host';createdAt='2026-10-05T00:00:00.0000000Z'}}
    if($ProcessId -eq 202){return [pscustomobject]@{pid=202;parentPid=$script:wrapperParent;userSid=$sid;executable=$psExe;commandLine='wrapper';createdAt='2026-10-05T00:00:01.0000000Z'}}
    $null
  }
  function script:Get-TunnelStatus { param($Config,$Tunnel) $script:tunnelStatus }
  function script:Test-OwnedTunnel { param($InstallDirectory,$Config,$Tunnel,$Status) $script:tunnelOwned }
  function script:Invoke-BrowserProbeProcess { param($Config,$InstallDirectory) $script:browserResult }
}

Test 'Listener snapshot binds wrapper receipt root to verified household host' {
  $snap=Get-DoctorListenerOwnershipSnapshot $root $cfg
  Assert ($null -ne $snap -and $snap.hostPid -eq 101 -and $snap.wrapperPid -eq 202)
  & $module {$script:wrapperParent=999}
  Assert ($null -eq (Get-DoctorListenerOwnershipSnapshot $root $cfg))
  & $module {$script:wrapperParent=101}
}
Test 'Missing wrapper evidence fails closed' {
  Remove-Item -LiteralPath (Join-Path $root 'codexless.pid') -Force
  Assert ($null -eq (Get-DoctorListenerOwnershipSnapshot $root $cfg))
  '202'|Set-Content -LiteralPath (Join-Path $root 'codexless.pid') -Encoding ascii
}
Test 'Ownership snapshots must remain exact across observations' {
  $a=[pscustomobject]@{hostPid=101;hostCreatedAt='a';wrapperPid=202;wrapperCreatedAt='b';ownerSid='s'}
  $b=[pscustomobject]@{hostPid=101;hostCreatedAt='a';wrapperPid=202;wrapperCreatedAt='b';ownerSid='s'}
  Assert (Test-DoctorOwnershipSnapshotEqual $a $b)
  $b.wrapperCreatedAt='c'
  Assert (!(Test-DoctorOwnershipSnapshotEqual $a $b))
}
Test 'Tunnel acceptance requires running ready exact receipt ownership' {
  $r=Get-DoctorTunnelAcceptance $root $cfg
  Assert ($r.state -ceq 'PASS')
  & $module {$script:tunnelOwned=$false}
  $r=Get-DoctorTunnelAcceptance $root $cfg
  Assert ($r.state -ceq 'FAIL')
  & $module {$script:tunnelOwned=$true}
}
Test 'Tunnel disabled is a nonblocking SKIP' {
  $r=Get-DoctorTunnelAcceptance $root ([pscustomobject]@{tunnels=@()})
  Assert ($r.state -ceq 'SKIP')
}
Test 'Browser acceptance requires a supported connected backend' {
  $r=Get-DoctorBrowserAcceptance $root $cfg
  Assert ($r.state -ceq 'PASS')
  & $module {$script:browserResult=[pscustomobject]@{exitCode=1;output='{"ok":false,"browserStatus":"ok","chromeSkill":"ok","nodeRepl":"ok","supportedBackendCount":0,"selectionRequired":false}'}}
  Assert ((Get-DoctorBrowserAcceptance $root $cfg).state -ceq 'FAIL')
}
Test 'Verdict rejects empty lowercase and unknown states before precedence' {
  Assert ((Get-DoctorVerdict @()) -ceq 'FAIL')
  Assert ((Get-DoctorVerdict @([pscustomobject]@{state='fail'})) -ceq 'FAIL')
  Assert ((Get-DoctorVerdict @([pscustomobject]@{state='degraded'})) -ceq 'FAIL')
  Assert ((Get-DoctorVerdict @([pscustomobject]@{state='DEGRADED'},[pscustomobject]@{state='PENDING'})) -ceq 'FAIL')
  Assert ((Get-DoctorVerdict @([pscustomobject]@{state='PASS'},[pscustomobject]@{state='SKIP'})) -ceq 'PASS')
  Assert ((Get-DoctorVerdict @([pscustomobject]@{state='DEGRADED'})) -ceq 'DEGRADED')
}

Test 'Missing package JSON failure is sanitized and machine-path free' {
  $missing=Join-Path $root 'does-not-exist'
  $raw=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\Doctor.ps1') -InstallDirectory $missing -Json 2>&1
  $code=$LASTEXITCODE
  Assert ($code -eq 1)
  $text=($raw|Out-String).Trim()
  $j=$text|ConvertFrom-Json
  Assert ($j.verdict -ceq 'FAIL' -and $j.ok -eq $false)
  Assert ($text -notmatch [regex]::Escape($missing))
  Assert ($text -notmatch 'At .*Doctor\.ps1|CategoryInfo|FullyQualifiedErrorId')
}
Test 'Doctor source does not emit untrusted release version text' {
  $text=Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Doctor.ps1') -Raw
  Assert ($text -notmatch '\$cfg\.release\.version')
}

Remove-Item -LiteralPath $root -Recurse -Force
Write-Output ("RESULT: {0}/{0} PASS; Doctor acceptance/aggregation/early diagnostics mocked; no live mutation" -f $script:passed)
