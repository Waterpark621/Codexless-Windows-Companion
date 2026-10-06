param(
    [string]$InstallDirectory=(Join-Path $env:LOCALAPPDATA 'CodexlessCompanion'),
    [switch]$Json,
    [ValidatePattern('^$|^Codexless-NativeAdapter-Test-[0-9a-f]{32}$')][string]$DisposableTaskName
)
$ErrorActionPreference='Stop'
$checks=New-Object Collections.Generic.List[object]

function Add-Check([string]$Name,[string]$State,[string]$Detail) {
    $checks.Add([pscustomobject]@{name=$Name;state=$State;detail=$Detail})
}

function Get-LocalDoctorVerdict([object[]]$Checks) {
    if($null -eq $Checks -or @($Checks).Count -eq 0){return 'FAIL'}
    $canonical=@('PASS','DEGRADED','FAIL','SKIP')
    foreach($check in @($Checks)){
        if($null -eq $check -or !$check.PSObject.Properties['state']){return 'FAIL'}
        $state=[string]$check.state
        if(@($canonical|Where-Object{$_ -ceq $state}).Count -ne 1){return 'FAIL'}
    }
    if(@($Checks|Where-Object{[string]$_.state -ceq 'FAIL'}).Count -gt 0){return 'FAIL'}
    if(@($Checks|Where-Object{[string]$_.state -ceq 'DEGRADED'}).Count -gt 0){return 'DEGRADED'}
    'PASS'
}

try {
    if (!(Test-Path -LiteralPath $InstallDirectory -PathType Container)) {
        throw 'DOCTOR_INSTALL_DIRECTORY_MISSING'
    }
    $runtime=Join-Path $PSScriptRoot 'CompanionRuntime.psm1'
    $support=Join-Path $PSScriptRoot 'DoctorSupport.psm1'
    if (!(Test-Path -LiteralPath $runtime -PathType Leaf) -or !(Test-Path -LiteralPath $support -PathType Leaf)) {
        throw 'DOCTOR_PACKAGE_INCOMPLETE'
    }

    Import-Module $runtime -Force -ErrorAction Stop
    Import-Module $support -Force -ErrorAction Stop
    $cfg=Get-CompanionConfig $InstallDirectory

    Add-Check 'settings' 'PASS' 'Destination settings are valid.'
    Add-Check 'release' 'PASS' 'Selected Codexless release/build identity is valid.'
    Add-Check 'node' 'PASS' 'Configured Node executable is available.'

    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $taskName=if($DisposableTaskName){$DisposableTaskName}else{"Codexless-Household-$sid"}
    $task=Get-ScheduledTask -TaskName $taskName -TaskPath ([string][char]92) -ErrorAction SilentlyContinue
    if ($null -eq $task) {
        Add-Check 'task' 'FAIL' 'Scheduled Task is not registered.'
    } else {
        $taskState=[string]$task.State
        if($taskState -ceq 'Running'){
            Add-Check 'task' 'PASS' 'Scheduled Task is running.'
        }else{
            Add-Check 'task' 'FAIL' 'Scheduled Task is not running.'
        }

        try {
            $raw=(& (Join-Path $PSScriptRoot 'Household-Task.ps1') -Action Status -LauncherDirectory $InstallDirectory -DisposableTaskName $DisposableTaskName | Out-String).Trim()
            $status=$raw|ConvertFrom-Json -ErrorAction Stop
            $ownerState=if($status.taskState -eq 'Running' -and $status.ownerVerified -and $status.piecesVerified -and !$status.cleanupRequired){'PASS'}else{'FAIL'}
            Add-Check 'owner' $ownerState $(if($ownerState -ceq 'PASS'){'Household owner and tracked pieces are verified.'}else{'Household owner or tracked pieces could not be verified.'})
        } catch {
            Add-Check 'owner' 'FAIL' 'Household ownership status could not be verified.'
        }

        $ownershipBefore=Get-DoctorListenerOwnershipSnapshot $InstallDirectory $cfg -DisposableTaskName $DisposableTaskName
        $ownershipMid=$null
        $ownershipAfter=$null
        $readinessOk=$false
        $browserResult=$null

        if($null -ne $ownershipBefore){
            $readinessOk=Test-CodexlessReady $cfg
            if($readinessOk){
                $ownershipMid=Get-DoctorListenerOwnershipSnapshot $InstallDirectory $cfg -DisposableTaskName $DisposableTaskName
            }
            if($readinessOk -and (Test-DoctorOwnershipSnapshotEqual $ownershipBefore $ownershipMid)){
                $browserResult=Get-DoctorBrowserAcceptance $InstallDirectory $cfg
                $ownershipAfter=Get-DoctorListenerOwnershipSnapshot $InstallDirectory $cfg -DisposableTaskName $DisposableTaskName
            }
        }

        $listenerStable=(
            $null -ne $ownershipBefore -and
            $null -ne $ownershipMid -and
            $null -ne $ownershipAfter -and
            (Test-DoctorOwnershipSnapshotEqual $ownershipBefore $ownershipMid) -and
            (Test-DoctorOwnershipSnapshotEqual $ownershipBefore $ownershipAfter)
        )
        if($listenerStable){
            Add-Check 'listener-ownership' 'PASS' 'Loopback listener stayed bound to the exact verified household owner chain.'
        }else{
            Add-Check 'listener-ownership' 'FAIL' 'Loopback listener ownership could not be established or changed during verification.'
        }

        if($readinessOk -and $listenerStable){
            Add-Check 'codexless-readiness' 'PASS' 'Codexless readiness matches the selected release and host contract.'
        }else{
            Add-Check 'codexless-readiness' 'FAIL' 'Codexless readiness or release identity could not be established on the verified listener.'
        }

        $tunnel=Get-DoctorTunnelAcceptance $InstallDirectory $cfg
        Add-Check 'tunnel-ownership' $tunnel.state $tunnel.detail

        if($null -ne $browserResult -and $listenerStable){
            Add-Check 'browser-backend' $browserResult.state $browserResult.detail
        }else{
            Add-Check 'browser-backend' 'FAIL' 'Codexless Browser backend connectivity was not established on the verified listener.'
        }
    }
} catch {
    Add-Check 'doctor' 'FAIL' 'Doctor could not establish the configured Companion package.'
}

$checkArray=[object[]]$checks.ToArray()
$verdict=Get-LocalDoctorVerdict $checkArray
$result=[pscustomobject]@{
    ok=($verdict -ceq 'PASS')
    verdict=$verdict
    checks=$checkArray
}

if($Json){
    $result|ConvertTo-Json -Depth 6
}else{
    $result.checks|Format-Table -AutoSize
    Write-Output ("Doctor: "+$result.verdict)
}

if($verdict -ceq 'FAIL'){exit 1}
if($verdict -ceq 'DEGRADED'){exit 2}
