Import-Module (Join-Path $PSScriptRoot 'MutationLock.psm1')
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
    # The logon owner's boot-provider observation can time out while WMI starts.
    # Retry only the exact native timeout observed in that owner's event record.
    # No receipt/ledger mutation occurs here; all typed boot and identity checks
    # still run after a successful observation, including the final boot recheck.
    for ($attempt=1; $attempt -le 3; $attempt++) {
        try {
            $os = @(Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 10 -ErrorAction Stop)
            break
        } catch {
            if ($_.FullyQualifiedErrorId -cne 'HRESULT 0x40004,Microsoft.Management.Infrastructure.CimCmdlets.GetCimInstanceCommand') { throw }
            if ($attempt -eq 3) { throw 'RECOVERY_BOOT_QUERY_TIMEOUT' }
            Start-Sleep -Milliseconds 500
        }
    }
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
            if ($record.version -ne $(if($name.StartsWith('tunnel-owners\')){2}else{1}) -or ![int]::TryParse([string]$record.pid,[ref]$id) -or $id -le 0 -or $record.userSid -cne $Definition.UserSid -or $pids -contains $id) { throw 'RECOVERY_RECEIPT_INVALID' }
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
                $connectStart=ConvertTo-ReceiptUtc $record.connectCreatedAt
                $connectExit=ConvertTo-ReceiptUtc $record.connectExitedAt
                $context=Get-TunnelRuntimeContext $Config $aliases[$alias]
                $sha=[Security.Cryptography.SHA256]::Create()
                try{$namespace=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($context.stateRoot)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
                if ($record.connectPid -le 0 -or $connectStart -lt $created -or $connectStart -gt $native -or $connectExit -lt $native -or $connectExit -ge $Boot -or $record.namespaceDigest -cne $namespace -or $record.generationSha256 -cne $owner.generationContract.sha256 -or $record.executableSha256 -cne 'fcc85a69ec0ad82518e4f8964f60c45e31787957782a0fc9c1b0c44e82d61b9b' -or $record.namespaceDigest -cnotmatch '^[0-9a-f]{64}$' -or $record.alias -cne $alias -or $record.executable -ine $Config.tunnelExe -or $record.registrationDigest -cne $digest -or $native -lt $time -or ($native-$time).Ticks -gt 9 -or $native -ge $Boot) { throw 'RECOVERY_TUNNEL_INVALID' }
            }
        }
        if ($time -lt $created -or $time -ge $Boot) { throw 'RECOVERY_GENERATION_INCONSISTENT' }
    }
    foreach ($pair in @(@('host.pid','task-owner.json'),@('codexless.pid','codexless-console-owner.json'))) {
        if ($raw.ContainsKey($pair[0])) {
            if (!$records.ContainsKey($pair[1]) -or $raw[$pair[0]].Trim() -cne [string]$records[$pair[1]].pid) { throw 'RECOVERY_PID_BINDING_INVALID' }
        }
    }
    [pscustomobject]@{ raw=$raw; pids=$pids; owner=$owner; records=$records; boot=$Boot }
}

function Assert-RecoveryForeignLifetime($Process,$Evidence,$Definition,$Config) {
    # No SID query, process handle, signal or adoption. The independently validated
    # receipt generation is before boot; this PID's typed lifetime is after boot.
    if ($null -eq $Process -or !$Process.PSObject.Properties['CreationDate'] -or
        $Process.CreationDate -isnot [DateTime] -or $Process.CreationDate.Kind -eq [DateTimeKind]::Unspecified) { throw 'RECOVERY_REUSED_LIFETIME_UNKNOWN' }
    $created=$Process.CreationDate.ToUniversalTime()
    if ($created -le $Evidence.boot -or $created -gt [DateTime]::UtcNow) { throw 'RECOVERY_REUSED_LIFETIME_UNKNOWN' }
    # A production executable/name conflict is ambiguous even with a newer lifetime.
    $names=@('powershell.exe','pwsh.exe','node.exe','cmd.exe','codex.exe',[IO.Path]::GetFileName($Config.tunnelExe),[IO.Path]::GetFileName($Config.nodeExe))
    if ([string]::IsNullOrWhiteSpace([string]$Process.Name) -or $Process.Name -in $names) { throw 'RECOVERY_REUSED_IDENTITY_CONFLICT' }
    $image=if($Process.PSObject.Properties['ExecutablePath']){[string]$Process.ExecutablePath}else{''}
    if ($image -ieq $Definition.PowerShellExe -or (![string]::IsNullOrWhiteSpace([string]$Config.tunnelExe) -and $image -ieq $Config.tunnelExe) -or $image -ieq $Config.nodeExe -or
        $image.StartsWith($Definition.LauncherDirectory+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'RECOVERY_REUSED_IDENTITY_CONFLICT' }
    # Protected unrelated images may omit path/command/SID; the non-production
    # process name plus the new kernel-boot lifetime excludes the recorded owner.
}

function Assert-RecoveryTunnelMetadata($Config,$Tunnel,$Status,$Evidence) {
    $name='tunnel-owners\'+$Tunnel.alias+'.json'
    if (!$Evidence.records.ContainsKey($name)) { throw 'RECOVERY_TUNNEL_RECEIPT_MISSING' }
    $receipt=$Evidence.records[$name]; $process=$Status.process
    if ($process.pid -ne $receipt.pid -or $process.alias -cne $Tunnel.alias -or
        $process.tunnel_id -cne $Tunnel.tunnelId -or $process.mode -cne 'process' -or
        $process.started_at -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') { throw 'RECOVERY_TUNNEL_METADATA_UNKNOWN' }
    $published=[DateTimeOffset]::ParseExact($process.started_at,"yyyy-MM-dd'T'HH:mm:ss'Z'",[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime
    $created=ConvertTo-ReceiptUtc $receipt.createdAt
    # Connect publishes UTCNow after readiness, and can refresh it on reuse.
    # Whole-second publication may roll over or be later in the proven prior boot.
    # Exact CIM/native lifetime and the connect interval remain independent proof.
    if ($published -ge $Evidence.boot -or $published.AddSeconds(1) -le $created) { throw 'RECOVERY_TUNNEL_METADATA_GENERATION' }
    $context=Get-TunnelRuntimeContext $Config $Tunnel
    if ($process.health_url_file -cne (Join-Path $context.stateRoot ('health\'+$Tunnel.alias+'.url')) -or
        $process.log_path -cne (Join-Path $context.stateRoot ('logs\'+$Tunnel.alias+'.log')) -or
        $process.profile_dir -cne $context.profileRoot -or $process.profile_name -cne $Tunnel.alias -or
        $process.profile_path -cne (Join-Path $context.profileRoot ($Tunnel.alias+'.yaml')) -or
        $process.config_path -cne $process.profile_path -or $process.target_kind -cne 'server_url' -or
        $process.target_value -cne $Config.mcpUrl -or
        $process.command -cne ("'$($Config.tunnelExe)' 'run' '--profile-dir' '$($context.profileRoot)' '--profile' '$($Tunnel.alias)'")) { throw 'RECOVERY_TUNNEL_METADATA_BINDING' }
    # The old namespace derives from this exact owner receipt. Normal startup
    # derives a fresh namespace from the new owner lifetime; it cannot reuse this
    # stale ledger. Do not edit the shared default tunnel-client state or run stop.
}

function Get-RecoveryListeners {
    [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
}

function Get-RecoveryRunValues {
    $run = Get-Item -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction Stop
    foreach ($name in $run.GetValueNames()) { [pscustomobject]@{name=$name;value=[string]$run.GetValue($name)} }
}

function Get-RecoveryTunnelStatus($Config,$Tunnel) {
    $status=Get-TunnelStatus $Config $Tunnel
    if($null -eq $status){throw 'RECOVERY_STATUS_UNAVAILABLE'}
    $status
}

function Assert-RecoveryStoppedTunnel($Config,$Tunnel,$Status,$Evidence) {
    $process=$Status.process
    # The qualified client omits PID in stopped status and stores zero in its
    # ledger. Prove the prior owner's isolated namespace before accepting either.
    if ($Status.process_running -or !$Status.PSObject.Properties['ready'] -or
        $Status.ready -isnot [bool] -or $Status.ready -or $process.mode -cne 'stopped') { throw 'RECOVERY_TUNNEL_STATUS_INCONSISTENT' }
    $pidField=$process.PSObject.Properties['pid']
    if ($null -ne $pidField -and (($pidField.Value -isnot [int] -and $pidField.Value -isnot [long]) -or $pidField.Value -ne 0)) { throw 'RECOVERY_TUNNEL_STATUS_INCONSISTENT' }
    $context=Get-TunnelRuntimeContext $Config $Tunnel
    $expected=@{
        alias=$Tunnel.alias; tunnel_id=$Tunnel.tunnelId; mode='stopped'
        health_url_file=(Join-Path $context.stateRoot ('health\'+$Tunnel.alias+'.url'))
        log_path=(Join-Path $context.stateRoot ('logs\'+$Tunnel.alias+'.log'))
        profile_dir=$context.profileRoot; profile_name=$Tunnel.alias
        profile_path=(Join-Path $context.profileRoot ($Tunnel.alias+'.yaml'))
        config_path=(Join-Path $context.profileRoot ($Tunnel.alias+'.yaml'))
        target_kind='server_url'; target_value=$Config.mcpUrl
        command=("'$($Config.tunnelExe)' 'run' '--profile-dir' '$($context.profileRoot)' '--profile' '$($Tunnel.alias)'")
    }
    foreach($field in $expected.Keys) {
        $value=$process.PSObject.Properties[$field]
        if ($null -eq $value -or [string]$value.Value -cne [string]$expected[$field]) { throw 'RECOVERY_TUNNEL_METADATA_BINDING' }
    }
    $publication=$process.PSObject.Properties['started_at']
    if ($null -eq $publication -or $publication.Value -isnot [string] -or
        $publication.Value -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') { throw 'RECOVERY_TUNNEL_METADATA_UNKNOWN' }
    $published=[DateTimeOffset]::ParseExact($publication.Value,"yyyy-MM-dd'T'HH:mm:ss'Z'",[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime
    $created=ConvertTo-ReceiptUtc $Evidence.owner.createdAt
    if ($published -ge $Evidence.boot -or $published.AddSeconds(1) -le $created) { throw 'RECOVERY_TUNNEL_METADATA_GENERATION' }
    $path=Join-Path $context.stateRoot 'processes.yaml'
    Assert-RecoveryPath $path
    $file=Get-Item -LiteralPath $path -ErrorAction Stop
    if ($file.PSIsContainer -or $file.Length -eq 0 -or $file.Length -gt 1048576 -or
        (Get-Acl -LiteralPath $path).GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $Evidence.owner.userSid) { throw 'RECOVERY_TUNNEL_STATE_INVALID' }
    $ledger=[IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop
    $entry=$ledger.PSObject.Properties[$Tunnel.alias]
    if ($null -eq $entry) { throw 'RECOVERY_TUNNEL_STATE_INVALID' }
    $ledgerPid=$entry.Value.PSObject.Properties['pid']
    if ($null -ne $ledgerPid -and (($ledgerPid.Value -isnot [int] -and $ledgerPid.Value -isnot [long]) -or $ledgerPid.Value -ne 0)) { throw 'RECOVERY_TUNNEL_STATE_INVALID' }
    foreach($field in @($expected.Keys)+@('started_at','admin_profile','session_name')) {
        $a=$entry.Value.PSObject.Properties[$field]; $b=$process.PSObject.Properties[$field]
        if (($null -eq $a) -ne ($null -eq $b) -or
            ($null -ne $a -and [string]$a.Value -cne [string]$b.Value)) { throw 'RECOVERY_TUNNEL_STATE_CHANGED' }
    }
    # No stop, ledger edit, PID adoption or receipt creation. The caller repeats
    # every global process/listener/receipt proof before retiring old evidence.
}

function Get-PriorBootRecoveryReason($Failure) {
    # Return only source-defined codes, never raw provider/command/config text.
    $allowed=@(
        'RECOVERY_TIMESTAMP_INVALID','RECOVERY_BOOT_QUERY_TIMEOUT','RECOVERY_BOOT_UNKNOWN','RECOVERY_BOOT_INVALID',
        'RECOVERY_REPARSE_POINT','RECOVERY_TUNNEL_CONFIG_INVALID','RECOVERY_UNKNOWN_TUNNEL_EVIDENCE','RECOVERY_EVIDENCE_LIMIT',
        'RECOVERY_EVIDENCE_INVALID','RECOVERY_OWNER_INVALID','RECOVERY_SAME_BOOT','RECOVERY_MARKER_INVALID',
        'RECOVERY_RECEIPT_INVALID','RECOVERY_CONSOLE_INVALID','RECOVERY_TUNNEL_INVALID','RECOVERY_GENERATION_INCONSISTENT',
        'RECOVERY_PID_BINDING_INVALID','RECOVERY_REUSED_LIFETIME_UNKNOWN','RECOVERY_REUSED_IDENTITY_CONFLICT',
        'RECOVERY_TUNNEL_RECEIPT_MISSING','RECOVERY_TUNNEL_METADATA_UNKNOWN','RECOVERY_TUNNEL_METADATA_GENERATION',
        'RECOVERY_TUNNEL_METADATA_BINDING','RECOVERY_TUNNEL_STATE_INVALID','RECOVERY_TUNNEL_STATE_CHANGED',
        'RECOVERY_STATUS_UNAVAILABLE','RECOVERY_LISTENER_PRESENT','RECOVERY_PROCESS_QUERY_EMPTY',
        'RECOVERY_TUNNEL_NOT_ABSENT','RECOVERY_TUNNEL_STATUS_INCONSISTENT','RECOVERY_PROCESS_QUERY_AMBIGUOUS',
        'RECOVERY_LEGACY_RUN_OWNER','RECOVERY_TUNNEL_PROCESS_PRESENT','RECOVERY_RELEVANT_PROCESS_PRESENT',
        'RECOVERY_PROCESS_UNREADABLE','RECOVERY_SETTINGS_OWNER_INVALID','RECOVERY_CONFIG_INVALID','RECOVERY_TUNNEL_LIMIT',
        'RECOVERY_EVIDENCE_CHANGED','RECOVERY_BOOT_CHANGED','GENERATION_CONTRACT_INVALID',
        'GENERATION_CONTRACT_MISMATCH','TUNNEL_GENERATION_CONTEXT_INVALID'
    )
    if ($null -ne $Failure -and $null -ne $Failure.Exception) {
        $saved=[string]$Failure.Exception.Data['RecoveryReasonCode']
        if ($saved -cin $allowed) { return $saved }
        $candidate=([string]$Failure.Exception.Message -split ':',2)[0]
        if ($candidate -cin $allowed) { return $candidate }
    }
    'RECOVERY_OBSERVATION_FAILED'
}

function Assert-PriorBootAbsence($Definition,$Config,$Tunnels,$Evidence) {
    # An authoritative socket table covers wildcard and IPv6 listeners too. Query
    # failure is not absence; do not use Core's connect probe (which swallows errors).
    $listeners = @(Get-RecoveryListeners)
    if (@($listeners | Where-Object { $_.Port -eq [int]$Config.port }).Count) { throw 'RECOVERY_LISTENER_PRESENT' }
    $processes = @(Get-CimInstance Win32_Process -OperationTimeoutSec 10 -ErrorAction Stop)
    if (!$processes.Count) { throw 'RECOVERY_PROCESS_QUERY_EMPTY' }
    $statusPids = @()
    foreach ($tunnel in $Tunnels) {
        $status = Get-RecoveryTunnelStatus $Config $tunnel
        if ($null -eq $status -or $status.process_running -isnot [bool] -or $status.alias -cne $tunnel.alias -or $status.tunnel_id -cne $tunnel.tunnelId) { throw 'RECOVERY_TUNNEL_NOT_ABSENT' }
        if ($status.PSObject.Properties['ready'] -and ($status.ready -isnot [bool] -or $status.ready)) { throw 'RECOVERY_TUNNEL_STATUS_INCONSISTENT' }
        if ($status.PSObject.Properties['process'] -and $null -ne $status.process) {
            if ($status.process.PSObject.Properties['mode'] -and $status.process.mode -ceq 'stopped') {
                Assert-RecoveryStoppedTunnel $Config $tunnel $status $Evidence
                continue
            }
            $statusPid = 0
            if (!$status.process.PSObject.Properties['pid'] -or ![int]::TryParse([string]$status.process.pid,[ref]$statusPid) -or $statusPid -le 0) { throw 'RECOVERY_TUNNEL_STATUS_INCONSISTENT' }
            $statusPids += $statusPid
            Assert-RecoveryTunnelMetadata $Config $tunnel $status $Evidence
            $live=@($processes | Where-Object {[int]$_.ProcessId -eq $statusPid})
            if ($live.Count -gt 1) { throw 'RECOVERY_PROCESS_QUERY_AMBIGUOUS' }
            if ($live.Count -eq 1) { Assert-RecoveryForeignLifetime $live[0] $Evidence $Definition $Config }
            if ($status.process_running -and $live.Count -ne 1) { throw 'RECOVERY_TUNNEL_STATUS_INCONSISTENT' }
        }
        elseif ($status.process_running) { throw 'RECOVERY_TUNNEL_NOT_ABSENT' }
    }
    foreach ($run in @(Get-RecoveryRunValues)) {
        if ($run.name -match 'Codexless' -or $run.value -match 'Codexless') { throw 'RECOVERY_LEGACY_RUN_OWNER' }
    }
    $tunnelName = if ([string]::IsNullOrWhiteSpace([string]$Config.tunnelExe)) { $null } else { [IO.Path]::GetFileName($Config.tunnelExe) }
    foreach ($process in $processes) {
        $id = [int]$process.ProcessId
        # Independent prior-boot receipt proof plus a current foreign lifetime.
        if ($Evidence.pids -contains $id -or $statusPids -contains $id) {
            if (@($processes | Where-Object {[int]$_.ProcessId -eq $id}).Count -ne 1) { throw 'RECOVERY_PROCESS_QUERY_AMBIGUOUS' }
            Assert-RecoveryForeignLifetime $process $Evidence $Definition $Config
        }
        if ($id -eq $PID) { continue }
        if ($null -ne $tunnelName -and $process.Name -ieq $tunnelName) { throw 'RECOVERY_TUNNEL_PROCESS_PRESENT' }
        $image=if($process.PSObject.Properties['ExecutablePath']){[string]$process.ExecutablePath}else{''}
        if ($image -ieq $Config.nodeExe -or (![string]::IsNullOrWhiteSpace([string]$Config.tunnelExe) -and $image -ieq $Config.tunnelExe)) { throw 'RECOVERY_RELEVANT_PROCESS_PRESENT' }
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
                if (![string]::IsNullOrWhiteSpace([string]$needle) -and ($command.IndexOf([string]$needle,[StringComparison]::OrdinalIgnoreCase) -ge 0 -or $image.IndexOf([string]$needle,[StringComparison]::OrdinalIgnoreCase) -ge 0)) { throw 'RECOVERY_RELEVANT_PROCESS_PRESENT' }
            }
            if ($command -match '(?i)codexless|Task-Host\.ps1|Household-Host\.ps1|launch\.mjs["\s]+http') { throw 'RECOVERY_RELEVANT_PROCESS_PRESENT' }
        }
    }
}

function Invoke-PriorBootOwnershipCore {
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
        $failure=[InvalidOperationException]::new('HOUSEHOLD_CLEANUP_DEGRADED: Prior-boot recovery proof incomplete; ownership evidence remains fenced.')
        $failure.Data['RecoveryReasonCode']=Get-PriorBootRecoveryReason $_
        throw $failure
    }
}

function Invoke-PriorBootOwnership {
    param($Definition,[switch]$CheckOnly)
    if($CheckOnly){return Invoke-PriorBootOwnershipCore $Definition -CheckOnly}
    Invoke-CompanionResourceMutation $Definition.LauncherDirectory {Invoke-PriorBootOwnershipCore $Definition}
}
Export-ModuleMember -Function Invoke-PriorBootOwnership,Get-PriorBootRecoveryReason
