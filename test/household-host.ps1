$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$scriptPath = Join-Path $PSScriptRoot '..\Household-Host.ps1'
$tokens=$null; $errors=$null
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$errors)
if ($errors.Count -ne 0) { throw ($errors | Out-String) }
# Load function definitions only. Never run the Host's live top-level code.
foreach ($function in $ast.FindAll({param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) {
    . ([scriptblock]::Create($function.Extent.Text))
}
$results = [Collections.Generic.List[string]]::new()
function Assert-True([bool]$Value,[string]$Message='assertion failed') { if (!$Value) { throw $Message } }
function Assert-Throws([scriptblock]$Body,[string]$Code) { try { & $Body | Out-Null } catch { if ($_.Exception.Message.Contains($Code)) { return }; throw }; throw "Expected $Code" }
function Test([string]$Name,[scriptblock]$Body) { & $Body; $results.Add($Name); Write-Output "PASS $Name" }
$mock = [pscustomobject]@{ready=$false;runtimeReady=$true;listening=$true;status=[pscustomobject]@{process_running=$false};connects=0;logs=[Collections.Generic.List[string]]::new();receiptPresent=$false;starts=0;ownerValid=$true;stopRequested=$false;publishStop=$false;trackingEvents=[Collections.Generic.List[string]]::new();now=[DateTime]'2026-10-03T00:00:00Z';stopError='';consoleError='';consoleStops=0;writerFails=$false;cleanupStages=[Collections.Generic.List[string]]::new();removes=[Collections.Generic.List[string]]::new()}
function Test-TunnelReady { param($cfg,$tunnel) $mock.ready }
function Test-TcpPort { param([int]$Port) $mock.listening }
function Test-CodexlessReady { param($cfg) $mock.runtimeReady }
function Get-CodexlessPrivateConsoleCommand { param($cfg) 'fixture-direct-launch:'+([string]$cfg.port) }
function Get-TunnelStatus { param($cfg,$tunnel) $mock.status }
function Get-PlainRuntimeKey { param($tunnel) 'fixture-key-not-a-credential' }
function Record-OwnedTunnel { param($launcher,$cfg,$tunnel,$status,$started) }
function Open-OwnedTunnelLifetime { param($launcher,$cfg,$tunnel,$status) $null }
function Connect-TunnelRuntime { param($cfg,$tunnel,[string]$key) $mock.connects++;$mock.ready=$true; 'connected' }
function Write-LauncherLog { param([string]$Message) $mock.logs.Add($Message) }
function Start-Sleep { param([int]$Milliseconds,[int]$Seconds) $mock.now=$mock.now.AddMilliseconds($Milliseconds).AddSeconds($Seconds) }
function Test-Path { param([string]$LiteralPath) if ($LiteralPath -eq 'receipt') { $mock.receiptPresent } elseif ($LiteralPath -eq 'stop.flag') { $mock.stopRequested } else { $true } }
function Get-Content { param([string]$LiteralPath,[switch]$Raw) '{"pid":101}' }
function Get-ConsoleProcessIdentity { param([int]$ProcessId) [pscustomobject]@{pid=$ProcessId} }
function Test-PrivateConsoleReceipt { param($receipt,$identity,$sid) $mock.ownerValid }
function Test-PrivateConsoleListener { param($receiptPath,[int]$Port) $mock.ownerValid }
function Start-PrivateConsoleProcess {
    param($Executable,$Arguments,$WorkingDirectory,$ReceiptPath)
    $script:CapturedConsoleArguments=$Arguments
    $script:CapturedWorkingDirectory=$WorkingDirectory
    $mock.starts++;$mock.listening=$true;[pscustomobject]@{pid=102}
}
function Get-HouseholdTime { $mock.now }
function Get-LauncherConfig { $cfg }
function Get-ConfiguredTunnels { param($cfg,[switch]$IncludeDisabled) @($tunnel) }
function Stop-HouseholdTunnel { param($cfg,$tunnel) if ($mock.stopError) { throw $mock.stopError } }
function Request-PrivateConsoleStop { param($receiptPath,$helperPath,[int]$TimeoutSeconds) $mock.consoleStops++;if ($mock.consoleError) { throw $mock.consoleError } }
function Remove-Item { param($LiteralPath,[switch]$Force,$ErrorAction) $mock.removes.Add($LiteralPath);if ($LiteralPath -eq 'stop.flag') {$mock.trackingEvents.Add('remove-stale-stop');$mock.stopRequested=$false} }
function Set-Content { param($LiteralPath,$Encoding) $mock.trackingEvents.Add('publish-owner');if ($mock.publishStop) {$mock.stopRequested=$true} }
function Write-HouseholdCleanupState { param($launcherDirectory,$stage,[int]$ownerPid) if ($mock.writerFails) { throw 'fixture-marker-write-failed' };$mock.cleanupStages.Add($stage) }
$consoleReceiptPath = 'receipt'
$consoleHelperPath = 'helper.ps1'
$LauncherDirectory='fixture'
$script:StopFlagPath='stop.flag'
$script:CodexlessPidPath='wrapper.pid'
$script:HostPidPath='host.pid'
$script:HouseholdStartedAt=[DateTime]'2026-10-03T00:00:00Z'
$script:HouseholdWorkingDirectory='already-authorized-fixture-root'
$cfg=[pscustomobject]@{port=12345;projectPath='already-authorized-fixture-root'}
$tunnel=[pscustomobject]@{alias='fixture'}
Test 'Ready alias is reused without another connect' {
    $mock.ready=$true
    Assert-True (Start-TunnelIfNeeded $cfg $tunnel)
    Assert-True ($mock.connects -eq 0)
}
Test 'Alive degraded alias is left to official reconnect and never duplicated' {
    $mock.ready=$false; $mock.status=[pscustomobject]@{process_running=$true}
    Assert-True (!(Start-TunnelIfNeeded $cfg $tunnel))
    Assert-True ($mock.connects -eq 0)
}
Test 'Unknown alias state does not permit another client' {
    $mock.status=$null
    Assert-True (!(Start-TunnelIfNeeded $cfg $tunnel))
    Assert-True ($mock.connects -eq 0)
}
Test 'Known exited alias restarts once through official connect' {
    $mock.status=[pscustomobject]@{process_running=$false}
    Assert-True (Start-TunnelIfNeeded $cfg $tunnel)
    Assert-True ($mock.connects -eq 1)
    Assert-True (Start-TunnelIfNeeded $cfg $tunnel)
    Assert-True ($mock.connects -eq 1)
}
Test 'Malformed running state never authorizes another tunnel connect' {
    $mock.ready=$false;$before=$mock.connects
    foreach($bad in @([pscustomobject]@{},[pscustomobject]@{process_running='false'})){
        $mock.status=$bad
        Assert-True (!(Start-TunnelIfNeeded $cfg $tunnel))
    }
    Assert-True ($mock.connects -eq $before)
}
Test 'Unowned listener fails closed without adoption' {
    $mock.receiptPresent=$false
    Assert-Throws { Start-CodexlessIfNeeded $cfg } 'HOUSEHOLD_FOREIGN_LISTENER'
    Assert-True ($mock.starts -eq 0)
}
Test 'Existing listener requires the exact console owner' {
    $mock.receiptPresent=$true; $mock.ownerValid=$false
    Assert-Throws { Start-CodexlessIfNeeded $cfg } 'HOUSEHOLD_CONSOLE_OWNER_INVALID'
    $mock.ownerValid=$true
    Assert-True (Start-CodexlessIfNeeded $cfg)
    Assert-True ($mock.starts -eq 0)
}
Test 'Unverified listener blocks even a ready alias before any new tunnel connect' {
    $mock.ready=$true; $mock.ownerValid=$false
    $before=$mock.connects
    Assert-True (!(Start-TunnelIfNeeded $cfg $tunnel))
    Assert-True ($mock.connects -eq $before)
    $mock.ownerValid=$true
}
Test 'Dead or unready wrapper receipt blocks replacement while cleanup is unproven' {
    $mock.listening=$false
    Assert-True (!(Start-CodexlessIfNeeded $cfg))
    Assert-True ($mock.starts -eq 0)
}
Test 'Stop request prevents wrapper or tunnel startup work' {
    $mock.stopRequested=$true
    $beforeStarts=$mock.starts;$beforeConnects=$mock.connects
    Assert-True (!(Start-CodexlessIfNeeded $cfg))
    Assert-True (!(Start-TunnelIfNeeded $cfg $tunnel))
    Assert-True ($mock.starts -eq $beforeStarts -and $mock.connects -eq $beforeConnects)
}
Test 'Stop authorized when ownership is published survives stale-stop cleanup' {
    $mock.stopRequested=$true;$mock.publishStop=$true;$mock.trackingEvents.Clear()
    Initialize-HouseholdHostTracking
    Assert-True ($mock.stopRequested)
    Assert-True (($mock.trackingEvents -join ',') -ceq 'remove-stale-stop,publish-owner')
    $mock.publishStop=$false
}
function Reset-StopFixture {
    $mock.stopRequested=$true;$mock.status=[pscustomobject]@{process_running=$false};$mock.listening=$false;$mock.receiptPresent=$true
    $mock.stopError='';$mock.consoleError='';$mock.consoleStops=0;$mock.writerFails=$false;$mock.cleanupStages.Clear();$mock.removes.Clear()
    $mock.now=[DateTime]'2026-10-03T00:00:00Z'
}
Test 'Normal cooperative stop removes wrapper PID only after console and listener completion' {
    Reset-StopFixture
    Invoke-HouseholdHostBody
    Assert-True ($mock.consoleStops -eq 1 -and $mock.removes.Contains('wrapper.pid') -and $mock.cleanupStages.Count -eq 0)
    Assert-True (!$mock.removes.Contains('host.pid'))
}
Test 'Failed official tunnel stop records degraded stage and preserves remaining wrapper tracking' {
    Reset-StopFixture;$mock.stopError='HOUSEHOLD_TUNNEL_STOP_FAILED: fake-private-value'
    Assert-Throws { Invoke-HouseholdHostBody } 'HOUSEHOLD_TUNNEL_STOP_FAILED'
    Assert-True ($mock.cleanupStages[0] -ceq 'tunnel-stop' -and $mock.consoleStops -eq 0 -and $mock.removes.Count -eq 0)
}
Test 'Unknown tunnel status times out with degraded evidence before any console stop' {
    Reset-StopFixture;$mock.status=$null
    Assert-Throws { Invoke-HouseholdHostBody } 'HOUSEHOLD_TUNNEL_STOP_TIMEOUT'
    Assert-True ($mock.cleanupStages[0] -ceq 'tunnel-wait' -and $mock.consoleStops -eq 0 -and $mock.removes.Count -eq 0)
}
Test 'Console rejection and timeout retain wrapper evidence and record only fixed cleanup stage' {
    foreach ($code in @('PRIVATE_CONSOLE_STOP_FAILED','PRIVATE_CONSOLE_HELPER_TIMEOUT')) {
        Reset-StopFixture;$mock.consoleError=$code+': fake-private-value'
        Assert-Throws { Invoke-HouseholdHostBody } $code
        Assert-True ($mock.cleanupStages[0] -ceq 'console-stop' -and $mock.removes.Count -eq 0)
    }
}
Test 'Remaining listener fails cleanup before removing wrapper PID' {
    Reset-StopFixture;$mock.listening=$true
    Assert-Throws { Invoke-HouseholdHostBody } 'HOUSEHOLD_STOP_LISTENER_REMAINS'
    Assert-True ($mock.cleanupStages[0] -ceq 'listener-check' -and $mock.removes.Count -eq 0)
}
Test 'Marker-write failure preserves tracking and original cleanup failure' {
    Reset-StopFixture;$mock.consoleError='PRIVATE_CONSOLE_STOP_FAILED';$mock.writerFails=$true
    Assert-Throws { Invoke-HouseholdHostBody } 'PRIVATE_CONSOLE_STOP_FAILED'
    Assert-True ($mock.removes.Count -eq 0 -and $mock.cleanupStages.Count -eq 0)
}
Test 'Portable release command is encoded without a legacy wrapper or stderr redirection' {
    $mock.stopRequested=$false;$mock.receiptPresent=$false;$mock.listening=$false;$mock.ownerValid=$true;$mock.runtimeReady=$true
    $before=$mock.starts
    $launchCfg=[pscustomobject]@{port=$cfg.port;projectPath='portable-fixture-project'}
    Assert-True (Start-CodexlessIfNeeded $launchCfg)
    Assert-True ($mock.starts -eq $before+1)
    Assert-True ($script:CapturedConsoleArguments -match '-EncodedCommand ([A-Za-z0-9+/=]+)$')
    $command=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1]))
    Assert-True ($command -ceq ('fixture-direct-launch:'+([string]$launchCfg.port)))
    Assert-True ($command -notmatch 'Core\.ps1|Host\.ps1|verified-codex-runtime|Start-VerifiedHousehold')
    Assert-True ($script:CapturedWorkingDirectory -ceq $launchCfg.projectPath)
}
Test 'Staged Host never contains a force-termination or security-job escape path' {
    $source = [IO.File]::ReadAllText([IO.Path]::GetFullPath($scriptPath))
    Assert-True ($source -notmatch 'taskkill|Stop-Process|Stop-ScheduledTask|TerminateProcess|CREATE_BREAKAWAY_FROM_JOB')
    Assert-True ($source.Contains('Request-PrivateConsoleStop'))
    Assert-True ($source.Contains('runtimes stop'))
}
Write-Output ("RESULT: {0}/{0} PASS; Host adapters mocked; no task/runtime/tunnel operations" -f $results.Count)
