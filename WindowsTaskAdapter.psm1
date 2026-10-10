Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'MutationLock.psm1')
Import-Module (Join-Path $PSScriptRoot 'UserSessionTask.psm1')
Import-Module (Join-Path $PSScriptRoot 'PrivateConsole.psm1')
Import-Module (Join-Path $PSScriptRoot 'CompanionRuntime.psm1')
Import-Module (Join-Path $PSScriptRoot 'PriorBootOwnership.psm1')
Import-Module (Join-Path $PSScriptRoot 'GenerationIdentity.psm1')
Import-Module (Join-Path $PSScriptRoot 'VerifiedTunnel.psm1') -DisableNameChecking

if(!('Codexless.ScheduledTaskFileAuthority' -as [type])){
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace Codexless {
  [StructLayout(LayoutKind.Sequential)]
  struct ScheduledTaskByHandleFileInformation {
    public uint FileAttributes;
    public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
    public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
    public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
    public uint VolumeSerialNumber;
    public uint FileSizeHigh;
    public uint FileSizeLow;
    public uint NumberOfLinks;
    public uint FileIndexHigh;
    public uint FileIndexLow;
  }
  public sealed class ScheduledTaskFileAuthority : IDisposable {
    SafeFileHandle handle;
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security,
      uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetFileInformationByHandle(SafeFileHandle handle, out ScheduledTaskByHandleFileInformation info);
    public ScheduledTaskFileAuthority(string path, bool allowDelete) {
      uint share = 1u | (allowDelete ? 4u : 0u); // read; optionally delete; never write
      handle = CreateFileW(path, 0x80000000u, share, IntPtr.Zero, 3u, 0x00200000u, IntPtr.Zero);
      if(handle.IsInvalid) {
        int error=Marshal.GetLastWin32Error(); handle.Dispose();
        throw new IOException("TASK_AUTHORITY_UNAVAILABLE", new Win32Exception(error));
      }
      ScheduledTaskByHandleFileInformation info;
      if(!GetFileInformationByHandle(handle,out info)) {
        int error=Marshal.GetLastWin32Error(); handle.Dispose();
        throw new Win32Exception(error);
      }
      if((info.FileAttributes & 0x400u)!=0 || (info.FileAttributes & 0x10u)!=0) {
        handle.Dispose(); throw new IOException("TASK_AUTHORITY_INVALID");
      }
    }
    public void Dispose() { if(handle!=null){handle.Dispose();handle=null;} }
  }
}
'@
}

function Open-HouseholdTaskAuthority {
    param([Parameter(Mandatory=$true)]$Definition,[switch]$AllowDelete)
    if ($null -eq $Definition -or [string]$Definition.Name -cnotmatch '^Codexless-[A-Za-z0-9_.-]{1,220}$') {
        throw 'TASK_AUTHORITY_INVALID: Refusing an unsafe Scheduled Task name.'
    }
    $tasksDirectory = if ([Environment]::Is64BitOperatingSystem -and ![Environment]::Is64BitProcess) {
        Join-Path $env:SystemRoot 'Sysnative\Tasks'
    } else {
        Join-Path $env:SystemRoot 'System32\Tasks'
    }
    $path=Join-Path $tasksDirectory ([string]$Definition.Name)
    [Codexless.ScheduledTaskFileAuthority]::new($path,[bool]$AllowDelete)
}

function Register-HouseholdTaskCreateOnlyCore {
    param([Parameter(Mandatory=$true)]$Definition)
    # Register-ScheduledTask without -Force is a create-only mutation. A raced
    # same-name task makes this call fail rather than overwriting foreign state.
    $null=Register-ScheduledTask -TaskName $Definition.Name -TaskPath '\' -Xml $Definition.Xml -ErrorAction Stop
    $authority=$null
    try {
        # Do not report registration success until the just-created task is pinned
        # against delete/write replacement and its full safety identity re-proves.
        # If an attacker wins the tiny create/open gap, this proof sees the foreign
        # object and fails closed rather than adopting it.
        $authority=Open-HouseholdTaskAuthority -Definition $Definition
        $xml=Export-ScheduledTask -TaskName $Definition.Name -TaskPath '\' -ErrorAction Stop
        Assert-HouseholdTaskIdentity $xml $Definition
    } finally { if($authority){$authority.Dispose()} }
}

function Start-HouseholdTaskPinnedCore {
    param([Parameter(Mandatory=$true)]$Definition)
    $authority=$null
    try {
        # No delete/write sharing: after this open, same-name delete, update, or
        # replacement cannot cross the final XML proof before Start-ScheduledTask.
        $authority=Open-HouseholdTaskAuthority -Definition $Definition
        $xml=Export-ScheduledTask -TaskName $Definition.Name -TaskPath '\' -ErrorAction Stop
        Assert-HouseholdTaskIdentity $xml $Definition
        Start-ScheduledTask -TaskName $Definition.Name -TaskPath '\' -ErrorAction Stop
    } finally { if($authority){$authority.Dispose()} }
}

