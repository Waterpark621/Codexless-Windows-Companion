param(
    [Parameter(Mandatory=$true)][string]$LauncherDirectory,
    [string]$DisposableInstanceId,
    [Parameter(Mandatory=$true)]$TaskDefinition
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MutationLock.psm1')
if(![string]::IsNullOrWhiteSpace($DisposableInstanceId) -and $DisposableInstanceId -cnotmatch '^[0-9a-f]{32}$'){
    throw 'HOUSEHOLD_TEST_INSTANCE_INVALID'
}
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'CompanionRuntime.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'PrivateConsole.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'UserSessionTask.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'VerifiedTunnel.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'GenerationIdentity.psm1') -Force

$script:HostPidPath=Join-Path $LauncherDirectory 'host.pid'
$script:CodexlessPidPath=Join-Path $LauncherDirectory 'codexless.pid'
$script:StopFlagPath=Join-Path $LauncherDirectory 'stop.flag'
$script:consoleReceiptPath=Join-Path $LauncherDirectory 'codexless-console-owner.json'
$script:consoleHelperPath=Join-Path $PSScriptRoot 'Signal-PrivateConsole.ps1'
$script:SettingsPath=Join-Path $LauncherDirectory 'settings.json'
$script:InitialSettingsText=[IO.File]::ReadAllText($script:SettingsPath)
$script:InitialConfig=Get-CompanionConfig $LauncherDirectory
$script:InitialReleaseBuildId=[string]$script:InitialConfig.release.buildId
$script:InitialGenerationContract=Get-CompanionGenerationContract $script:InitialConfig
$generationOwner=Get-Content -LiteralPath (Join-Path $LauncherDirectory 'task-owner.json') -Raw | ConvertFrom-Json
Assert-CompanionGenerationContract $generationOwner.generationContract $script:InitialConfig
$script:HouseholdWorkingDirectory=[string]$script:InitialConfig.projectPath

function Get-LauncherConfig {
    $currentText=[IO.File]::ReadAllText($script:SettingsPath)
    if ($currentText -cne $script:InitialSettingsText) { throw 'HOUSEHOLD_SETTINGS_CHANGED: Stop the Companion before changing settings.' }
    $cfg=Get-CompanionConfig $LauncherDirectory
    Assert-CompanionGenerationContract $script:InitialGenerationContract $cfg
    if ([string]$cfg.release.buildId -cne $script:InitialReleaseBuildId) { throw 'HOUSEHOLD_RELEASE_CHANGED: Stop the Companion before changing the Codexless release.' }
    $cfg
}

function Write-LauncherLog {
    param([string]$Message)
    Write-CompanionLog $LauncherDirectory $Message
}

if ($null -ne (Get-HouseholdCleanupState $LauncherDirectory)) { throw 'HOUSEHOLD_CLEANUP_DEGRADED: Verified recovery is required before startup.' }

function Initialize-HouseholdHostTracking {
    Remove-Item -LiteralPath $script:StopFlagPath -Force -ErrorAction SilentlyContinue
    $PID | Set-Content -LiteralPath $script:HostPidPath -Encoding ascii
}

$initialLease=Enter-CompanionHostLease $TaskDefinition Startup
try {
if (!(Test-Path -LiteralPath (Join-Path $LauncherDirectory 'logs'))) { New-Item -ItemType Directory -Path (Join-Path $LauncherDirectory 'logs') -Force | Out-Null }
$created = $false
$hostMutexName=if([string]::IsNullOrWhiteSpace($DisposableInstanceId)){'Local\CodexlessLocalLauncherHost'}else{"Local\CodexlessLocalLauncherHost-Test-$DisposableInstanceId"}
$mutex = New-Object Threading.Mutex($true,$hostMutexName,[ref]$created)
if (!$created) { $mutex.Dispose(); exit 0 }
Initialize-HouseholdHostTracking
$script:HouseholdStartedAt=[DateTime]::UtcNow
}finally{$initialLease.Dispose()}

function Test-HouseholdStopRequested { Test-Path -LiteralPath $script:StopFlagPath }
function Get-HouseholdTime { [DateTime]::UtcNow }

