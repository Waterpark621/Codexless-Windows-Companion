param(
    [Parameter(Mandatory=$true)] [string]$LauncherDirectory,
    [Parameter(Mandatory=$true)] [string]$UserSid,
    [string]$TaskName,
    [string]$TransactionId,
    [string]$GenerationId
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MutationLock.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'UserSessionTask.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'WindowsTaskAdapter.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'CompanionRuntime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'GenerationIdentity.psm1') -Force -DisableNameChecking
if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -cne $UserSid) { throw 'TASK_OWNER_INVALID' }
Assert-HouseholdPrincipal $UserSid (Get-Acl -LiteralPath (Join-Path $LauncherDirectory 'settings.json') -ErrorAction Stop).GetOwner([Security.Principal.SecurityIdentifier]).Value
$definitionParameters=@{
    UserSid=$UserSid
    LauncherDirectory=$LauncherDirectory
    HostScript=$PSCommandPath
    PowerShellExe=(Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
}
if (![string]::IsNullOrWhiteSpace($TaskName)) { $definitionParameters.TaskName=$TaskName }
$transactionBound=![string]::IsNullOrWhiteSpace($TransactionId) -or ![string]::IsNullOrWhiteSpace($GenerationId)
if ($transactionBound) {
    if ($TransactionId -cnotmatch '^[0-9a-f]{32}$' -or $GenerationId -cnotmatch '^[0-9a-f]{32}$') { throw 'TASK_TRANSACTION_INVALID' }
    $ownerPath=Join-Path $LauncherDirectory 'native-adapter-owner.json'
    if (!(Test-Path -LiteralPath $ownerPath -PathType Leaf) -or (Get-Item -LiteralPath $ownerPath -Force).Length -gt 32768) { throw 'TASK_TRANSACTION_OWNER_MISSING' }
    try { $nativeOwner=Get-Content -LiteralPath $ownerPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch { throw 'TASK_TRANSACTION_OWNER_INVALID' }
    if ($nativeOwner.version -notin @(1,2) -or $nativeOwner.state -cne 'active' -or $nativeOwner.transactionId -cne $TransactionId -or
        $nativeOwner.generationId -cne $GenerationId -or $nativeOwner.payloadSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'TASK_TRANSACTION_OWNER_INVALID' }
    $definitionParameters.TransactionId=$TransactionId
    $definitionParameters.GenerationId=$GenerationId
}
$definition = New-HouseholdTaskDefinition @definitionParameters
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
# Production keeps the historical per-user singleton. The strict transaction-bound
# disposable namespace is isolated so acceptance can coexist with an untouched live
# household without weakening or renaming the production gate.
$disposableTransaction = ($transactionBound -and $TaskName -cmatch '^Codexless-NativeAdapter-Test-([0-9a-f]{32})$')
$disposableId = if($disposableTransaction){$Matches[1]}else{$null}
$taskOwnerMutexName = if($disposableTransaction){"Local\CodexlessTaskOwner-Test-$disposableId"}else{"Local\CodexlessTaskOwner-$UserSid"}
$created = $false
$gate = New-Object Threading.Mutex($true,$taskOwnerMutexName,[ref]$created)
if (!$created) { $gate.Dispose(); exit 0 }
$receiptFile = Join-Path $definition.LauncherDirectory 'task-owner.json'
$identity = $null
$ownerEstablished = $false
$cleanupCompleted = $false
try {
    $admission=Enter-CompanionHostLease $definition Startup
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
    $generationContract=Get-CompanionGenerationContract (Get-CompanionConfig $definition.LauncherDirectory)
    $receipt = [ordered]@{ version=1; pid=$PID; createdAt=$identity.createdAt; userSid=$UserSid; taskName=$definition.Name; hostScript=$definition.HostScript; launcherDirectory=$definition.LauncherDirectory; generationContract=$generationContract }
    $temp = "$receiptFile.$PID.tmp"
    $receipt | ConvertTo-Json | Set-Content -LiteralPath $temp -Encoding utf8
    Move-Item -LiteralPath $temp -Destination $receiptFile -Force
    $ownerEstablished = $true
    }finally{$admission.Dispose()}
    # Run synchronously; Task Scheduler owns the long-lived supervisor, not a starter process.
    $hostParameters=@{LauncherDirectory=$definition.LauncherDirectory;TaskDefinition=$definition}
    if($disposableTransaction){$hostParameters.DisposableInstanceId=$disposableId}
    & (Join-Path $PSScriptRoot 'Household-Host.ps1') @hostParameters
    # Keep unexpected supervisor exit visible to Task Scheduler.
    if (!(Test-Path -LiteralPath (Join-Path $definition.LauncherDirectory 'stop.flag'))) { throw 'HOUSEHOLD_HOST_EXITED: Supervisor exited without a requested stop.' }
    $cleanupCompleted = $true
} catch {
    $failure = $_
    if ($ownerEstablished) {
        try { $cleanupLease=Enter-CompanionHostLease $definition Shutdown;try{Write-HouseholdCleanupState $definition.LauncherDirectory 'task-host' $PID}finally{$cleanupLease.Dispose()} }
        catch { Write-Error 'HOUSEHOLD_CLEANUP_STATE_WRITE_FAILED: Ownership receipts were retained.' -ErrorAction Continue }
    }
    $message=$failure.Exception.Message
    if($message -clike 'HOUSEHOLD_CLEANUP_DEGRADED:*' -and $failure.Exception.Data.Contains('RecoveryReasonCode')) {
        $message+=' Reason: '+(Get-PriorBootRecoveryReason $failure)
        try { Write-CompanionLog $definition.LauncherDirectory ('Prior-boot recovery refused. Reason: '+(Get-PriorBootRecoveryReason $failure)) }
        catch { Write-Error 'HOUSEHOLD_RECOVERY_DIAGNOSTIC_WRITE_FAILED' -ErrorAction Continue }
    }
    Write-Error -Message $message -ErrorAction Continue
    exit 1
} finally {
    try {
        if($ownerEstablished -and $cleanupCompleted){
            $cleanupLease=Enter-CompanionHostLease $definition Shutdown
            try{Complete-HouseholdOwnerTracking $definition.LauncherDirectory $identity $cleanupCompleted}finally{$cleanupLease.Dispose()}
        }
    }
    finally { $gate.ReleaseMutex(); $gate.Dispose() }
}
