$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\VerifiedTunnel.psm1') -Force -DisableNameChecking
$module=Get-Module VerifiedTunnel
$root=Join-Path $PSScriptRoot ('.fixtures\multi-lifecycle-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$passed=0
& $module {
    function script:Get-TunnelGenerationProof {param($Config,$Tunnel) $script:Contexts[$Tunnel.alias]}
    function script:Get-TunnelRuntimeContext {param($Config,$Tunnel) $script:Contexts[$Tunnel.alias]}
    function script:Assert-TunnelExecutable {param($Config) 'fcc85a69ec0ad82518e4f8964f60c45e31787957782a0fc9c1b0c44e82d61b9b'}
    function script:Get-CimInstance {param($ClassName,$Filter,$OperationTimeoutSec,$ErrorAction) $script:Live; if($script:Foreign){[pscustomobject]@{ProcessId=333}}}
    function script:Get-ConsoleProcessIdentity {param($ProcessId) if($ProcessId -eq 100){$script:Owner}else{$script:Children[$ProcessId]}}
    function script:Get-TunnelStatus {param($Config,$Tunnel) $script:Statuses[$Tunnel.alias]}
    function script:Connect-TunnelRuntime {
        param($Config,$Tunnel,$PlainKey)
        if($PlainKey -cne ('fixture-key-'+$Tunnel.profileId)){throw 'credential binding changed'}
        $script:KeysSeen[$Tunnel.profileId]=$true
        $script:Statuses[$Tunnel.alias].process_running=$true
        $script:Live += [pscustomobject]@{ProcessId=$script:Statuses[$Tunnel.alias].process.pid}
        [pscustomobject]@{Ok=($Tunnel.alias -cne $script:FailedConnect);Code=if($Tunnel.alias -ceq $script:FailedConnect){'NATIVE_EXIT_FAILED'}else{'NATIVE_OK'};ExitCode=if($Tunnel.alias -ceq $script:FailedConnect){1}else{0};LifetimeMayRemain=$false;TimedOut=$false;OutputOverflow=$false;ProcessId=$script:Statuses[$Tunnel.alias].process.pid+1000;CreatedAt='2026-10-03T00:00:00.0000000Z';ExitedAt='2026-10-03T00:00:02.0000000Z'}
    }
    function script:New-Object {param($TypeName,$ArgumentList)
        if($TypeName -cne 'Codexless.TunnelLifetime'){throw 'unexpected native construction'}
        $lease=[pscustomobject]@{NativeHandle=[IntPtr]1;CreatedAt='2026-10-03T00:00:01.1234567Z';Executable='C:\fixture\tunnel-client.exe';Exited=$false;Disposed=$false}
        $lease|Add-Member ScriptMethod WaitForExit {param($ms) $this.Exited}
        $lease|Add-Member ScriptMethod Dispose {$this.Disposed=$true}
        $script:Lease=$lease;$lease
    }
    function script:Invoke-TunnelNative {
        param($Config,$Tunnel,$Arguments,$TimeoutMs,$PlainKey,$StateRoot,$GuardHandle)
        if($GuardHandle -ne [IntPtr]1 -or ($Arguments -join '|') -cne ('runtimes|stop|'+$Tunnel.alias+'|--json') -or $PlainKey){throw 'stop contract'}
        $processes=Get-Content -LiteralPath (Join-Path $StateRoot 'processes.yaml') -Raw|ConvertFrom-Json
        if(@($processes.PSObject.Properties).Count -ne 1 -or $processes.PSObject.Properties[$Tunnel.alias].Value.pid -ne $script:Statuses[$Tunnel.alias].process.pid){throw 'non-exact stop snapshot'}
        $script:Stopped.Add($Tunnel.profileId)
        $script:Lease.Exited=$true
        $pidToStop=$script:Statuses[$Tunnel.alias].process.pid
        $script:Live=@($script:Live|Where-Object {$_.ProcessId -ne $pidToStop})
        $script:Statuses[$Tunnel.alias].process_running=$false
        [pscustomobject]@{GuardTransferred=$true;Ok=$true;Stdout=([pscustomobject]@{alias=$Tunnel.alias;tunnel_id=$Tunnel.tunnelId;stopped=$true}|ConvertTo-Json -Compress)}
    }
}
function Assert([bool]$value){if(!$value){throw 'assertion failed'}}
function Refuses([scriptblock]$body){$caught=$false;try {& $body|Out-Null}catch{$caught=$_.Exception.Message -ceq 'TUNNEL_FOREIGN_PROCESS_PRESENT'};Assert $caught}
function Fixture {
    $folder=Join-Path $root ([Guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path $folder
    $script:cfg=[pscustomobject]@{companionRoot=$folder;tunnelExe='C:\fixture\tunnel-client.exe';tunnels=@()}
    foreach($alias in @('alpha','beta','gamma','fourth')){$cfg.tunnels += [pscustomobject]@{profileId=$alias;alias=$alias;tunnelId=('tunnel_'+$alias);enabled=$true}}
    & $module {param($folder,$sid,$profiles)
        $script:Owner=[pscustomobject]@{pid=100;createdAt='2026-10-03T00:00:00.0000000Z';userSid=$sid}
        $script:FailedConnect='';$script:Contexts=@{};$script:Statuses=@{};$script:Children=@{};$script:Live=@();$script:Foreign=$false;$script:KeysSeen=@{};$script:Stopped=[Collections.Generic.List[string]]::new()
        $i=0
        foreach($profile in $profiles){
            $processId=77+$i;$i++
            $state=Join-Path $folder ('native\'+$profile.alias);$directory=Join-Path $state 'profiles'
            $script:Contexts[$profile.alias]=[pscustomobject]@{owner=$script:Owner;stateRoot=$state;profileRoot=$directory;intentPath=(Join-Path $state 'connect-intent.json');generationSha256=('a'*64)}
            $script:Children[$processId]=[pscustomobject]@{pid=$processId;parentPid=$processId+1000;createdAt='2026-10-03T00:00:01.1234560Z';userSid=$sid;executable='C:\fixture\tunnel-client.exe';commandLine=('"C:\fixture\tunnel-client.exe" run --profile-dir "'+$directory+'" --profile '+$profile.alias)}
            $script:Statuses[$profile.alias]=[pscustomobject]@{alias=$profile.alias;tunnel_id=$profile.tunnelId;process_running=$false;healthy=$true;ready=$true;process=[pscustomobject]@{alias=$profile.alias;tunnel_id=$profile.tunnelId;pid=$processId;mode='process'}}
        }
    } $folder $sid $cfg.tunnels
}
function Start-Profile($profile){Start-OwnedTunnel $cfg.companionRoot $cfg $profile ('fixture-key-'+$profile.profileId)}
function Owned($profile){& $module {param($cfg,$profile) Test-OwnedTunnel $cfg.companionRoot $cfg $profile (Get-TunnelStatus $cfg $profile)} $cfg $profile}
function Test([string]$name,[scriptblock]$body){Fixture;& $body;$script:passed++;Write-Output "PASS $name"}
try {
    Test 'Three exact siblings connect with independent credential and lifetime bindings' {
        foreach($profile in $cfg.tunnels[0..2]){Assert (Start-Profile $profile);Assert (Owned $profile)}
        Assert (& $module {$script:KeysSeen.Count -eq 3 -and $script:Live.Count -eq 3})
        Assert (@(Get-ChildItem -LiteralPath (Join-Path $cfg.companionRoot 'tunnel-owners') -File).Count -eq 3)
    }
    Test 'Never-launched configured profile needs no stop and cannot stop a sibling' {
        Start-Profile $cfg.tunnels[0]|Out-Null
        Stop-OwnedTunnel $cfg.companionRoot $cfg $cfg.tunnels[1]
        Assert (Owned $cfg.tunnels[0])
        Assert (& $module {$script:Stopped.Count -eq 0 -and $script:Live.Count -eq 1})
    }
    Test 'One revoked-key degraded exact child does not block two healthy sibling clients' {
        & $module {$script:FailedConnect='alpha';$script:Statuses.alpha.healthy=$false;$script:Statuses.alpha.ready=$false}
        foreach($profile in $cfg.tunnels[0..2]){Assert (Start-Profile $profile);Assert (Owned $profile)}
        Assert (& $module {@($script:Statuses.Values|Where-Object {$_.process_running -and $_.healthy -and $_.ready}).Count -eq 2})
    }
    Test 'Exact stop of one profile leaves both other clients and receipts intact' {
        foreach($profile in $cfg.tunnels[0..2]){Start-Profile $profile|Out-Null}
        Stop-OwnedTunnel $cfg.companionRoot $cfg $cfg.tunnels[1]
        Assert (!(Test-Path -LiteralPath (Get-TunnelOwnerPath $cfg.companionRoot $cfg.tunnels[1])))
        Assert (Owned $cfg.tunnels[0]);Assert (Owned $cfg.tunnels[2])
        Assert (& $module {$script:Stopped.Count -eq 1 -and $script:Stopped[0] -ceq 'beta' -and $script:Live.Count -eq 2})
    }
    Test 'Stop all exact configured siblings retires only their receipts' {
        foreach($profile in $cfg.tunnels[0..2]){Start-Profile $profile|Out-Null}
        foreach($profile in $cfg.tunnels[0..2]){Stop-OwnedTunnel $cfg.companionRoot $cfg $profile}
        Assert (& $module {$script:Stopped.Count -eq 3 -and $script:Live.Count -eq 0})
        Assert (@(Get-ChildItem -LiteralPath (Join-Path $cfg.companionRoot 'tunnel-owners') -File).Count -eq 0)
        Fixture
        foreach($profile in $cfg.tunnels[0..2]){Assert (Start-Profile $profile);Assert (Owned $profile)}
    }
    Test 'Foreign full client alongside owned siblings blocks another connect without adoption' {
        Start-Profile $cfg.tunnels[0]|Out-Null;& $module {$script:Foreign=$true}
        Refuses {Start-Profile $cfg.tunnels[1]}
        Assert (!(Test-Path -LiteralPath (Get-TunnelOwnerPath $cfg.companionRoot $cfg.tunnels[1])))
        Assert (& $module {$script:KeysSeen.Count -eq 1})
    }
    Test 'Sibling PID reuse and mismatched creation time remain fail-closed' {
        Start-Profile $cfg.tunnels[0]|Out-Null;& $module {$script:Children[77].createdAt='2026-10-04T00:00:00.0000000Z'}
        Refuses {Start-Profile $cfg.tunnels[1]}
        Assert (& $module {$script:KeysSeen.Count -eq 1})
    }
    Test 'Ambiguous sibling registration cannot authorize a shared executable process' {
        Start-Profile $cfg.tunnels[0]|Out-Null;& $module {$script:Statuses.alpha.tunnel_id='tunnel_foreign'}
        Refuses {Start-Profile $cfg.tunnels[1]}
        Assert (& $module {$script:KeysSeen.Count -eq 1})
    }
} finally {Remove-Item -LiteralPath $root -Recurse -Force}
Write-Output ("RESULT: {0}/{0} PASS; exact multi-profile launch/stop receipts with mocked native process and CLI surfaces" -f $passed)