function Start-CodexlessIfNeeded($cfg) {
    if (Test-HouseholdStopRequested) { return $false }
    if (Test-TcpPort -Port ([int]$cfg.port)) {
        if (!(Test-Path -LiteralPath $script:consoleReceiptPath)) { throw 'HOUSEHOLD_FOREIGN_LISTENER: Existing listener is not owned by this supervisor.' }
        if (!(Test-PrivateConsoleListener $script:consoleReceiptPath ([int]$cfg.port))) { throw 'HOUSEHOLD_CONSOLE_OWNER_INVALID: Listener ancestry is not established for the exact console receipt.' }
        if (!(Test-CodexlessReady $cfg)) {
            Write-LauncherLog 'Owned Codexless listener is present but readiness has not been established.'
            return $false
        }
        return $true
    }
    if (Test-Path -LiteralPath $script:consoleReceiptPath) {
        Write-LauncherLog 'Household degraded: prior console receipt remains; no duplicate runtime was started.'
        return $false
    }

    $command=Get-CodexlessPrivateConsoleCommand $cfg
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    Write-LauncherLog 'Starting Codexless HTTP from the qualified release in an owned hidden private console.'
    $receipt=Start-PrivateConsoleProcess (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $encoded" $cfg.projectPath $script:consoleReceiptPath
    $receipt.pid | Set-Content -LiteralPath $script:CodexlessPidPath -Encoding ascii
    for ($attempt=0; $attempt -lt 40; $attempt++) {
        if (Test-HouseholdStopRequested) { return $false }
        Start-Sleep -Milliseconds 500
        if (Test-TcpPort -Port ([int]$cfg.port)) {
            if (!(Test-PrivateConsoleListener $script:consoleReceiptPath ([int]$cfg.port))) { throw 'HOUSEHOLD_FOREIGN_LISTENER: Readiness requires verified listener ancestry.' }
            if (Test-CodexlessReady $cfg) {
                Write-LauncherLog "Codexless HTTP is ready on port $($cfg.port)."
                return $true
            }
        }
    }
    Write-LauncherLog 'Codexless HTTP did not become ready within 20 seconds; the existing owned console is retained.'
    $false
}

function Start-TunnelIfNeeded($cfg,$tunnel) {
    if (Test-HouseholdStopRequested) { return $false }
    if (!(Test-PrivateConsoleListener $script:consoleReceiptPath ([int]$cfg.port))) {
        Write-LauncherLog "Tunnel '$($tunnel.alias)' was not connected: listener ancestry is unverified."
        return $false
    }
    if (!(Test-CodexlessReady $cfg)) {
        Write-LauncherLog "Tunnel '$($tunnel.alias)' was not connected: Codexless readiness is unverified."
        return $false
    }
    if (Test-TunnelGenerationUnlaunched $cfg $tunnel) {
        $plain=Get-PlainRuntimeKey $tunnel
        try { return (Start-OwnedTunnel $LauncherDirectory $cfg $tunnel $plain) }
        finally { $plain=$null }
    }
    if (Test-TunnelReady $cfg $tunnel) {
        $readyStatus=Get-TunnelStatus $cfg $tunnel
        try {
            if (Test-OwnedTunnel $LauncherDirectory $cfg $tunnel $readyStatus) { return $true }
        } catch { }
        Write-LauncherLog 'Existing ready tunnel is not proven Companion-owned; it was not adopted.'
        return $false
    }
    if (!(Test-TcpPort -Port ([int]$cfg.port))) { return $false }
    $status=Get-TunnelStatus $cfg $tunnel
    if ($null -eq $status -or !$status.PSObject.Properties['process_running'] -or $status.process_running -isnot [bool]) {
        Write-LauncherLog "Tunnel '$($tunnel.alias)' state is unavailable; no competing client was started."
        return $false
    }
    if ($status.process_running -eq $true) {
        try {
            if (Test-OwnedTunnel $LauncherDirectory $cfg $tunnel $status) {
                Write-LauncherLog 'Companion-owned tunnel is alive but degraded; waiting for official client recovery.'
                return $false
            }
        } catch { }
        Write-LauncherLog 'Existing tunnel process is not proven Companion-owned; it was not adopted.'
        return $false
    }
    $previous=Open-OwnedTunnelLifetime $LauncherDirectory $cfg $tunnel $status
    if($null -ne $previous){$previous.lease.Dispose();throw 'TUNNEL_LIFETIME_MISMATCH'}
    Write-LauncherLog 'Tunnel generation remains fenced; explicit recovery is required before any replacement.'
    $false
}

function Stop-HouseholdTunnel($cfg,$tunnel) {
    # Official runtimes stop only, through the verified bounded lifecycle.
    Stop-OwnedTunnel $LauncherDirectory $cfg $tunnel
}

function Stop-ManagedPieces($cfg) {
    $script:HouseholdStage='tunnel-stop'
    Write-LauncherLog 'Stopping Companion-managed tunnel clients through their official command.'
    foreach ($tunnel in @(Get-ConfiguredTunnels $cfg -IncludeDisabled)) { Stop-HouseholdTunnel $cfg $tunnel }
    $script:HouseholdStage='tunnel-wait'
    $deadline=(Get-HouseholdTime).AddSeconds(30)
    do {
        $alive=$false
        foreach ($tunnel in @(Get-ConfiguredTunnels $cfg -IncludeDisabled)) {
            $status=Get-TunnelStatus $cfg $tunnel
            if ($null -eq $status -or !$status.PSObject.Properties['process_running'] -or $status.process_running -isnot [bool] -or $status.process_running -eq $true) { $alive=$true }
        }
        if (!$alive) { break }
        if ((Get-HouseholdTime) -ge $deadline) { throw 'HOUSEHOLD_TUNNEL_STOP_TIMEOUT: No wrapper stop or duplicate start was attempted.' }
        Start-Sleep -Milliseconds 250
    } while ($true)
    $script:HouseholdStage='console-stop'
    if (Test-Path -LiteralPath $script:consoleReceiptPath) { Request-PrivateConsoleStop $script:consoleReceiptPath $script:consoleHelperPath 60 }
    $script:HouseholdStage='listener-check'
    if (Test-TcpPort -Port ([int]$cfg.port)) { throw 'HOUSEHOLD_STOP_LISTENER_REMAINS: No force termination or replacement was attempted.' }
    Remove-Item -LiteralPath $script:CodexlessPidPath -Force -ErrorAction SilentlyContinue
}

function Invoke-HouseholdHostBody {
    $script:HouseholdStage='supervision'
    try {
        Write-LauncherLog "Task-owned Host started. PID=$PID"
        while (!(Test-HouseholdStopRequested)) {
            $cycleLease=$null
            try{$cycleLease=Enter-CompanionHostLease $TaskDefinition Startup}catch{
                if($_.Exception.Message -like 'MUTATION_CONCURRENT_OPERATION*' -or $_.Exception.Message -eq 'MUTATION_TRANSACTION_FENCED'){Start-Sleep -Milliseconds 250;continue}
                throw
            }
            try {
            $cfg=Get-LauncherConfig
            $ownedReady=Start-CodexlessIfNeeded $cfg
            if ($ownedReady) {
                foreach ($tunnel in @(Get-ConfiguredTunnels $cfg)) {
                    if (Test-HouseholdStopRequested) { break }
                    $null=Start-TunnelIfNeeded $cfg $tunnel
                }
            }
            }finally{$cycleLease.Dispose()}
            for ($wait=0; $wait -lt 15; $wait++) { if (Test-HouseholdStopRequested) { break }; Start-Sleep -Seconds 2 }
        }
        $stopLease=$null
        $deadline=[DateTime]::UtcNow.AddSeconds(120)
        while(!$stopLease){
            try{$stopLease=Enter-CompanionHostLease $TaskDefinition Shutdown}catch{
                if($_.Exception.Message -notlike 'MUTATION_CONCURRENT_OPERATION*' -or [DateTime]::UtcNow -ge $deadline){throw}
                Start-Sleep -Milliseconds 100
            }
        }
        try{Stop-ManagedPieces (Get-LauncherConfig)}finally{$stopLease.Dispose()}
        Write-LauncherLog 'Task-owned Host stopped normally after graceful household close.'
    } catch {
        $failure=$_
        try { $failureLease=Enter-CompanionHostLease $TaskDefinition Shutdown;try{Write-HouseholdCleanupState $LauncherDirectory $script:HouseholdStage $PID}finally{$failureLease.Dispose()} }
        catch { Write-LauncherLog 'HOUSEHOLD_CLEANUP_STATE_WRITE_FAILED: Ownership receipts were retained.' }
        Write-LauncherLog "Task-owned Host entered degraded state during stage '$script:HouseholdStage'."
        throw $failure
    }
}

try {
    Invoke-HouseholdHostBody
} finally {
    try { $mutex.ReleaseMutex() } catch {}
    $mutex.Dispose()
}
