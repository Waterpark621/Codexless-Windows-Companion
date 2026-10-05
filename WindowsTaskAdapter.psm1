Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'UserSessionTask.psm1')
Import-Module (Join-Path $PSScriptRoot 'PrivateConsole.psm1')
Import-Module (Join-Path $PSScriptRoot 'PriorBootOwnership.psm1')

function Get-ProcessIdentity {
    param([int]$ProcessId)
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop
    if ($null -eq $process) { return $null }
    $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid -ErrorAction Stop
    if ($owner.ReturnValue -ne 0) { throw 'PROCESS_OWNER_UNAVAILABLE' }
    [pscustomobject]@{ pid=[int]$process.ProcessId; parentPid=[int]$process.ParentProcessId; userSid=$owner.Sid; executable=$process.ExecutablePath; commandLine=$process.CommandLine; createdAt=$process.CreationDate.ToUniversalTime().ToString('o') }
}

function Get-TaskSchedulerParentIdentity {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return $null }
    # The scheduler service belongs to SYSTEM. Ancestry needs its image and lifetime, not its owner SID.
    $process = $null
    try { $process = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop }
    catch { }
    if ($null -ne $process -and ![string]::IsNullOrWhiteSpace($process.ExecutablePath) -and $null -ne $process.CreationDate) {
        return [pscustomobject]@{ pid=[int]$process.ProcessId; executable=$process.ExecutablePath; createdAt=$process.CreationDate.ToUniversalTime().ToString('o'); identitySource='cim' }
    }
    # Least-privilege task processes cannot query the protected SYSTEM service image directly.
    # SCM publishes the running service PID and configured binary. Accept only the exact Schedule
    # binding, a consistent svchost process lifetime, and a Microsoft-signed System32 image.
    if ($null -eq $process -or [int]$process.ProcessId -ne $ProcessId -or $process.Name -ine 'svchost.exe' -or $null -eq $process.CreationDate) { throw 'TASK_SCHEDULER_PARENT_UNVERIFIED: Process image/lifetime is unavailable.' }
    $service = Get-CimInstance Win32_Service -Filter "Name='Schedule'" -ErrorAction Stop
    if ($null -eq $service -or $service.Name -ine 'Schedule' -or $service.State -cne 'Running' -or $service.StartName -ine 'LocalSystem' -or [int]$service.ProcessId -ne $ProcessId) { throw 'TASK_SCHEDULER_PARENT_UNVERIFIED: Parent is not the live LocalSystem Schedule service.' }
    if ([string]$service.PathName -notmatch '^(?:"(?<image>[^"]+)"|(?<image>\S+))(?:\s|$)') { throw 'TASK_SCHEDULER_PARENT_UNVERIFIED: Service binary path is unavailable.' }
    $serviceImage = $Matches.image
    if ($serviceImage -ine (Join-Path $env:SystemRoot 'System32\svchost.exe')) { throw 'TASK_SCHEDULER_PARENT_UNVERIFIED: Service image is outside the expected System32 path.' }
    $signature = Get-AuthenticodeSignature -LiteralPath $serviceImage -ErrorAction Stop
    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)') { throw 'TASK_SCHEDULER_PARENT_UNVERIFIED: Service image lacks a valid Microsoft signature.' }
    $serviceAgain = Get-CimInstance Win32_Service -Filter "Name='Schedule'" -ErrorAction Stop
    $processAgain = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop
    if ($null -eq $serviceAgain -or $serviceAgain.Name -cne $service.Name -or $serviceAgain.State -cne $service.State -or $serviceAgain.StartName -cne $service.StartName -or $serviceAgain.ProcessId -ne $service.ProcessId -or $serviceAgain.PathName -cne $service.PathName -or $null -eq $processAgain -or $processAgain.ProcessId -ne $process.ProcessId -or $processAgain.Name -cne $process.Name -or $null -eq $processAgain.CreationDate -or $processAgain.CreationDate -ne $process.CreationDate) { throw 'TASK_SCHEDULER_PARENT_UNVERIFIED: Service/process identity changed during verification.' }
    [pscustomobject]@{ pid=$ProcessId; executable=$serviceImage; createdAt=$process.CreationDate.ToUniversalTime().ToString('o'); identitySource='scm'; serviceName=$service.Name; serviceAccount=$service.StartName; serviceState=$service.State; serviceRechecked=$true }
}

