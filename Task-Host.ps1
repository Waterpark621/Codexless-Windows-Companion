param([Parameter(Mandatory=$true)] [string]$LauncherDirectory, [Parameter(Mandatory=$true)] [string]$UserSid)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'UserSessionTask.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'WindowsTaskAdapter.psm1') -Force
if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -cne $UserSid) { throw 'TASK_OWNER_INVALID' }
Assert-HouseholdPrincipal $UserSid (Get-Acl -LiteralPath (Join-Path $LauncherDirectory 'settings.json') -ErrorAction Stop).GetOwner([Security.Principal.SecurityIdentifier]).Value
$definition = New-HouseholdTaskDefinition -UserSid $UserSid -LauncherDirectory $LauncherDirectory -HostScript $PSCommandPath -PowerShellExe (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
# A running task alone does not prove that this process was spawned by Task Scheduler.
$taskIdentity = Get-ProcessIdentity $PID
$parentIdentity = Get-TaskSchedulerParentIdentity $taskIdentity.parentPid
if ($null -eq $parentIdentity) { throw 'TASK_OWNER_INVALID: Scheduler parent is unavailable.' }
$parentSignature = Get-AuthenticodeSignature -LiteralPath $parentIdentity.executable -ErrorAction Stop
$parentIdentity | Add-Member -NotePropertyName microsoftSigned -NotePropertyValue ($parentSignature.Status -eq 'Valid' -and $parentSignature.SignerCertificate.Subject -match 'O=Microsoft Corporation(?:,|$)')
$scheduleService = Get-CimInstance Win32_Service -Filter "Name='Schedule'" -ErrorAction Stop
if (!(Test-TaskSchedulerAncestry $taskIdentity $parentIdentity $scheduleService (Join-Path $env:SystemRoot 'System32'))) {
    throw 'TASK_OWNER_INVALID: Scheduler parent identity is not established; direct Desktop/tool launch is not accepted.'
}
# A second owner gate closes the controller->task launch race. Host retains its own mutex.
$created = $false
$gate = New-Object Threading.Mutex($true,"Local\CodexlessTaskOwner-$UserSid",[ref]$created)
if (!$created) { $gate.Dispose(); exit 0 }
$receiptFile = Join-Path $definition.LauncherDirectory 'task-owner.json'
$identity = $null
$ownerEstablished = $false
$cleanupCompleted = $false
try {
    $state = Get-HouseholdRuntimeState $definition
    if ($state.taskState -ne 'Running') { throw 'TASK_OWNER_INVALID: This wrapper must be launched by its registered task.' }
    Assert-HouseholdTaskIdentity (Export-ScheduledTask -TaskName $definition.Name -TaskPath '\' -ErrorAction Stop) $definition
    if ($state.cleanupRequired -or (Test-HouseholdOwnershipEvidence $definition.LauncherDirectory)) {
        Invoke-WindowsPriorBootRecovery $definition
        $state = Get-HouseholdRuntimeState $definition
        if ($state.cleanupRequired -or (Test-HouseholdOwnershipEvidence $definition.LauncherDirectory)) { throw 'HOUSEHOLD_CLEANUP_DEGRADED: Prior ownership evidence requires verified recovery before a new task owner.' }
    }
    if ($state.hostPresent -or $state.listenerPresent -or $state.tunnelPresent) { throw 'HOUSEHOLD_MIGRATION_REQUIRED: Existing processes were not adopted.' }
    $identity = $taskIdentity
    $receipt = [ordered]@{ version=1; pid=$PID; createdAt=$identity.createdAt; userSid=$UserSid; taskName=$definition.Name; hostScript=$definition.HostScript; launcherDirectory=$definition.LauncherDirectory }
    $temp = "$receiptFile.$PID.tmp"
    $receipt | ConvertTo-Json | Set-Content -LiteralPath $temp -Encoding utf8
    Move-Item -LiteralPath $temp -Destination $receiptFile -Force
    $ownerEstablished = $true
    # Run synchronously; Task Scheduler owns the long-lived supervisor, not a starter process.
    & (Join-Path $PSScriptRoot 'Household-Host.ps1') -LauncherDirectory $definition.LauncherDirectory
    # Keep unexpected supervisor exit visible to Task Scheduler.
    if (!(Test-Path -LiteralPath (Join-Path $definition.LauncherDirectory 'stop.flag'))) { throw 'HOUSEHOLD_HOST_EXITED: Supervisor exited without a requested stop.' }
    $cleanupCompleted = $true
} catch {
    $failure = $_
    if ($ownerEstablished) {
        try { Write-HouseholdCleanupState $definition.LauncherDirectory 'task-host' $PID }
        catch { Write-Error 'HOUSEHOLD_CLEANUP_STATE_WRITE_FAILED: Ownership receipts were retained.' -ErrorAction Continue }
    }
    Write-Error -Message $failure.Exception.Message -ErrorAction Continue
    exit 1
} finally {
    try { Complete-HouseholdOwnerTracking $definition.LauncherDirectory $identity $cleanupCompleted }
    finally { $gate.ReleaseMutex(); $gate.Dispose() }
}
