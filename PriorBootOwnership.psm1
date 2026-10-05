Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'UserSessionTask.psm1')
Import-Module (Join-Path $PSScriptRoot 'CompanionRuntime.psm1')
Import-Module (Join-Path $PSScriptRoot 'GenerationIdentity.psm1')

function ConvertTo-ReceiptUtc($Value) {
    # v1 CIM receipts have 1-7 fractional digits, depending on the writing runtime.
    if ($Value -isnot [string] -or $Value -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{1,7}Z$') { throw 'RECOVERY_TIMESTAMP_INVALID' }
    [DateTimeOffset]::ParseExact($Value,"yyyy-MM-dd'T'HH:mm:ss.FFFFFFF'Z'",[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime
}

function Get-WindowsBootUtc {
    $os = @(Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 10 -ErrorAction Stop)
    if ($os.Count -ne 1 -or $os[0].LastBootUpTime -isnot [DateTime] -or $os[0].LastBootUpTime.Kind -eq [DateTimeKind]::Unspecified) { throw 'RECOVERY_BOOT_UNKNOWN' }
    $boot = $os[0].LastBootUpTime.ToUniversalTime()
    if ($boot -gt [DateTime]::UtcNow -or $boot.Year -lt 2000) { throw 'RECOVERY_BOOT_INVALID' }
    $boot
}

function Assert-RecoveryPath([string]$Path) {
    # Check ancestors too: a receipt beneath a junction is not a local deployment proof.
    $cursor = $Path
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor -ErrorAction Stop) {
            if ((Get-Item -LiteralPath $cursor -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'RECOVERY_REPARSE_POINT' }
        }
        $cursor = Split-Path -Path $cursor -Parent
    }
}

function Get-PriorBootEvidence($Definition,$Config,$Tunnels,[DateTime]$Boot) {
    $launcher = $Definition.LauncherDirectory
    Assert-RecoveryPath $launcher
    $names = @('task-owner.json','host.pid','codexless-console-owner.json','codexless.pid','household-cleanup-state.json')
    $directory = Join-Path $launcher 'tunnel-owners'
    Assert-RecoveryPath $directory
    $aliases = @{}
    foreach ($tunnel in $Tunnels) {
        if ($tunnel.alias -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$' -or $aliases.ContainsKey($tunnel.alias) -or [string]::IsNullOrWhiteSpace($tunnel.tunnelId)) { throw 'RECOVERY_TUNNEL_CONFIG_INVALID' }
        $aliases[$tunnel.alias] = $tunnel
    }
    if (Test-Path -LiteralPath $directory) {
        foreach ($file in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
            if ($file.PSIsContainer -or $file.Extension -cne '.json' -or !$aliases.ContainsKey($file.BaseName)) { throw 'RECOVERY_UNKNOWN_TUNNEL_EVIDENCE' }
            $names += 'tunnel-owners\'+$file.Name
        }
    }
    if ($names.Count -gt 69) { throw 'RECOVERY_EVIDENCE_LIMIT' }
    $raw = @{}; $records = @{}; $pids = @()
    foreach ($name in $names) {
        $path = Join-Path $launcher $name
        if (!(Test-Path -LiteralPath $path -ErrorAction Stop)) { continue }
        Assert-RecoveryPath $path
        $file = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($file.PSIsContainer -or $file.Length -gt 16384 -or $file.Length -eq 0) { throw 'RECOVERY_EVIDENCE_INVALID' }
        $raw[$name] = [IO.File]::ReadAllText($path)
        if ($name.EndsWith('.json')) { $records[$name] = $raw[$name] | ConvertFrom-Json -ErrorAction Stop }
    }
    $owner = $records['task-owner.json']
    if ($null -eq $owner -or $owner.version -ne 1 -or $owner.userSid -cne $Definition.UserSid -or $owner.taskName -cne $Definition.Name -or $owner.hostScript -cne $Definition.HostScript -or $owner.launcherDirectory -cne $launcher) { throw 'RECOVERY_OWNER_INVALID' }
    Assert-CompanionGenerationContract $owner.generationContract $Config
    $created = ConvertTo-ReceiptUtc $owner.createdAt
    if ($created -ge $Boot) { throw 'RECOVERY_SAME_BOOT' }
    foreach ($name in @($records.Keys)) {
        $record = $records[$name]
        if ($name -eq 'household-cleanup-state.json') {
            $marker = Get-HouseholdCleanupState $launcher
            if ($marker.state -cne 'degraded' -or $marker.ownerPid -ne $owner.pid -or $record.requiresVerifiedRecovery -isnot [bool] -or !$record.requiresVerifiedRecovery) { throw 'RECOVERY_MARKER_INVALID' }
            $time = ConvertTo-ReceiptUtc $marker.recordedAt
        } else {
            $id = 0
            if ($record.version -ne 1 -or ![int]::TryParse([string]$record.pid,[ref]$id) -or $id -le 0 -or $record.userSid -cne $Definition.UserSid -or $pids -contains $id) { throw 'RECOVERY_RECEIPT_INVALID' }
            $pids += $id
            $time = ConvertTo-ReceiptUtc $record.createdAt
            if ($name -eq 'codexless-console-owner.json') {
                # Bind the console receipt to the exact release-derived launch command
                # without executing, logging or archiving that command.
                $command = Get-CodexlessPrivateConsoleCommand $Config
                $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
                $expected = '"'+$Definition.PowerShellExe+'" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand '+$encoded
                if ($record.executable -ine $Definition.PowerShellExe -or $record.commandLine -cne $expected) { throw 'RECOVERY_CONSOLE_INVALID' }
            } elseif ($name.StartsWith('tunnel-owners\')) {
                $alias = [IO.Path]::GetFileNameWithoutExtension($name)
                $sha = [Security.Cryptography.SHA256]::Create()
                try { $digest = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($aliases[$alias].tunnelId)))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
                $native = ConvertTo-ReceiptUtc $record.nativeCreatedAt
                if ($record.alias -cne $alias -or $record.executable -ine $Config.tunnelExe -or $record.registrationDigest -cne $digest -or $native -lt $time -or ($native-$time).Ticks -gt 9 -or $native -ge $Boot) { throw 'RECOVERY_TUNNEL_INVALID' }
            }
        }
        if ($time -lt $created -or $time -ge $Boot) { throw 'RECOVERY_GENERATION_INCONSISTENT' }
    }
    foreach ($pair in @(@('host.pid','task-owner.json'),@('codexless.pid','codexless-console-owner.json'))) {
        if ($raw.ContainsKey($pair[0])) {
            if (!$records.ContainsKey($pair[1]) -or $raw[$pair[0]].Trim() -cne [string]$records[$pair[1]].pid) { throw 'RECOVERY_PID_BINDING_INVALID' }
        }
    }
    [pscustomobject]@{ raw=$raw; pids=$pids; owner=$owner }
}

function Get-RecoveryListeners {
    [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
}

function Get-RecoveryRunValues {
    $run = Get-Item -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction Stop
    foreach ($name in $run.GetValueNames()) { [pscustomobject]@{name=$name;value=[string]$run.GetValue($name)} }
}

function Get-RecoveryTunnelStatus($Config,$Tunnel) {
    # Bound the read-only status command. Timeout refuses recovery; it never kills
    # even this probe, and never invokes the client's connect/stop commands.
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $Config.tunnelExe
    $start.Arguments = 'runtimes status '+$Tunnel.alias+' --json'
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        if (!$process.Start()) { throw 'RECOVERY_STATUS_START_FAILED' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit(5000) -or !$stdout.Wait(1000) -or !$stderr.Wait(1000) -or $process.ExitCode -ne 0 -or $stdout.Result.Length -gt 65536) { throw 'RECOVERY_STATUS_UNAVAILABLE' }
        $stdout.Result | ConvertFrom-Json -ErrorAction Stop
    } finally { $process.Dispose() }
}

function Assert-PriorBootAbsence($Definition,$Config,$Tunnels,$Evidence) {
    # An authoritative socket table covers wildcard and IPv6 listeners too. Query
    # failure is not absence; do not use Core's connect probe (which swallows errors).
    $listeners = @(Get-RecoveryListeners)
    if (@($listeners | Where-Object { $_.Port -eq [int]$Config.port }).Count) { throw 'RECOVERY_LISTENER_PRESENT' }
    $statusPids = @()
    foreach ($tunnel in $Tunnels) {
        $status = Get-RecoveryTunnelStatus $Config $tunnel
        if ($null -eq $status -or $status.process_running -isnot [bool] -or $status.process_running -or $status.alias -cne $tunnel.alias -or $status.tunnel_id -cne $tunnel.tunnelId) { throw 'RECOVERY_TUNNEL_NOT_ABSENT' }
        if ($status.PSObject.Properties['ready'] -and ($status.ready -isnot [bool] -or $status.ready)) { throw 'RECOVERY_TUNNEL_STATUS_INCONSISTENT' }
        if ($status.PSObject.Properties['process'] -and $null -ne $status.process) {
            $statusPid = 0
            if (![int]::TryParse([string]$status.process.pid,[ref]$statusPid) -or $statusPid -le 0) { throw 'RECOVERY_TUNNEL_STATUS_INCONSISTENT' }
            $statusPids += $statusPid
        }
    }
    foreach ($run in @(Get-RecoveryRunValues)) {
        if ($run.name -match 'Codexless' -or $run.value -match 'Codexless') { throw 'RECOVERY_LEGACY_RUN_OWNER' }
    }
    $processes = @(Get-CimInstance Win32_Process -OperationTimeoutSec 10 -ErrorAction Stop)
    if (!$processes.Count) { throw 'RECOVERY_PROCESS_QUERY_EMPTY' }
    $tunnelName = if ([string]::IsNullOrWhiteSpace([string]$Config.tunnelExe)) { $null } else { [IO.Path]::GetFileName($Config.tunnelExe) }
    foreach ($process in $processes) {
        $id = [int]$process.ProcessId
        # Any reused or foreign recorded PID blocks, regardless of lifetime/SID.
        if ($Evidence.pids -contains $id -or $statusPids -contains $id) { throw 'RECOVERY_RECORDED_PID_PRESENT' }
        if ($id -eq $PID) { continue }
        if ($null -ne $tunnelName -and $process.Name -ieq $tunnelName) { throw 'RECOVERY_TUNNEL_PROCESS_PRESENT' }
        $command = [string]$process.CommandLine
        if ([string]::IsNullOrWhiteSpace($command)) {
            if ($process.Name -in @('powershell.exe','pwsh.exe','node.exe','codex.exe','cmd.exe')) { throw 'RECOVERY_PROCESS_UNREADABLE' }
        } else {
            if ($command -match '(?i)-(?:e|en|enc|enco|encod|encode|encoded|encodedc|encodedco|encodedcom|encodedcomm|encodedcomma|encodedcomman|encodedcommand)\s+"?([A-Za-z0-9+/=]+)') {
                $command += ' '+[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1]))
            }
            $needles=@($Definition.LauncherDirectory,(Split-Path $Definition.HostScript),$Config.codexlessRoot,$Config.nodeExe,$Config.launchScript)
            if (![string]::IsNullOrWhiteSpace([string]$Config.tunnelExe)) { $needles += [string]$Config.tunnelExe }
            foreach ($needle in $needles) {
                if (![string]::IsNullOrWhiteSpace([string]$needle) -and $command.IndexOf([string]$needle,[StringComparison]::OrdinalIgnoreCase) -ge 0) { throw 'RECOVERY_RELEVANT_PROCESS_PRESENT' }
            }
            if ($command -match '(?i)codexless|Task-Host\.ps1|Household-Host\.ps1|launch\.mjs["\s]+http') { throw 'RECOVERY_RELEVANT_PROCESS_PRESENT' }
        }
    }
}

function Invoke-PriorBootOwnership {
    param($Definition,[switch]$CheckOnly)
    $ErrorActionPreference = 'Stop'
    try {
        $launcher = $Definition.LauncherDirectory
        Assert-HouseholdPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value) $Definition.UserSid
        $settingsPath=Join-Path $launcher 'settings.json'
        if ((Get-Acl -LiteralPath $settingsPath).GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $Definition.UserSid) { throw 'RECOVERY_SETTINGS_OWNER_INVALID' }
        $settingsText = [IO.File]::ReadAllText($settingsPath)
        $cfg = Get-CompanionConfig $launcher
        if ([int]$cfg.port -lt 1 -or [int]$cfg.port -gt 65535 -or ![IO.Path]::IsPathRooted($cfg.nodeExe) -or ![IO.Path]::IsPathRooted($cfg.launchScript) -or ![IO.Path]::IsPathRooted($cfg.codexlessRoot)) { throw 'RECOVERY_CONFIG_INVALID' }
        if (@($cfg.tunnels).Count -and ([string]::IsNullOrWhiteSpace([string]$cfg.tunnelExe) -or ![IO.Path]::IsPathRooted($cfg.tunnelExe))) { throw 'RECOVERY_CONFIG_INVALID' }
        $tunnels = @(Get-ConfiguredTunnels $cfg -IncludeDisabled)
        if ($tunnels.Count -gt 64) { throw 'RECOVERY_TUNNEL_LIMIT' }
        $boot = Get-WindowsBootUtc
        $evidence = Get-PriorBootEvidence $Definition $cfg $tunnels $boot
        Assert-PriorBootAbsence $Definition $cfg $tunnels $evidence
        # Repeat all observations before mutating. A controller preflight never clears files.
        $again = Get-PriorBootEvidence $Definition $cfg $tunnels $boot
        if ($evidence.raw.Count -ne $again.raw.Count) { throw 'RECOVERY_EVIDENCE_CHANGED' }
        foreach ($name in $evidence.raw.Keys) { if (!$again.raw.ContainsKey($name) -or $evidence.raw[$name] -cne $again.raw[$name]) { throw 'RECOVERY_EVIDENCE_CHANGED' } }
        Assert-PriorBootAbsence $Definition $cfg $tunnels $again
        if ((Get-WindowsBootUtc) -ne $boot) { throw 'RECOVERY_BOOT_CHANGED' }
        # The second observation may have taken time. Recheck every byte (including
        # the old cleanup marker) before replacing that marker with our own fence.
        $final = Get-PriorBootEvidence $Definition $cfg $tunnels $boot
        Assert-CompanionGenerationContract $final.owner.generationContract (Get-CompanionConfig $launcher)
        if ($evidence.raw.Count -ne $final.raw.Count -or [IO.File]::ReadAllText($settingsPath) -cne $settingsText) { throw 'RECOVERY_EVIDENCE_CHANGED' }
        foreach ($name in $evidence.raw.Keys) { if (!$final.raw.ContainsKey($name) -or $evidence.raw[$name] -cne $final.raw[$name]) { throw 'RECOVERY_EVIDENCE_CHANGED' } }
        if ($CheckOnly) { return }
        # The caller is Task-Host, inside its Scheduler/identity/owner-mutex gates.
        # Replace the fence BEFORE retirement: interruption now requires manual recovery.
        $marker = Join-Path $launcher 'household-cleanup-state.json'
        $diagnostic = Join-Path $launcher 'prior-boot-recovery.json'
        foreach ($path in @($marker,$diagnostic)) { Assert-RecoveryPath $path }
        $summary = [ordered]@{version=1;state='retiring';recordedAt=[DateTime]::UtcNow.ToString('o');bootUtc=$boot.ToString('o');priorOwnerCreatedAt=$evidence.owner.createdAt;priorOwnerPid=$evidence.owner.pid;receiptCount=$evidence.raw.Count}
        $summary | ConvertTo-Json | Set-Content -LiteralPath $diagnostic -Encoding utf8
        $fence = [ordered]@{version=1;state='degraded';stage='task-host';reasonCode='HOUSEHOLD_VERIFIED_RECOVERY_REQUIRED';recordedAt=[DateTime]::UtcNow.ToString('o');ownerPid=$PID;requiresVerifiedRecovery=$true}
        $fence | ConvertTo-Json | Set-Content -LiteralPath $marker -Encoding utf8
        # Owner receipt is last; all removals are exact validated paths, never recursive.
        $retire = @($evidence.raw.Keys | Where-Object { $_ -notin @('task-owner.json','household-cleanup-state.json') }) + @('task-owner.json')
        foreach ($name in $retire) {
            $path = Join-Path $launcher $name
            Assert-RecoveryPath $path
            if ([IO.File]::ReadAllText($path) -cne $evidence.raw[$name]) { throw 'RECOVERY_EVIDENCE_CHANGED' }
            Remove-Item -LiteralPath $path -ErrorAction Stop
        }
        $summary.state = 'retired'
        $summary | ConvertTo-Json | Set-Content -LiteralPath $diagnostic -Encoding utf8
        Remove-Item -LiteralPath $marker -ErrorAction Stop
    } catch {
        # Do not surface provider errors, raw receipts, configuration or command lines.
        throw 'HOUSEHOLD_CLEANUP_DEGRADED: Prior-boot recovery proof incomplete; ownership evidence remains fenced.'
    }
}

Export-ModuleMember -Function Invoke-PriorBootOwnership