function Get-HouseholdRuntimeState {
    param($Definition)
    $launcher = $Definition.LauncherDirectory
    . (Join-Path $launcher 'Core.ps1')
    $cfg = Get-LauncherConfig
    $task = Get-ScheduledTask -TaskName $Definition.Name -TaskPath '\' -ErrorAction SilentlyContinue
    $taskState = if ($null -ne $task) { [string]$task.State } else { 'NotRegistered' }
    $receiptFile = Join-Path $launcher 'task-owner.json'
    $receipt = $null
    if (Test-Path -LiteralPath $receiptFile) { $receipt = Get-Content -LiteralPath $receiptFile -Raw | ConvertFrom-Json }
    $hostIdentity = $null
    $hostPidFile = Join-Path $launcher 'host.pid'
    if (Test-Path -LiteralPath $hostPidFile) {
        $hostProcessId = 0
        if ([int]::TryParse((Get-Content -LiteralPath $hostPidFile -Raw).Trim(),[ref]$hostProcessId)) { $hostIdentity = Get-ProcessIdentity $hostProcessId }
    }
    $ownerVerified = Test-HouseholdOwnerIdentity $receipt $hostIdentity $Definition
    $cleanupState = Get-HouseholdCleanupState $launcher
    $evidencePresent = Test-HouseholdOwnershipEvidence $launcher
    # Retained receipts fence recovery even if writing the degraded marker itself failed.
    # A still-running owner may be publishing/removing host.pid. Explicit markers always block.
    $cleanupRequired = ($null -ne $cleanupState -or ($taskState -ne 'Running' -and !$ownerVerified -and $evidencePresent))
    $listenerPresent = Test-TcpPort -Port ([int]$cfg.port)
    $piecesVerified = ($ownerVerified -and !$cleanupRequired)
    # Never ask Host to terminate a reused/unrelated wrapper PID.
    $wrapperPidFile = Join-Path $launcher 'codexless.pid'
    $consoleReceiptFile = Join-Path $launcher 'codexless-console-owner.json'
    if (Test-Path -LiteralPath $wrapperPidFile) {
        $wrapperProcessId = 0
        if (![int]::TryParse((Get-Content -LiteralPath $wrapperPidFile -Raw).Trim(),[ref]$wrapperProcessId)) { $piecesVerified = $false }
        elseif ($wrapperProcessId -gt 0) {
            $wrapper = Get-ProcessIdentity $wrapperProcessId
            if ($null -ne $wrapper -and ($null -eq $hostIdentity -or $wrapper.parentPid -ne $hostIdentity.pid -or $wrapper.userSid -ne $Definition.UserSid -or $wrapper.executable -ine $Definition.PowerShellExe)) { $piecesVerified = $false }
            if ($null -ne $wrapper) {
                if (!(Test-Path -LiteralPath $consoleReceiptFile)) { $piecesVerified = $false }
                else {
                    $consoleReceipt = Get-Content -LiteralPath $consoleReceiptFile -Raw | ConvertFrom-Json
                    if (!(Test-PrivateConsoleReceipt $consoleReceipt $wrapper $Definition.UserSid)) { $piecesVerified = $false }
                }
            }
        }
    }
    $tunnelPresent = $false
    $tunnels = @()
    foreach ($tunnel in @(Get-ConfiguredTunnels $cfg -IncludeDisabled)) {
        $status = Get-TunnelStatus $cfg $tunnel
        $alive = ($null -ne $status -and $status.process_running -eq $true)
        if ($alive) {
            $tunnelPresent = $true
            # Current official status exposes process.pid; an absent/invalid nested PID fails closed.
            $identity = $null
            $tunnelProcessId = 0
            if ($status.PSObject.Properties['process'] -and $null -ne $status.process -and $status.process.PSObject.Properties['pid'] -and [int]::TryParse([string]$status.process.pid,[ref]$tunnelProcessId) -and $tunnelProcessId -gt 0) {
                $identity = Get-ProcessIdentity $tunnelProcessId
            }
            # Existing aliases are reused, never replaced or registered anew.
            if ($null -eq $identity -or $null -eq $receipt -or $identity.userSid -ne $Definition.UserSid -or $identity.executable -ine $cfg.tunnelExe -or $identity.createdAt -lt $receipt.createdAt -or !$status.PSObject.Properties['tunnel_id'] -or $status.tunnel_id -ne $tunnel.tunnelId) { $piecesVerified = $false }
        }
        $tunnels += [pscustomobject]@{ alias=$tunnel.alias; alive=$alive; ready=($alive -and $status.ready -eq $true) }
    }
    [pscustomobject]@{ taskState=$taskState; hostPresent=($null -ne $hostIdentity); ownerVerified=$ownerVerified; piecesVerified=$piecesVerified; listenerPresent=$listenerPresent; tunnelPresent=$tunnelPresent; tunnels=$tunnels; cleanupRequired=$cleanupRequired; cleanupState=$cleanupState }
}

function Invoke-WindowsPriorBootRecovery {
    param($Definition,[switch]$CheckOnly)
    Invoke-PriorBootOwnership $Definition -CheckOnly:$CheckOnly
}

function New-WindowsTaskAdapter {
    param($Definition)
    Import-Module ScheduledTasks -ErrorAction Stop
    $binding = $Definition
    @{
        GetTask = {
            $task = Get-ScheduledTask -TaskName $binding.Name -TaskPath '\' -ErrorAction SilentlyContinue
            if ($null -eq $task) { return $null }
            [pscustomobject]@{ xml=(Export-ScheduledTask -TaskName $binding.Name -TaskPath '\' -ErrorAction Stop) }
        }.GetNewClosure()
        RegisterTask = { param($value) $null = Register-ScheduledTask -TaskName $value.Name -TaskPath '\' -Xml $value.Xml -ErrorAction Stop }.GetNewClosure()
        StartTask = { Start-ScheduledTask -TaskName $binding.Name -TaskPath '\' -ErrorAction Stop }.GetNewClosure()
        GetStatus = { Get-HouseholdRuntimeState $binding }.GetNewClosure()
        CanRecoverPriorBoot = { try { Invoke-WindowsPriorBootRecovery $binding -CheckOnly; $true } catch { $false } }.GetNewClosure()
        RequestGracefulStop = {
            # Only a verified task-owned Host consumes this signal. No taskkill or Stop-ScheduledTask.
            New-Item -ItemType File -Path (Join-Path $binding.LauncherDirectory 'stop.flag') -Force -ErrorAction Stop | Out-Null
        }.GetNewClosure()
        Now = { [DateTime]::UtcNow }
        Sleep = { Start-Sleep -Milliseconds 500 }
    }
}

Export-ModuleMember -Function New-WindowsTaskAdapter,Get-HouseholdRuntimeState,Get-ProcessIdentity,Get-TaskSchedulerParentIdentity,Invoke-WindowsPriorBootRecovery
