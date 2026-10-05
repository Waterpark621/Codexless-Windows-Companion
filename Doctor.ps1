param(
    [string]$InstallDirectory=(Join-Path $env:LOCALAPPDATA 'CodexlessCompanion'),
    [switch]$Json
)
$ErrorActionPreference='Stop'
$checks=New-Object Collections.Generic.List[object]

function Add-Check([string]$Name,[string]$State,[string]$Detail) {
    $checks.Add([pscustomobject]@{name=$Name;state=$State;detail=$Detail})
}

try {
    if (!(Test-Path -LiteralPath $InstallDirectory -PathType Container)) {
        throw 'Companion install directory is missing.'
    }
    $runtime=Join-Path $InstallDirectory 'CompanionRuntime.psm1'
    if (!(Test-Path -LiteralPath $runtime -PathType Leaf)) {
        throw 'CompanionRuntime.psm1 is missing.'
    }

    Import-Module $runtime -Force
    $cfg=Get-CompanionConfig $InstallDirectory
    Add-Check 'settings' 'PASS' 'settings.json is valid and destination-owned paths resolve.'
    Add-Check 'release' 'PASS' ("Codexless {0}; build {1}; host contract {2}." -f $cfg.release.version,$cfg.release.buildId.Substring(0,12),$cfg.release.hostContractVersion)
    Add-Check 'node' 'PASS' $cfg.nodeExe

    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $taskName="Codexless-Household-$sid"
    $task=Get-ScheduledTask -TaskName $taskName -TaskPath ([string][char]92) -ErrorAction SilentlyContinue
    if ($null -eq $task) {
        Add-Check 'task' 'FAIL' 'Scheduled Task is not registered.'
    } else {
        Add-Check 'task' 'PASS' ("Scheduled Task state: {0}." -f [string]$task.State)
        try {
            $raw=(& (Join-Path $InstallDirectory 'Household-Task.ps1') -Action Status -LauncherDirectory $InstallDirectory | Out-String).Trim()
            $status=$raw|ConvertFrom-Json

            $ownerState=if($status.taskState -eq 'Running' -and $status.ownerVerified -and $status.piecesVerified -and !$status.cleanupRequired){'PASS'}else{'FAIL'}
            Add-Check 'owner' $ownerState ("task={0}; host={1}; ownerVerified={2}; piecesVerified={3}; cleanupRequired={4}" -f $status.taskState,$status.hostPresent,$status.ownerVerified,$status.piecesVerified,$status.cleanupRequired)

            if($status.listenerPresent -and (Test-CodexlessReady $cfg)){
                Add-Check 'codexless-readiness' 'PASS' $cfg.readyUrl
            }else{
                Add-Check 'codexless-readiness' 'FAIL' ("listenerPresent={0}; readyz did not establish expected release identity." -f $status.listenerPresent)
            }

            if(@($cfg.tunnels).Count -eq 0){
                Add-Check 'tunnel' 'SKIP' 'Tunnel is disabled in settings.'
            }else{
                foreach($t in @($cfg.tunnels)){
                    $ts=Get-TunnelStatus $cfg $t
                    if($null -ne $ts -and $ts.process_running -eq $true -and $ts.ready -eq $true -and $ts.tunnel_id -eq $t.tunnelId){
                        Add-Check ("tunnel:"+$t.alias) 'PASS' 'Official runtime status is running and ready.'
                    }else{
                        Add-Check ("tunnel:"+$t.alias) 'FAIL' 'Official runtime status is absent, not running, not ready, or bound to another tunnel.'
                    }
                }
            }
        }catch{
            Add-Check 'household-status' 'FAIL' $_.Exception.Message
        }
    }

    Add-Check 'browser-extension' 'PENDING' 'Browser backend connectivity is not yet part of Doctor v0; this remains a friend-install release gate.'
}catch{
    Add-Check 'doctor' 'FAIL' $_.Exception.Message
}

$failed=@($checks|Where-Object {$_.state -eq 'FAIL'}).Count
$result=[pscustomobject]@{
    ok=($failed -eq 0)
    installDirectory=$InstallDirectory
    checks=@($checks)
}

if($Json){
    $result|ConvertTo-Json -Depth 6
}else{
    $result.checks|Format-Table -AutoSize
    if($result.ok){
        Write-Output 'Doctor: PASS (Browser backend probe still pending for release qualification).'
    }else{
        Write-Output 'Doctor: FAIL'
        exit 1
    }
}
