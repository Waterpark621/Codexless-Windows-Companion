Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'MutationLock.psm1')

function Assert-TaskPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or ![IO.Path]::IsPathRooted($Path) -or $Path.Contains('"') -or $Path.Contains("`r") -or $Path.Contains("`n")) {
        throw 'TASK_PATH_INVALID: An absolute local path without quotes/newlines is required.'
    }
    if ($Path.StartsWith('\\')) { throw 'TASK_PATH_INVALID: Network paths are not supported.' }
    [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Assert-HouseholdPrincipal {
    param([string]$CurrentUserSid,[string]$ConfigOwnerSid)
    if ($CurrentUserSid -cne $ConfigOwnerSid -or $CurrentUserSid -notmatch '^S-1-5-21-\d+-\d+-\d+-\d+$') {
        throw 'TASK_OWNER_INVALID: Run as the existing household configuration owner; an inherited profile path does not establish DPAPI identity.'
    }
}

function New-HouseholdTaskDefinition {
    param(
        [string]$UserSid,
        [string]$LauncherDirectory,
        [string]$HostScript,
        [string]$PowerShellExe,
        [string]$TaskName,
        [string]$TransactionId,
        [string]$GenerationId
    )
    if ($UserSid -notmatch '^S-1-5-21-\d+-\d+-\d+-\d+$') { throw 'TASK_OWNER_INVALID: A Windows user SID is required.' }
    $launcher = Assert-TaskPath $LauncherDirectory
    $hostFile = Assert-TaskPath $HostScript
    $powershell = Assert-TaskPath $PowerShellExe
    $defaultName = "Codexless-Household-$UserSid"
    $name = if ([string]::IsNullOrWhiteSpace($TaskName)) { $defaultName } else { $TaskName }
    if ($name -cnotmatch '^Codexless-[A-Za-z0-9_.-]{1,220}$') { throw 'TASK_NAME_INVALID: Refusing an unsafe Scheduled Task name.' }
    $transactionBound = ![string]::IsNullOrWhiteSpace($TransactionId) -or ![string]::IsNullOrWhiteSpace($GenerationId)
    if ($transactionBound) {
        if ($TransactionId -cnotmatch '^[0-9a-f]{32}$' -or $GenerationId -cnotmatch '^[0-9a-f]{32}$') {
            throw 'TASK_TRANSACTION_INVALID: Exact transaction and generation identifiers are required together.'
        }
    }
    $escape = { param($value) [Security.SecurityElement]::Escape($value) }
    # Preserve the existing launcher's process-local script execution setting.
    $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$hostFile`" -LauncherDirectory `"$launcher`" -UserSid $UserSid"
    if ($name -cne $defaultName) { $arguments += " -TaskName `"$name`"" }
    $description='Codexless household user-session owner; launcher-only v1'
    $transactionBinding=$null
    if ($transactionBound) {
        $arguments += " -TransactionId $TransactionId -GenerationId $GenerationId"
        $transactionBinding="$TransactionId/$GenerationId"
        $description += "; transaction=$TransactionId; generation=$GenerationId"
    }
    $registration="<RegistrationInfo><Description>$(& $escape $description)</Description></RegistrationInfo>"
    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  $registration
  <Triggers><LogonTrigger><Enabled>true</Enabled><UserId>$(& $escape $UserSid)</UserId></LogonTrigger></Triggers>
  <Principals><Principal id="Owner"><UserId>$(& $escape $UserSid)</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>false</AllowHardTerminate><StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable><Enabled>true</Enabled><Hidden>true</Hidden>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit><Priority>4</Priority>
    <RestartOnFailure><Interval>PT1M</Interval><Count>3</Count></RestartOnFailure>
  </Settings>
  <Actions Context="Owner"><Exec><Command>$(& $escape $powershell)</Command><Arguments>$(& $escape $arguments)</Arguments><WorkingDirectory>$(& $escape $launcher)</WorkingDirectory></Exec></Actions>
</Task>
"@
    [pscustomobject]@{
        Name=$name
        UserSid=$UserSid
        LauncherDirectory=$launcher
        HostScript=$hostFile
        PowerShellExe=$powershell
        Arguments=$arguments
        TransactionId=if($transactionBound){$TransactionId}else{$null}
        GenerationId=if($transactionBound){$GenerationId}else{$null}
        TransactionBinding=$transactionBinding
        Description=$description
        Xml=$xml
    }
}

function Assert-HouseholdTaskIdentity {
    param([string]$Xml, $Definition)
    try {
        [xml]$actual = $Xml
        [xml]$expected = $Definition.Xml
        # Export-ScheduledTask may normalize XML; compare every safety-relevant field.
        $ns = New-Object Xml.XmlNamespaceManager($actual.NameTable)
        $ns.AddNamespace('t','http://schemas.microsoft.com/windows/2004/02/mit/task')
        $wantedNs = New-Object Xml.XmlNamespaceManager($expected.NameTable)
        $wantedNs.AddNamespace('t','http://schemas.microsoft.com/windows/2004/02/mit/task')
        $actualPriority=$actual.SelectNodes('/t:Task/t:Settings/t:Priority',$ns)
        if($actualPriority.Count -ne 1 -or $actualPriority[0].InnerText -cne '4'){throw 'mismatch: task priority'}
        $expectedDescription=$expected.SelectSingleNode('/t:Task/t:RegistrationInfo/t:Description',$wantedNs)
        $actualDescription=$actual.SelectNodes('/t:Task/t:RegistrationInfo/t:Description',$ns)
        if($actualDescription.Count -ne 1 -or $actualDescription[0].InnerText -cne $expectedDescription.InnerText){throw 'mismatch: task description'}
        # Scheduler export omits these schema defaults; omission preserves their exact meaning.
        $defaults = @{
            '/t:Task/t:Principals/t:Principal/t:RunLevel'='LeastPrivilege'
            '/t:Task/t:Settings/t:Enabled'='true'
            '/t:Task/t:Settings/t:RunOnlyIfNetworkAvailable'='false'
            '/t:Task/t:Triggers/t:LogonTrigger/t:Enabled'='true'
        }
        foreach ($xpath in @('/t:Task/t:Principals/t:Principal/t:UserId','/t:Task/t:Principals/t:Principal/t:LogonType','/t:Task/t:Principals/t:Principal/t:RunLevel','/t:Task/t:Actions/t:Exec/t:Command','/t:Task/t:Actions/t:Exec/t:Arguments','/t:Task/t:Actions/t:Exec/t:WorkingDirectory','/t:Task/t:Settings/t:MultipleInstancesPolicy','/t:Task/t:Settings/t:ExecutionTimeLimit','/t:Task/t:Settings/t:AllowHardTerminate','/t:Task/t:Settings/t:Enabled','/t:Task/t:Settings/t:DisallowStartIfOnBatteries','/t:Task/t:Settings/t:StopIfGoingOnBatteries','/t:Task/t:Settings/t:RunOnlyIfNetworkAvailable','/t:Task/t:Settings/t:RestartOnFailure/t:Count','/t:Task/t:Settings/t:RestartOnFailure/t:Interval','/t:Task/t:Triggers/t:LogonTrigger/t:UserId','/t:Task/t:Triggers/t:LogonTrigger/t:Enabled')) {
            $a = $actual.SelectNodes($xpath,$ns)
            $e = $expected.SelectSingleNode($xpath,$wantedNs)
            if ($a.Count -eq 0 -and $defaults.ContainsKey($xpath) -and $e.InnerText -ceq $defaults[$xpath]) { continue }
            if ($a.Count -ne 1) { throw "mismatch: $xpath" }
            $value=$a[0].InnerText
            if ($xpath -like '*/t:UserId' -and $value -notmatch '^S-1-') {
                $account=New-Object Security.Principal.NTAccount($value)
                $value=$account.Translate([Security.Principal.SecurityIdentifier]).Value
            }
            if ($value -cne $e.InnerText) { throw "mismatch: $xpath" }
        }
        if ($actual.SelectNodes('/t:Task/t:Actions/*',$ns).Count -ne 1 -or $actual.SelectNodes('/t:Task/t:Triggers/*',$ns).Count -ne 1 -or $actual.SelectNodes('/t:Task/t:Principals/*',$ns).Count -ne 1) { throw 'extra actions/triggers/principals' }
    } catch { throw "TASK_IDENTITY_MISMATCH: Refusing to operate an unrelated or changed task ($($_.Exception.Message))." }
}

function Test-HouseholdOwnerIdentity {
    param($Receipt, $Process, $Definition)
    if ($null -eq $Receipt -or $null -eq $Process) { return $false }
    try {
        ($Receipt.version -eq 1 -and $Receipt.pid -eq $Process.pid -and
         $Receipt.createdAt -ceq $Process.createdAt -and $Receipt.userSid -ceq $Definition.UserSid -and
         $Process.userSid -ceq $Definition.UserSid -and $Receipt.taskName -ceq $Definition.Name -and
         $Receipt.hostScript -ceq $Definition.HostScript -and $Receipt.launcherDirectory -ceq $Definition.LauncherDirectory -and
         $Process.executable -ieq $Definition.PowerShellExe -and
         $Process.commandLine.IndexOf('"'+$Definition.HostScript+'"',[StringComparison]::OrdinalIgnoreCase) -ge 0)
    } catch { $false }
}

function Test-TaskSchedulerAncestry {
    param($Process,$Parent,$ScheduleService,[string]$SystemDirectory)
    if ($null -eq $Process -or $null -eq $Parent -or $Process.parentPid -ne $Parent.pid) { return $false }
    if ($Parent.createdAt -gt $Process.createdAt) { return $false }
    if (!$Parent.PSObject.Properties['microsoftSigned'] -or $Parent.microsoftSigned -ne $true) { return $false }
    $taskeng = Join-Path $SystemDirectory 'taskeng.exe'
    $taskhost = Join-Path $SystemDirectory 'taskhostw.exe'
    if ($Parent.executable -ieq $taskeng -or $Parent.executable -ieq $taskhost) { return $true }
    ($null -ne $ScheduleService -and $ScheduleService.State -eq 'Running' -and
     $ScheduleService.ProcessId -eq $Parent.pid -and $Parent.executable -ieq (Join-Path $SystemDirectory 'svchost.exe'))
}

function Write-HouseholdCleanupState {
    param([string]$LauncherDirectory,
        [ValidateSet('supervision','tunnel-stop','tunnel-wait','console-stop','listener-check','task-host')][string]$Stage,
        [int]$OwnerPid)
    $path = Join-Path $LauncherDirectory 'household-cleanup-state.json'
    # Preserve earlier evidence. Never serialize configuration, command lines, keys, or exception text.
    if ([IO.File]::Exists($path)) { return }
    $state = [ordered]@{version=1;state='degraded';stage=$Stage;reasonCode='HOUSEHOLD_VERIFIED_RECOVERY_REQUIRED';recordedAt=[DateTime]::UtcNow.ToString('o');ownerPid=$OwnerPid;requiresVerifiedRecovery=$true}
    foreach ($entry in @{ownerReceiptPresent='task-owner.json';hostPidPresent='host.pid';consoleReceiptPresent='codexless-console-owner.json';wrapperPidPresent='codexless.pid'}.GetEnumerator()) {
        $state[$entry.Key] = [IO.File]::Exists((Join-Path $LauncherDirectory $entry.Value))
    }
    $stream = $null
    try {
        $stream = [IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        $bytes = [Text.Encoding]::UTF8.GetBytes(($state | ConvertTo-Json))
        $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true)
    } finally { if ($null -ne $stream) { $stream.Dispose() } }
}

function Test-HouseholdOwnershipEvidence {
    param([string]$LauncherDirectory)
    foreach ($file in @('task-owner.json','host.pid','codexless-console-owner.json','codexless.pid')) {
        if (Test-Path -LiteralPath (Join-Path $LauncherDirectory $file) -ErrorAction Stop) { return $true }
    }
    $tunnelReceipts=Join-Path $LauncherDirectory 'tunnel-owners'
    if(Test-Path -LiteralPath $tunnelReceipts){
        if((Get-Item -LiteralPath $tunnelReceipts).Attributes -band [IO.FileAttributes]::ReparsePoint){return $true}
        if(@(Get-ChildItem -LiteralPath $tunnelReceipts -File).Count){return $true}
    }
    $false
}

function Get-HouseholdCleanupState {
    param([string]$LauncherDirectory)
    $path = Join-Path $LauncherDirectory 'household-cleanup-state.json'
    if (!(Test-Path -LiteralPath $path -ErrorAction Stop)) { return $null }
    try {
        $saved = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($saved.version -ne 1 -or $saved.state -cne 'degraded' -or $saved.stage -cnotin @('supervision','tunnel-stop','tunnel-wait','console-stop','listener-check','task-host') -or $saved.reasonCode -cne 'HOUSEHOLD_VERIFIED_RECOVERY_REQUIRED') { throw 'invalid' }
        # Surface only validated fixed fields. Extra or malformed fields never leak into status output.
        $pidValue = 0
        if (![int]::TryParse([string]$saved.ownerPid,[ref]$pidValue) -or $pidValue -le 0 -or $saved.recordedAt -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$') { throw 'invalid' }
        [pscustomobject]@{state='degraded';stage=$saved.stage;reasonCode='HOUSEHOLD_VERIFIED_RECOVERY_REQUIRED';recordedAt=$saved.recordedAt;ownerPid=$pidValue;requiresVerifiedRecovery=$true}
    } catch {
        [pscustomobject]@{state='unknown';stage='unknown';reasonCode='HOUSEHOLD_CLEANUP_STATE_INVALID';requiresVerifiedRecovery=$true}
    }
}

function Complete-HouseholdOwnerTracking {
    param([string]$LauncherDirectory,$Identity,[bool]$CleanupCompleted)
    # A write failure must not turn exceptional cleanup into apparent success.
    if (!$CleanupCompleted) { return }
    if ($null -ne (Get-HouseholdCleanupState $LauncherDirectory)) { throw 'HOUSEHOLD_CLEANUP_DEGRADED: Ownership receipts retained.' }
    foreach ($file in @('codexless-console-owner.json','codexless.pid')) {
        if (Test-Path -LiteralPath (Join-Path $LauncherDirectory $file) -ErrorAction Stop) { throw 'HOUSEHOLD_CLEANUP_INCOMPLETE: Remaining wrapper evidence was retained.' }
    }
    $receiptFile = Join-Path $LauncherDirectory 'task-owner.json'
    $saved = Get-Content -LiteralPath $receiptFile -Raw -ErrorAction Stop | ConvertFrom-Json
    if ($null -eq $Identity -or $saved.pid -ne $Identity.pid -or $saved.createdAt -cne $Identity.createdAt -or $saved.userSid -cne $Identity.userSid) { throw 'HOUSEHOLD_CLEANUP_OWNER_INVALID: Ownership receipts retained.' }
    $pidFile = Join-Path $LauncherDirectory 'host.pid'
    if (Test-Path -LiteralPath $pidFile -ErrorAction Stop) {
        if ((Get-Content -LiteralPath $pidFile -Raw -ErrorAction Stop).Trim() -cne ([string]$Identity.pid)) { throw 'HOUSEHOLD_CLEANUP_OWNER_INVALID: Host PID evidence retained.' }
        Remove-Item -LiteralPath $pidFile -ErrorAction Stop
    }
    Remove-Item -LiteralPath $receiptFile -ErrorAction Stop
}

function Invoke-HouseholdLifecycleCore {
    # 30s tunnel wait + 60s console wait + bounded helper/observation margin.
    param([ValidateSet('Register','Start','Stop','Restart','Status')] [string]$Action, $Definition, [hashtable]$Adapter, [ValidateRange(1,600)][int]$TimeoutSeconds=120)
    $task = & $Adapter.GetTask
    if ($null -ne $task) { Assert-HouseholdTaskIdentity $task.xml $Definition }
    if ($Action -eq 'Status') { return & $Adapter.GetStatus }
    if ($Action -eq 'Register') {
        if ($null -ne $task) { return [pscustomobject]@{ state='registered'; changed=$false } }
        & $Adapter.RegisterTask $Definition
        return [pscustomobject]@{ state='registered'; changed=$true }
    }
    if ($null -eq $task) { throw 'TASK_NOT_REGISTERED: Register the approved task first.' }
    if ($Action -eq 'Start') {
        $state = & $Adapter.GetStatus
        if ($state.PSObject.Properties['cleanupRequired'] -and $state.cleanupRequired) {
            # Read-only preflight. Only the Scheduler-verified owner may retire evidence,
            # after repeating every proof under its owner mutex.
            if ($state.taskState -eq 'Running' -or !$Adapter.ContainsKey('CanRecoverPriorBoot') -or !(& $Adapter.CanRecoverPriorBoot)) {
                throw 'HOUSEHOLD_CLEANUP_DEGRADED: Verified recovery is required before startup.'
            }
        }
        if ($state.taskState -eq 'Running') {
            if ($state.hostPresent -and !$state.ownerVerified) { throw 'HOUSEHOLD_FOREIGN_OWNER: Running task does not own the household.' }
            return [pscustomobject]@{ state='already-running'; changed=$false }
        }
        if ($state.hostPresent -or $state.listenerPresent -or $state.tunnelPresent) { throw 'HOUSEHOLD_MIGRATION_REQUIRED: Existing processes must be stopped through their current owner before starting the task.' }
        & $Adapter.StartTask
        return [pscustomobject]@{ state='starting'; changed=$true }
    }
    $state = & $Adapter.GetStatus
    if ($state.PSObject.Properties['cleanupRequired'] -and $state.cleanupRequired) { throw 'HOUSEHOLD_CLEANUP_DEGRADED: Remaining cleanup evidence was not adopted or cleared.' }
    if ($state.taskState -ne 'Running') {
        if ($state.hostPresent -or $state.listenerPresent -or $state.tunnelPresent) { throw 'HOUSEHOLD_FOREIGN_OWNER: Refusing to stop unmanaged processes.' }
    } else {
        if (!$state.ownerVerified -or !$state.piecesVerified) { throw 'HOUSEHOLD_FOREIGN_OWNER: Refusing to stop processes without verified ownership.' }
        & $Adapter.RequestGracefulStop
        $deadline = (& $Adapter.Now).AddSeconds($TimeoutSeconds)
        do {
            $state = & $Adapter.GetStatus
            if ($state.PSObject.Properties['cleanupRequired'] -and $state.cleanupRequired) { throw 'HOUSEHOLD_CLEANUP_DEGRADED: Cleanup failed; no replacement was started.' }
            if ($state.taskState -ne 'Running' -and !$state.hostPresent -and !$state.listenerPresent -and !$state.tunnelPresent) { break }
            if ((& $Adapter.Now) -ge $deadline) { throw 'HOUSEHOLD_STOP_TIMEOUT: Graceful shutdown did not complete; no force kill or duplicate start was attempted.' }
            & $Adapter.Sleep
        } while ($true)
    }
    if ($Action -eq 'Restart') { return Invoke-HouseholdLifecycle -Action Start -Definition $Definition -Adapter $Adapter -TimeoutSeconds $TimeoutSeconds }
    [pscustomobject]@{ state='stopped'; changed=$true }
}

function Invoke-HouseholdLifecycle {
    param([ValidateSet('Register','Start','Stop','Restart','Status')][string]$Action,$Definition,[hashtable]$Adapter,[ValidateRange(1,600)][int]$TimeoutSeconds=120)
    if($Action -ceq 'Status'){return Invoke-HouseholdLifecycleCore @PSBoundParameters}
    Invoke-CompanionMutationLocked $Definition.LauncherDirectory {
        if(!$Adapter.ContainsKey('HostDelegation')){return Invoke-HouseholdLifecycleCore $Action $Definition $Adapter $TimeoutSeconds}
        if($Action -ceq 'Register'){return Invoke-HouseholdLifecycleCore $Action $Definition $Adapter $TimeoutSeconds}
        if($Action -cin @('Stop','Restart')){
            $stopped=Invoke-CompanionHostDelegation $Definition Shutdown {Invoke-HouseholdLifecycleCore Stop $Definition $Adapter $TimeoutSeconds}
            if($Action -ceq 'Stop'){return $stopped}
        }
        Invoke-CompanionHostDelegation $Definition Startup {
            $result=Invoke-HouseholdLifecycleCore Start $Definition $Adapter $TimeoutSeconds
            & $Adapter.WaitReady $TimeoutSeconds
            $result
        }
    }
}
Export-ModuleMember -Function New-HouseholdTaskDefinition,Assert-HouseholdPrincipal,Assert-HouseholdTaskIdentity,Test-HouseholdOwnerIdentity,Test-TaskSchedulerAncestry,Write-HouseholdCleanupState,Test-HouseholdOwnershipEvidence,Get-HouseholdCleanupState,Complete-HouseholdOwnerTracking,Invoke-HouseholdLifecycle