function Unregister-HouseholdTaskPinnedCore {
    param([Parameter(Mandatory=$true)]$Definition)
    $authority=$null
    try {
        # Delete sharing lets Scheduler retire the exact held file. Write sharing
        # remains denied, so a same-name registration/update cannot replace it
        # before the unregister completes; recreation stays blocked until dispose.
        $authority=Open-HouseholdTaskAuthority -Definition $Definition -AllowDelete
        $xml=Export-ScheduledTask -TaskName $Definition.Name -TaskPath '\' -ErrorAction Stop
        Assert-HouseholdTaskIdentity $xml $Definition
        Unregister-ScheduledTask -TaskName $Definition.Name -TaskPath '\' -Confirm:$false -ErrorAction Stop
        if ($null -ne (Get-ScheduledTask -TaskName $Definition.Name -TaskPath '\' -ErrorAction SilentlyContinue)) {
            throw 'TASK_REMOVE_UNPROVEN: Scheduled Task still resolves after unregister.'
        }
    } finally { if($authority){$authority.Dispose()} }
}

function Get-ProcessIdentity {
    param([int]$ProcessId)
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop
    if ($null -eq $process) { return $null }
    try { $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid -ErrorAction Stop }
    catch {
        # Cooperative exit can occur after the initial CIM snapshot. Treat only
        # proven disappearance as absent; a replacement or unavailable query fails.
        $again=Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop
        if($null -eq $again){return $null}
        throw 'PROCESS_OWNER_UNAVAILABLE'
    }
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

function Get-HouseholdRuntimeStateUnchecked {
    param($Definition)
    $launcher = $Definition.LauncherDirectory
    $cfg = Get-CompanionConfig $launcher
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
    if($ownerVerified){try{Assert-CompanionGenerationContract $receipt.generationContract $cfg}catch{$ownerVerified=$false}}
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
            try{if(!(Test-OwnedTunnel $launcher $cfg $tunnel $status)){$piecesVerified=$false}}catch{$piecesVerified=$false}
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
        $tunnels += [pscustomobject]@{ profileId=if($tunnel.PSObject.Properties['profileId']){$tunnel.profileId}else{$tunnel.alias}; enabled=if($tunnel.PSObject.Properties['enabled']){$tunnel.enabled}else{$true}; alias=$tunnel.alias; alive=$alive; ready=($alive -and $status.PSObject.Properties['healthy'] -and $status.healthy -is [bool] -and $status.healthy -and $status.PSObject.Properties['ready'] -and $status.ready -is [bool] -and $status.ready) }
    }
    [pscustomobject]@{ taskState=$taskState; hostPresent=($null -ne $hostIdentity); ownerVerified=$ownerVerified; piecesVerified=$piecesVerified; listenerPresent=$listenerPresent; tunnelPresent=$tunnelPresent; tunnels=$tunnels; cleanupRequired=$cleanupRequired; cleanupState=$cleanupState }
}

function Get-HouseholdRuntimeState {
    param($Definition)
    try { $state=Get-HouseholdRuntimeStateUnchecked $Definition }
    catch {
        if ($_.Exception.Message -cne 'PROCESS_OWNER_UNAVAILABLE') { throw }
        # An unavailable owner is an incomplete observation, never proof of absence.
        # Preserve every identity check and fence all mutations/recovery as degraded.
        $task=Get-ScheduledTask -TaskName $Definition.Name -TaskPath '\' -ErrorAction Stop
        $state=[pscustomobject]@{
            taskState=$(if($task){[string]$task.State}else{'NotRegistered'}); hostPresent=$null; ownerVerified=$false
            piecesVerified=$false; listenerPresent=$null; tunnelPresent=$null
            tunnels=@(); cleanupRequired=$true
            observationComplete=$false; identityError='PROCESS_OWNER_UNAVAILABLE'
            cleanupState=[pscustomobject]@{
                state='degraded'; reasonCode='PROCESS_OWNER_UNAVAILABLE'
                requiresVerifiedRecovery=$true
            }
        }
    }
    if ($state.cleanupRequired -and $state.taskState -ne 'Running') {
        try {
            # Absence comes from the complete prior-boot proof, never PID mismatch.
            # Controller Start repeats this read-only proof before scheduling.
            Invoke-PriorBootOwnership $Definition -CheckOnly
            $state.hostPresent=$false;$state.listenerPresent=$false;$state.tunnelPresent=$false
            $state | Add-Member -NotePropertyName priorBootRecoveryAvailable -NotePropertyValue $true
        } catch {
            $state | Add-Member -NotePropertyName priorBootRecoveryReason -NotePropertyValue (Get-PriorBootRecoveryReason $_)
        }
    }
    $state
}

function Invoke-WindowsPriorBootRecovery {
    param($Definition,[switch]$CheckOnly)
    Invoke-PriorBootOwnership $Definition -CheckOnly:$CheckOnly
}

function New-WindowsTaskAdapter {
    param($Definition)
    Import-Module ScheduledTasks -ErrorAction Stop
    $binding = $Definition
    $mutationLock=Get-Command Invoke-CompanionMutationLocked
    $testReady=Get-Command Test-CodexlessReady
    $getConfig=Get-Command Get-CompanionConfig
    # GetNewClosure executes in a private dynamic module. Capture every module-
    # bound/helper command explicitly so native execution cannot depend on the
    # caller's import/session state.
    $getScheduledTask=Get-Command Get-ScheduledTask -ErrorAction Stop
    $exportScheduledTask=Get-Command Export-ScheduledTask -ErrorAction Stop
    $registerTask=Get-Command Register-HouseholdTaskCreateOnly -ErrorAction Stop
    $startTask=Get-Command Start-HouseholdTaskPinned -ErrorAction Stop
    $getRuntimeState=Get-Command Get-HouseholdRuntimeState -ErrorAction Stop
    $priorBootRecovery=Get-Command Invoke-WindowsPriorBootRecovery -ErrorAction Stop
    $recoveryReason=Get-Command Get-PriorBootRecoveryReason -ErrorAction Stop
    $recoveryObservation=[pscustomobject]@{reason=$null}
    @{
        HostDelegation = $true
        WaitReady = {
            param([int]$TimeoutSeconds)
            $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
            do {
                $state=& $getRuntimeState $binding
                $tunnelsReady=@($state.tunnels|Where-Object {(!$_.PSObject.Properties['enabled'] -or $_.enabled) -and !$_.ready}).Count -eq 0
                if($state.taskState -eq 'Running' -and $state.ownerVerified -and $state.piecesVerified -and
                   $state.listenerPresent -and !$state.cleanupRequired -and $tunnelsReady -and (& $testReady (& $getConfig $binding.LauncherDirectory))){return}
                if($state.cleanupRequired -or [DateTime]::UtcNow -ge $deadline){throw 'HOUSEHOLD_START_NOT_READY'}
                Start-Sleep -Milliseconds 250
            }while($true)
        }.GetNewClosure()
        GetTask = {
            $task = & $getScheduledTask -TaskName $binding.Name -TaskPath '\' -ErrorAction SilentlyContinue
            if ($null -eq $task) { return $null }
            [pscustomobject]@{ xml=(& $exportScheduledTask -TaskName $binding.Name -TaskPath '\' -ErrorAction Stop) }
        }.GetNewClosure()
        RegisterTask = { param($value) & $registerTask -Definition $value }.GetNewClosure()
        StartTask = { & $startTask -Definition $binding }.GetNewClosure()
        GetStatus = { & $getRuntimeState $binding }.GetNewClosure()
        CanRecoverPriorBoot = {
            $recoveryObservation.reason=$null
            try { & $priorBootRecovery $binding -CheckOnly; $true }
            catch { $recoveryObservation.reason=& $recoveryReason $_; $false }
        }.GetNewClosure()
        RecoveryFailureReason = { $recoveryObservation.reason }.GetNewClosure()
        RequestGracefulStop = {
            # Only a verified task-owned Host consumes this signal. No taskkill or Stop-ScheduledTask.
            & $mutationLock $binding.LauncherDirectory { New-Item -ItemType File -Path (Join-Path $binding.LauncherDirectory 'stop.flag') -Force -ErrorAction Stop | Out-Null }
        }.GetNewClosure()
        Now = { [DateTime]::UtcNow }
        Sleep = { Start-Sleep -Milliseconds 500 }
    }
}

function Register-HouseholdTaskCreateOnly {
 param([Parameter(Mandatory=$true)]$Definition)
 Invoke-CompanionMutationLocked $Definition.LauncherDirectory { Register-HouseholdTaskCreateOnlyCore $Definition }
}
function Start-HouseholdTaskPinned {
 param([Parameter(Mandatory=$true)]$Definition)
 Invoke-CompanionMutationLocked $Definition.LauncherDirectory { Start-HouseholdTaskPinnedCore $Definition }
}
function Unregister-HouseholdTaskPinned {
 param([Parameter(Mandatory=$true)]$Definition)
 Invoke-CompanionMutationLocked $Definition.LauncherDirectory { Unregister-HouseholdTaskPinnedCore $Definition }
}
Export-ModuleMember -Function New-WindowsTaskAdapter,Get-HouseholdRuntimeState,Get-ProcessIdentity,Get-TaskSchedulerParentIdentity,Invoke-WindowsPriorBootRecovery,Open-HouseholdTaskAuthority,Register-HouseholdTaskCreateOnly,Start-HouseholdTaskPinned,Unregister-HouseholdTaskPinned
