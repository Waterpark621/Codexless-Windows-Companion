param([Parameter(Mandatory=$true)][string]$LauncherDirectory)
$ErrorActionPreference = 'Stop'
# Preserve the current launcher's module-import repair and all Core configuration/DPAPI behavior.
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1') -Force -ErrorAction Stop
$corePath = Join-Path $LauncherDirectory 'Core.ps1'
if ((Get-FileHash -LiteralPath $corePath -Algorithm SHA256).Hash -cne '4BE5AA39D49CB78C93F8146BADDEACDBE8CECB0BED4B1963E2539D15B9E1D88B') { throw 'HOUSEHOLD_CORE_VERSION_UNKNOWN: Review changed Core before using this source stage.' }
. $corePath
# Preserve the already-authorized working directory of the reviewed installed launcher.
# A scheduler default directory must not silently change Codex's project authority.
$legacyHostPath=Join-Path $LauncherDirectory 'Host.ps1'
if((Get-FileHash -LiteralPath $legacyHostPath).Hash -cne 'E7BEA32679952DFB1CB7B5D1A8642AB9E58369CF9B1342BB3911314A1DF6F633'){throw 'HOUSEHOLD_HOST_VERSION_UNKNOWN: Review original launcher working directory first.'}
$legacyTokens=$null;$legacyErrors=$null
$legacyAst=[Management.Automation.Language.Parser]::ParseFile($legacyHostPath,[ref]$legacyTokens,[ref]$legacyErrors)
$legacyParameters=@($legacyAst.FindAll({param($node) $node -is [Management.Automation.Language.CommandParameterAst] -and $node.ParameterName -ceq 'WorkingDirectory'},$true))
if($legacyErrors.Count -or $legacyParameters.Count -ne 1){throw 'HOUSEHOLD_WORKING_DIRECTORY_UNPROVEN'}
$elements=$legacyParameters[0].Parent.CommandElements;$index=$elements.IndexOf($legacyParameters[0])
if($elements[$index+1] -isnot [Management.Automation.Language.StringConstantExpressionAst]){throw 'HOUSEHOLD_WORKING_DIRECTORY_UNPROVEN'}
$script:HouseholdWorkingDirectory=$elements[$index+1].Value
if(!(Test-Path -LiteralPath $script:HouseholdWorkingDirectory -PathType Container)){throw 'HOUSEHOLD_WORKING_DIRECTORY_UNAVAILABLE'}
Import-Module (Join-Path $PSScriptRoot 'PrivateConsole.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'UserSessionTask.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'VerifiedTunnel.psm1') -Force -DisableNameChecking
$consoleReceiptPath = Join-Path $LauncherDirectory 'codexless-console-owner.json'
$consoleHelperPath = Join-Path $PSScriptRoot 'Signal-PrivateConsole.ps1'
$verifiedHouseholdPath = Join-Path $PSScriptRoot 'Start-VerifiedHousehold.ps1'
if ($null -ne (Get-HouseholdCleanupState $LauncherDirectory)) { throw 'HOUSEHOLD_CLEANUP_DEGRADED: Verified recovery is required before startup.' }
function Initialize-HouseholdHostTracking {
    # A controller can authorize Stop only after host.pid is published. Clear stale flags first.
    Remove-Item -LiteralPath $script:StopFlagPath -Force -ErrorAction SilentlyContinue
    $PID | Set-Content -LiteralPath $script:HostPidPath -Encoding ascii
}
if (!(Test-Path -LiteralPath $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
$created = $false
$mutex = New-Object Threading.Mutex($true,'Local\CodexlessLocalLauncherHost',[ref]$created)
if (!$created) { $mutex.Dispose(); exit 0 }
Initialize-HouseholdHostTracking
$script:HouseholdStartedAt=[DateTime]::UtcNow

function Test-HouseholdStopRequested { Test-Path -LiteralPath $script:StopFlagPath }
function Get-HouseholdTime { [DateTime]::UtcNow }

function Start-CodexlessIfNeeded($cfg) {
    if (Test-HouseholdStopRequested) { return $false }
    if (Test-TcpPort -Port ([int]$cfg.port)) {
        if (!(Test-Path -LiteralPath $consoleReceiptPath)) { throw 'HOUSEHOLD_FOREIGN_LISTENER: Existing listener is not owned by this staged supervisor.' }
        if (!(Test-PrivateConsoleListener $consoleReceiptPath ([int]$cfg.port))) { throw 'HOUSEHOLD_CONSOLE_OWNER_INVALID: Listener ancestry is not established for the exact console receipt.' }
        return $true
    }
    if (Test-Path -LiteralPath $consoleReceiptPath) {
        # A dead wrapper does not establish that its MCP/Browser descendants finished closing.
        Write-LauncherLog 'Household degraded: prior console receipt remains; no duplicate wrapper was started.'
        return $false
    }
    if (!(Test-Path -LiteralPath $cfg.codexlessHttp)) { Write-LauncherLog "Codexless HTTP launcher missing: $($cfg.codexlessHttp)"; return $false }
    $quotedLauncher = $cfg.codexlessHttp.Replace("'","''")
    $quotedShim = $verifiedHouseholdPath.Replace("'","''")
    $quotedDirectory = $LauncherDirectory.Replace("'","''")
    # Keep native stdio in this private console. In Windows PowerShell 5.1, pipeline
    # stderr redirection turns ordinary Node logs into terminating wrapper errors.
    $command = "& '$quotedShim' -LauncherDirectory '$quotedDirectory' -VerifiedWrapper '$quotedLauncher'"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    Write-LauncherLog 'Starting Codexless HTTP in an owned hidden private console.'
    $receipt = Start-PrivateConsoleProcess (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $encoded" $script:HouseholdWorkingDirectory $consoleReceiptPath
    $receipt.pid | Set-Content -LiteralPath $script:CodexlessPidPath -Encoding ascii
    for ($attempt=0; $attempt -lt 40; $attempt++) {
        if (Test-HouseholdStopRequested) { return $false }
        Start-Sleep -Milliseconds 500
        if (Test-TcpPort -Port ([int]$cfg.port)) {
            if (!(Test-PrivateConsoleListener $consoleReceiptPath ([int]$cfg.port))) { throw 'HOUSEHOLD_FOREIGN_LISTENER: Readiness requires verified listener ancestry.' }
            Write-LauncherLog "Codexless HTTP is listening on port $($cfg.port)."; return $true
        }
    }
    Write-LauncherLog 'Codexless HTTP did not become ready within 20 seconds; the existing owned console is retained.'
    $false
}

function Start-TunnelIfNeeded($cfg,$tunnel) {
    if (Test-HouseholdStopRequested) { return $false }
    if (!(Test-PrivateConsoleListener $consoleReceiptPath ([int]$cfg.port))) {
        Write-LauncherLog "Tunnel '$($tunnel.alias)' was not connected: listener ancestry is unverified."
        return $false
    }
    if (Test-TunnelReady $cfg $tunnel) {
        Record-OwnedTunnel $LauncherDirectory $cfg $tunnel (Get-TunnelStatus $cfg $tunnel) $script:HouseholdStartedAt
        return $true
    }
    if (!(Test-TcpPort -Port ([int]$cfg.port))) { return $false }
    $status = Get-TunnelStatus $cfg $tunnel
    if ($null -eq $status -or !$status.PSObject.Properties['process_running'] -or $status.process_running -isnot [bool]) {
        Write-LauncherLog "Tunnel '$($tunnel.alias)' state is unavailable; no competing client was started."
        return $false
    }
    if ($null -ne $status -and $status.process_running -eq $true) {
        Record-OwnedTunnel $LauncherDirectory $cfg $tunnel $status $script:HouseholdStartedAt
        # The official client owns reconnect while alive. Never start a second alias client.
        Write-LauncherLog "Tunnel '$($tunnel.alias)' is alive but degraded; waiting for official client recovery."
        return $false
    }
    $previous=Open-OwnedTunnelLifetime $LauncherDirectory $cfg $tunnel $status
    if($null -ne $previous){$previous.lease.Dispose();throw 'TUNNEL_LIFETIME_MISMATCH'}
    try {
        $key = Get-PlainRuntimeKey $tunnel
        Write-LauncherLog "Connecting existing tunnel alias '$($tunnel.alias)'."
        $result = Connect-TunnelRuntime $cfg $tunnel $key
        $key = $null
        $connected=Get-TunnelStatus $cfg $tunnel
        if($null -ne $connected -and $connected.PSObject.Properties['process_running'] -and $connected.process_running -eq $true){Record-OwnedTunnel $LauncherDirectory $cfg $tunnel $connected $script:HouseholdStartedAt}
        if ($result.Trim()) { Write-LauncherLog "tunnel-client[$($tunnel.alias)]: $($result.Trim())" }
    } catch { Write-LauncherLog "Tunnel '$($tunnel.alias)' connect failed: $($_.Exception.Message)"; return $false }
    for ($attempt=0; $attempt -lt 20; $attempt++) {
        if (Test-HouseholdStopRequested) { return $false }
        Start-Sleep -Milliseconds 750
        if (Test-TunnelReady $cfg $tunnel) {
            Record-OwnedTunnel $LauncherDirectory $cfg $tunnel (Get-TunnelStatus $cfg $tunnel) $script:HouseholdStartedAt
            Write-LauncherLog "Tunnel '$($tunnel.alias)' is ready."; return $true
        }
    }
    Write-LauncherLog "Tunnel '$($tunnel.alias)' remains degraded after 15 seconds; host will check again."
    $false
}

function Stop-HouseholdTunnel($cfg,$tunnel) {
    $binding=Open-OwnedTunnelLifetime $LauncherDirectory $cfg $tunnel (Get-TunnelStatus $cfg $tunnel)
    if($null -eq $binding){return}
    try{
        # Hold the exact process object across the supported PID-based command, preventing PID reuse.
        & $cfg.tunnelExe runtimes stop $tunnel.alias 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "HOUSEHOLD_TUNNEL_STOP_FAILED: $($tunnel.alias)" }
        Complete-OwnedTunnelStop $binding
    }finally{$binding.lease.Dispose()}
}

function Stop-ManagedPieces($cfg) {
    $script:HouseholdStage = 'tunnel-stop'
    Write-LauncherLog 'Stopping launcher-managed tunnel clients through their official command.'
    foreach ($tunnel in @(Get-ConfiguredTunnels $cfg -IncludeDisabled)) {
        Stop-HouseholdTunnel $cfg $tunnel
    }
    $script:HouseholdStage = 'tunnel-wait'
    $deadline = (Get-HouseholdTime).AddSeconds(30)
    do {
        $alive = $false
        foreach ($tunnel in @(Get-ConfiguredTunnels $cfg -IncludeDisabled)) {
            $status = Get-TunnelStatus $cfg $tunnel
            if ($null -eq $status -or !$status.PSObject.Properties['process_running'] -or $status.process_running -isnot [bool] -or $status.process_running -eq $true) { $alive = $true }
        }
        if (!$alive) { break }
        if ((Get-HouseholdTime) -ge $deadline) { throw 'HOUSEHOLD_TUNNEL_STOP_TIMEOUT: No wrapper stop or duplicate start was attempted.' }
        Start-Sleep -Milliseconds 250
    } while ($true)
    $script:HouseholdStage = 'console-stop'
    if (Test-Path -LiteralPath $consoleReceiptPath) { Request-PrivateConsoleStop $consoleReceiptPath $consoleHelperPath 60 }
    $script:HouseholdStage = 'listener-check'
    if (Test-TcpPort -Port ([int]$cfg.port)) { throw 'HOUSEHOLD_STOP_LISTENER_REMAINS: No force termination or replacement was attempted.' }
    Remove-Item -LiteralPath $script:CodexlessPidPath -Force -ErrorAction SilentlyContinue
}

function Invoke-HouseholdHostBody {
    $script:HouseholdStage = 'supervision'
    try {
        Write-LauncherLog "Task-owned Host started. PID=$PID"
        while (!(Test-HouseholdStopRequested)) {
            $cfg = Get-LauncherConfig
            $ownedReady = Start-CodexlessIfNeeded $cfg
            if ($ownedReady) {
                foreach ($tunnel in @(Get-ConfiguredTunnels $cfg)) {
                    if (Test-HouseholdStopRequested) { break }
                    $null = Start-TunnelIfNeeded $cfg $tunnel
                }
            }
            for ($wait=0; $wait -lt 15; $wait++) { if (Test-HouseholdStopRequested) { break }; Start-Sleep -Seconds 2 }
        }
        Stop-ManagedPieces (Get-LauncherConfig)
        Write-LauncherLog 'Task-owned Host stopped normally after graceful household close.'
    } catch {
        $failure = $_
        try { Write-HouseholdCleanupState $LauncherDirectory $script:HouseholdStage $PID }
        catch { Write-LauncherLog 'HOUSEHOLD_CLEANUP_STATE_WRITE_FAILED: Ownership receipts were retained.' }
        Write-LauncherLog "Task-owned Host fatal/degraded: $($failure.Exception.Message)"
        throw $failure
    }
}

try {
    Invoke-HouseholdHostBody
} finally {
    # Task-Host clears matching owner tracking only after confirmed successful cleanup.
    try { $mutex.ReleaseMutex() } catch {}
    $mutex.Dispose()
}
