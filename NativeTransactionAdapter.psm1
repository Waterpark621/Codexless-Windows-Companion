Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'InstallTransaction.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'UserSessionTask.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'WindowsTaskAdapter.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CompanionRuntime.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ArtifactProvenance.psm1') -Force

function Get-NativeBytesSha256([byte[]]$Bytes) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-NativeStringSha256([string]$Value) {
    Get-NativeBytesSha256 ([Text.Encoding]::UTF8.GetBytes($Value))
}

function Get-NativeFileSha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Resolve-NativeAdapterPath {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Label,
        [ValidateSet('Any','File','Directory')][string]$Kind='Any',
        [switch]$MustExist
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -notmatch '^[A-Za-z]:[\\/]' -or $Path.StartsWith('\\') -or
        $Path.Contains('"') -or $Path.Contains([char]13) -or $Path.Contains([char]10)) {
        throw "NATIVE_ADAPTER_PATH_INVALID: $Label must be a fully-qualified local drive path."
    }
    $full=[IO.Path]::GetFullPath($Path)
    $drive=[IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $drive.Length) { $full=$full.TrimEnd('\') }
    if ($MustExist) {
        if ($Kind -eq 'File' -and !(Test-Path -LiteralPath $full -PathType Leaf)) { throw "NATIVE_ADAPTER_PATH_INVALID: $Label is not an existing file." }
        if ($Kind -eq 'Directory' -and !(Test-Path -LiteralPath $full -PathType Container)) { throw "NATIVE_ADAPTER_PATH_INVALID: $Label is not an existing directory." }
        if ($Kind -eq 'Any' -and !(Test-Path -LiteralPath $full)) { throw "NATIVE_ADAPTER_PATH_INVALID: $Label does not exist." }
    }
    $cursor=$full
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "NATIVE_ADAPTER_REPARSE_POINT: $Label traverses a reparse point."
            }
        }
        $next=Split-Path $cursor -Parent
        if ([string]::IsNullOrWhiteSpace($next) -or $next -ceq $cursor) { break }
        $cursor=$next
    }
    $full
}

function Read-NativeJson {
    param([Parameter(Mandatory=$true)][string]$Path,[ValidateRange(1,65536)][int]$Limit=32768)
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'NATIVE_ADAPTER_STATE_MISSING' }
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint -or $item.Length -gt $Limit) { throw 'NATIVE_ADAPTER_STATE_INVALID' }
    $bytes=[IO.File]::ReadAllBytes($Path)
    try { [Text.UTF8Encoding]::new($false,$true).GetString($bytes) | ConvertFrom-Json -ErrorAction Stop }
    catch { throw 'NATIVE_ADAPTER_STATE_INVALID' }
}

function Write-NativeJson {
    param([string]$Path,$Value,[switch]$CreateNew)
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 8 -Compress))
    if ($CreateNew) {
        $stream=$null
        try {
            $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
            $stream.Write($bytes,0,$bytes.Length)
            $stream.Flush($true)
        } finally { if ($stream) { $stream.Dispose() } }
        return
    }
    $temp=$Path+'.'+[Guid]::NewGuid().ToString('N')+'.pending'
    $stream=$null
    try {
        $stream=[IO.File]::Open($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $stream.Write($bytes,0,$bytes.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream=$null
        if (Test-Path -LiteralPath $Path) {
            $backup=$Path+'.'+[Guid]::NewGuid().ToString('N')+'.backup'
            try { [IO.File]::Replace($temp,$Path,$backup,$true) }
            finally { if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue } }
        }
        else { [IO.File]::Move($temp,$Path) }
    } finally {
        if ($stream) { $stream.Dispose() }
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}

function Get-NativeGenerationPath($Binding,$Record) {
    if ($Record.generationId -cnotmatch '^[0-9a-f]{32}$') { throw 'NATIVE_ADAPTER_RECORD_INVALID' }
    Resolve-NativeAdapterPath (Join-Path (Join-Path $Binding.Root 'generations') ([string]$Record.generationId)) 'generation' Directory -MustExist
}

function Assert-NativePayloadShape([string]$Path) {
    foreach ($file in @(
        'Task-Host.ps1','Household-Host.ps1','UserSessionTask.psm1','WindowsTaskAdapter.psm1',
        'CompanionRuntime.psm1','GenerationIdentity.psm1','PrivateConsole.psm1','PriorBootOwnership.psm1',
        'VerifiedTunnel.psm1','ArtifactProvenance.psm1','BoundedNative.psm1','Signal-PrivateConsole.ps1'
    )) {
        if (!(Test-Path -LiteralPath (Join-Path $Path $file) -PathType Leaf)) { throw 'NATIVE_ADAPTER_PAYLOAD_INVALID' }
    }
}

function Test-NativeVerifiedStage($Binding,[string]$Path) {
    try {
        $full=Resolve-NativeAdapterPath $Path 'payload stage' Directory -MustExist
        Assert-NativePayloadShape $full
        $digest=Get-TransactionTreeDigest $full
        return ($Binding.TrustedPayloadSha256 -ccontains $digest)
    } catch { return $false }
}

function Assert-NativeFenceRecord {
    param($Binding,$Record,[string[]]$Allowed)
    $fence=Read-NativeJson (Join-Path $Binding.Root 'incomplete-install.json')
    if ($fence.version -ne 1 -or $fence.transactionId -cnotmatch '^[0-9a-f]{32}$' -or
        $fence.generationId -cnotmatch '^[0-9a-f]{32}$' -or $fence.payloadSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $fence.requiresVerifiedRecovery -ne $true) { throw 'NATIVE_ADAPTER_FENCE_INVALID' }
    $pair=([string]$fence.operation)+'/'+([string]$fence.stage)
    if ($Allowed -cnotcontains $pair) { throw 'NATIVE_ADAPTER_FENCE_STAGE_INVALID' }

    if ($fence.operation -ceq 'update') {
        $candidate=($Record.transactionId -ceq $fence.transactionId -and
            $Record.generationId -ceq $fence.generationId -and
            $Record.payloadSha256 -ceq $fence.payloadSha256)
        $rollback=($fence.PSObject.Properties['rollbackGenerationId'] -and
            $fence.PSObject.Properties['rollbackSha256'] -and
            $Record.generationId -ceq $fence.rollbackGenerationId -and
            $Record.payloadSha256 -ceq $fence.rollbackSha256)
        if (!$candidate -and !$rollback) { throw 'NATIVE_ADAPTER_FENCE_RECORD_MISMATCH' }
    } else {
        if ($Record.transactionId -cne $fence.transactionId -or
            $Record.generationId -cne $fence.generationId -or
            $Record.payloadSha256 -cne $fence.payloadSha256) { throw 'NATIVE_ADAPTER_FENCE_RECORD_MISMATCH' }
    }
    $fence
}

function New-NativeTaskDefinition($Binding,$Record) {
    $generation=Get-NativeGenerationPath $Binding $Record
    $parameters=@{
        UserSid=$Binding.UserSid
        LauncherDirectory=$Binding.Root
        HostScript=(Join-Path $generation 'Task-Host.ps1')
        PowerShellExe=$Binding.PowerShellExe
        TransactionId=[string]$Record.transactionId
        GenerationId=[string]$Record.generationId
    }
    if ($null -ne $Binding.DisposableTaskName) { $parameters.TaskName=$Binding.DisposableTaskName }
    New-HouseholdTaskDefinition @parameters
}

function Get-NativeTask($Binding) {
    $task=Get-ScheduledTask -TaskName $Binding.TaskName -TaskPath '\' -ErrorAction SilentlyContinue
    if ($null -eq $task) { return $null }
    [pscustomobject]@{
        state=[string]$task.State
        xml=(Export-ScheduledTask -TaskName $Binding.TaskName -TaskPath '\' -ErrorAction Stop)
    }
}

function Assert-NativeConfig($Binding) {
    $cfg=Get-CompanionConfig $Binding.Root
    if ($cfg.companionRoot -ine $Binding.Root -or
        $cfg.projectPath -ine $Binding.ProjectPath -or
        $cfg.codexlessRoot -ine $Binding.CodexlessRoot -or
        $cfg.nodeExe -ine $Binding.NodeExe -or
        $cfg.nodeSha256 -cne $Binding.NodeSha256 -or
        [int]$cfg.port -ne $Binding.Port) { throw 'NATIVE_ADAPTER_SETTINGS_MISMATCH' }
    if ($Binding.TunnelEnabled) {
        if (@($cfg.tunnels).Count -ne 1 -or
            $cfg.tunnelExe -ine $Binding.TunnelClientExe -or
            $cfg.profileDir -ine (Join-Path $Binding.Root 'tunnel-profile') -or
            $cfg.tunnels[0].alias -cne $Binding.TunnelAlias -or
            $cfg.tunnels[0].tunnelId -cne $Binding.TunnelId -or
            $cfg.tunnels[0].keyPath -ine (Join-Path $Binding.Root 'keys\runtime-key.dpapi')) {
            throw 'NATIVE_ADAPTER_SETTINGS_MISMATCH'
        }
        try { $null=ConvertTo-SecureString ((Get-Content -LiteralPath $cfg.tunnels[0].keyPath -Raw -ErrorAction Stop).Trim()) }
        catch { throw 'NATIVE_ADAPTER_CREDENTIAL_INVALID' }
    } elseif (@($cfg.tunnels).Count -ne 0) {
        throw 'NATIVE_ADAPTER_SETTINGS_MISMATCH'
    }
    $cfg
}

function New-NativeOwnerReceipt($Binding,$Record) {
    $settings=Join-Path $Binding.Root 'settings.json'
    $key=Join-Path $Binding.Root 'keys\runtime-key.dpapi'
    [ordered]@{
        version=1
        state='active'
        transactionId=[string]$Record.transactionId
        generationId=[string]$Record.generationId
        payloadSha256=[string]$Record.payloadSha256
        nodeSha256=[string]$Binding.NodeSha256
        settingsSha256=(Get-NativeFileSha256 $settings)
        credentialSha256=if($Binding.TunnelEnabled){Get-NativeFileSha256 $key}else{$null}
        taskNameSha256=(Get-NativeStringSha256 $Binding.TaskName)
        taskBindingSha256=(Get-NativeStringSha256 (([string]$Record.transactionId)+'/'+([string]$Record.generationId)))
    }
}

function Assert-NativeOwnedState($Binding,$Record) {
    if ($Record.version -ne 1 -or $Record.state -cne 'installed' -or
        $Record.transactionId -cnotmatch '^[0-9a-f]{32}$' -or
        $Record.generationId -cnotmatch '^[0-9a-f]{32}$' -or
        $Record.payloadSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'NATIVE_ADAPTER_RECORD_INVALID' }
    if ($Binding.TrustedPayloadSha256 -cnotcontains [string]$Record.payloadSha256) { throw 'NATIVE_ADAPTER_PAYLOAD_UNTRUSTED' }

    $receipt=Read-NativeJson (Join-Path $Binding.Root 'native-adapter-owner.json')
    if ($receipt.version -ne 1 -or $receipt.state -cne 'active' -or
        $receipt.transactionId -cne $Record.transactionId -or
        $receipt.generationId -cne $Record.generationId -or
        $receipt.payloadSha256 -cne $Record.payloadSha256 -or
        $receipt.nodeSha256 -cne $Binding.NodeSha256 -or
        $receipt.settingsSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $receipt.taskNameSha256 -cne (Get-NativeStringSha256 $Binding.TaskName) -or
        $receipt.taskBindingSha256 -cne (Get-NativeStringSha256 (([string]$Record.transactionId)+'/'+([string]$Record.generationId)))) {
        throw 'NATIVE_ADAPTER_OWNER_MISMATCH'
    }

    $settings=Join-Path $Binding.Root 'settings.json'
    if (!(Test-Path -LiteralPath $settings -PathType Leaf) -or
        (Get-NativeFileSha256 $settings) -cne $receipt.settingsSha256) { throw 'NATIVE_ADAPTER_FOREIGN_STATE' }

    $key=Join-Path $Binding.Root 'keys\runtime-key.dpapi'
    if ($Binding.TunnelEnabled) {
        if ($receipt.credentialSha256 -cnotmatch '^[0-9a-f]{64}$' -or
            !(Test-Path -LiteralPath $key -PathType Leaf) -or
            (Get-NativeFileSha256 $key) -cne $receipt.credentialSha256) { throw 'NATIVE_ADAPTER_FOREIGN_STATE' }
    } elseif ($null -ne $receipt.credentialSha256 -or (Test-Path -LiteralPath $key)) {
        throw 'NATIVE_ADAPTER_FOREIGN_STATE'
    }
    $null=Assert-NativeConfig $Binding
    $receipt
}

function Assert-NativeTask($Binding,$Record) {
    $null=Assert-NativeOwnedState $Binding $Record
    $task=Get-NativeTask $Binding
    if ($null -eq $task) { throw 'NATIVE_ADAPTER_TASK_MISSING' }
    $definition=New-NativeTaskDefinition $Binding $Record
    Assert-HouseholdTaskIdentity $task.xml $definition
    $task
}

function Assert-NativeInitialStateVacant($Binding) {
    foreach ($name in @(
        'settings.json','native-adapter-owner.json','task-owner.json','host.pid','codexless.pid',
        'codexless-console-owner.json','household-cleanup-state.json','stop.flag'
    )) {
        if (Test-Path -LiteralPath (Join-Path $Binding.Root $name)) { throw 'NATIVE_ADAPTER_FOREIGN_STATE' }
    }
    foreach ($directory in @('keys','tunnel-profile','tunnel-owners','tunnel-runtime')) {
        if (Test-Path -LiteralPath (Join-Path $Binding.Root $directory)) { throw 'NATIVE_ADAPTER_FOREIGN_STATE' }
    }
}

function Write-NativeInitialState($Binding,$Record) {
    Assert-NativeInitialStateVacant $Binding
    $settings=[ordered]@{
        schemaVersion=1
        project=[ordered]@{path=$Binding.ProjectPath}
        codexless=[ordered]@{root=$Binding.CodexlessRoot;nodeExe=$Binding.NodeExe;nodeSha256=$Binding.NodeSha256;port=$Binding.Port}
        tunnel=[ordered]@{enabled=$false}
    }
    if ($Binding.TunnelEnabled) {
        $keyDir=Join-Path $Binding.Root 'keys'
        $profileDir=Join-Path $Binding.Root 'tunnel-profile'
        $keyPath=Join-Path $keyDir 'runtime-key.dpapi'
        $null=New-Item -ItemType Directory -Path $keyDir -ErrorAction Stop
        $null=New-Item -ItemType Directory -Path $profileDir -ErrorAction Stop
        $cipher=$null
        $stream=$null
        try {
            $cipher=ConvertFrom-SecureString -SecureString $Binding.TunnelRuntimeKey
            $bytes=[Text.Encoding]::ASCII.GetBytes($cipher)
            $stream=[IO.File]::Open($keyPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
            $stream.Write($bytes,0,$bytes.Length)
            $stream.Flush($true)
        } finally {
            if ($stream) { $stream.Dispose() }
            $cipher=$null
        }
        $settings.tunnel=[ordered]@{
            enabled=$true
            executable=$Binding.TunnelClientExe
            profileDir='tunnel-profile'
            alias=$Binding.TunnelAlias
            tunnelId=$Binding.TunnelId
            keyFile='keys\runtime-key.dpapi'
        }
    }
    Write-NativeJson (Join-Path $Binding.Root 'settings.json') $settings -CreateNew
    $null=Assert-NativeConfig $Binding
}

function Test-NativeStopped($Binding,$Record) {
    $null=Assert-NativeTask $Binding $Record
    $definition=New-NativeTaskDefinition $Binding $Record
    $state=Get-HouseholdRuntimeState $definition
    ($state.taskState -ne 'Running' -and
        !$state.hostPresent -and !$state.listenerPresent -and !$state.tunnelPresent -and
        !$state.cleanupRequired -and !(Test-HouseholdOwnershipEvidence $Binding.Root))
}

function Remove-NativeOwnedState($Binding,$Record) {
    $receipt=Assert-NativeOwnedState $Binding $Record
    $settings=Join-Path $Binding.Root 'settings.json'
    $key=Join-Path $Binding.Root 'keys\runtime-key.dpapi'
    $stop=Join-Path $Binding.Root 'stop.flag'

    if ((Get-NativeFileSha256 $settings) -cne $receipt.settingsSha256) { throw 'NATIVE_ADAPTER_FOREIGN_STATE' }
    if ($Binding.TunnelEnabled -and (Get-NativeFileSha256 $key) -cne $receipt.credentialSha256) { throw 'NATIVE_ADAPTER_FOREIGN_STATE' }
    if (Test-Path -LiteralPath $stop) {
        $stopItem=Get-Item -LiteralPath $stop -Force
        if ($stopItem.Attributes -band [IO.FileAttributes]::ReparsePoint -or $stopItem.Length -ne 0) {
            throw 'NATIVE_ADAPTER_FOREIGN_STATE'
        }
    }

    Remove-Item -LiteralPath $settings -ErrorAction Stop
    if ($Binding.TunnelEnabled) { Remove-Item -LiteralPath $key -ErrorAction Stop }
    if (Test-Path -LiteralPath $stop) { Remove-Item -LiteralPath $stop -ErrorAction Stop }
    foreach ($directory in @((Join-Path $Binding.Root 'keys'),(Join-Path $Binding.Root 'tunnel-profile'))) {
        if ((Test-Path -LiteralPath $directory -PathType Container) -and
            (@(Get-ChildItem -LiteralPath $directory -Force).Count -eq 0)) {
            [IO.Directory]::Delete($directory,$false)
        }
    }
    Remove-Item -LiteralPath (Join-Path $Binding.Root 'native-adapter-owner.json') -ErrorAction Stop
}

function New-NativeTransactionAdapter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$ProjectPath,
        [Parameter(Mandatory=$true)][string]$CodexlessRoot,
        [Parameter(Mandatory=$true)][string]$NodeExe,
        [string]$ExpectedNodeSha256,
        [ValidateRange(1,65535)][int]$Port=7690,
        [Parameter(Mandatory=$true)][string[]]$TrustedPayloadSha256,
        [string]$DisposableTaskName,
        [string]$TunnelClientExe,
        [string]$TunnelId,
        [string]$TunnelAlias='codexless',
        [Security.SecureString]$TunnelRuntimeKey,
        [ValidateRange(1,300)][int]$ReadyTimeoutSeconds=90
    )

    if ($env:OS -cne 'Windows_NT') { throw 'NATIVE_ADAPTER_WINDOWS_REQUIRED' }
    if ($null -eq (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) -or
        $null -eq (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue) -or
        $null -eq (Get-Command Unregister-ScheduledTask -ErrorAction SilentlyContinue)) {
        Import-Module ScheduledTasks -ErrorAction Stop
    }

    if (@($TrustedPayloadSha256).Count -lt 1) { throw 'NATIVE_ADAPTER_PAYLOAD_DIGEST_INVALID' }
    $trusted=@()
    foreach ($digest in @($TrustedPayloadSha256)) {
        if ([string]$digest -cnotmatch '^[0-9a-fA-F]{64}$') { throw 'NATIVE_ADAPTER_PAYLOAD_DIGEST_INVALID' }
        $trusted += ([string]$digest).ToLowerInvariant()
    }
    $trusted=@($trusted | Sort-Object -Unique)

    $rootFull=Resolve-NativeAdapterPath $Root 'destination root'
    $parent=Split-Path $rootFull -Parent
    $null=Resolve-NativeAdapterPath $parent 'destination parent' Directory -MustExist
    $projectFull=Resolve-NativeAdapterPath $ProjectPath 'project' Directory -MustExist
    $codexlessFull=Resolve-NativeAdapterPath $CodexlessRoot 'Codexless root' Directory -MustExist
    $nodeFull=Resolve-NativeAdapterPath $NodeExe 'Node executable' File -MustExist
    $nodePolicy=Get-ArtifactPolicy node
    $nodeExpected=[string]$nodePolicy.executableSha256
    if (![string]::IsNullOrWhiteSpace($ExpectedNodeSha256)) {
        if ([string]::IsNullOrWhiteSpace($DisposableTaskName)) { throw 'NATIVE_ADAPTER_NODE_OVERRIDE_TEST_ONLY' }
        if ($ExpectedNodeSha256 -cnotmatch '^[0-9a-fA-F]{64}$') { throw 'NATIVE_ADAPTER_NODE_DIGEST_INVALID' }
        $nodeExpected=$ExpectedNodeSha256.ToLowerInvariant()
    } elseif (![string]::IsNullOrWhiteSpace($DisposableTaskName)) {
        $nodeExpected=Get-NativeFileSha256 $nodeFull
    }
    if ($nodeExpected -cnotmatch '^[0-9a-f]{64}$' -or (Get-NativeFileSha256 $nodeFull) -cne $nodeExpected) { throw 'NATIVE_ADAPTER_NODE_PROVENANCE_INVALID' }
    $powerShell=Resolve-NativeAdapterPath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') 'Windows PowerShell' File -MustExist
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ($sid -notmatch '^S-1-5-21-[0-9]+-[0-9]+-[0-9]+-[0-9]+$') { throw 'NATIVE_ADAPTER_OWNER_INVALID' }

    $defaultTaskName="Codexless-Household-$sid"
    $taskName=$defaultTaskName
    $disposable=$null
    if (![string]::IsNullOrWhiteSpace($DisposableTaskName)) {
        if ($DisposableTaskName -cnotmatch '^Codexless-NativeAdapter-Test-[0-9a-f]{32}$') {
            throw 'NATIVE_ADAPTER_TEST_TASK_NAME_INVALID'
        }
        $taskName=$DisposableTaskName
        $disposable=$DisposableTaskName
    }

    $tunnelEnabled=![string]::IsNullOrWhiteSpace($TunnelClientExe) -or
        ![string]::IsNullOrWhiteSpace($TunnelId) -or $null -ne $TunnelRuntimeKey
    $tunnelExeFull=$null
    if ($tunnelEnabled) {
        if ([string]::IsNullOrWhiteSpace($TunnelClientExe) -or
            [string]::IsNullOrWhiteSpace($TunnelId) -or $null -eq $TunnelRuntimeKey) {
            throw 'NATIVE_ADAPTER_TUNNEL_INPUT_INVALID'
        }
        $tunnelExeFull=Resolve-NativeAdapterPath $TunnelClientExe 'tunnel client' File -MustExist
        if ($TunnelAlias -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$' -or
            $TunnelId -cnotmatch '^tunnel_[A-Za-z0-9_-]+$') {
            throw 'NATIVE_ADAPTER_TUNNEL_INPUT_INVALID'
        }
    }

    $binding=[pscustomobject]@{
        Root=$rootFull
        ProjectPath=$projectFull
        CodexlessRoot=$codexlessFull
        NodeExe=$nodeFull
        NodeSha256=$nodeExpected
        Port=$Port
        TrustedPayloadSha256=$trusted
        UserSid=$sid
        PowerShellExe=$powerShell
        DefaultTaskName=$defaultTaskName
        TaskName=$taskName
        DisposableTaskName=$disposable
        TunnelEnabled=$tunnelEnabled
        TunnelClientExe=$tunnelExeFull
        TunnelId=$TunnelId
        TunnelAlias=$TunnelAlias
        TunnelRuntimeKey=$TunnelRuntimeKey
        ReadyTimeoutSeconds=$ReadyTimeoutSeconds
    }

    # GetNewClosure creates a private dynamic module. Capture module-bound helper
    # scriptblocks and commands explicitly so the adapter remains self-contained
    # when the transaction engine invokes it from another module/session state.
    $resolvePath=(Get-Command Resolve-NativeAdapterPath -CommandType Function).ScriptBlock
    $verifyStage=(Get-Command Test-NativeVerifiedStage -CommandType Function).ScriptBlock
    $getTask=(Get-Command Get-NativeTask -CommandType Function).ScriptBlock
    $assertFence=(Get-Command Assert-NativeFenceRecord -CommandType Function).ScriptBlock
    $getGeneration=(Get-Command Get-NativeGenerationPath -CommandType Function).ScriptBlock
    $writeInitial=(Get-Command Write-NativeInitialState -CommandType Function).ScriptBlock
    $newDefinitionHelper=(Get-Command New-NativeTaskDefinition -CommandType Function).ScriptBlock
    $assertNativeTask=(Get-Command Assert-NativeTask -CommandType Function).ScriptBlock
    $assertNativeConfig=(Get-Command Assert-NativeConfig -CommandType Function).ScriptBlock
    $testStopped=(Get-Command Test-NativeStopped -CommandType Function).ScriptBlock
    $readJson=(Get-Command Read-NativeJson -CommandType Function).ScriptBlock
    $writeJson=(Get-Command Write-NativeJson -CommandType Function).ScriptBlock
    $newOwnerReceipt=(Get-Command New-NativeOwnerReceipt -CommandType Function).ScriptBlock
    $removeOwnedState=(Get-Command Remove-NativeOwnedState -CommandType Function).ScriptBlock

    $assertHouseholdTaskIdentity=Get-Command Assert-HouseholdTaskIdentity -ErrorAction Stop
    $openHouseholdTaskAuthority=Get-Command Open-HouseholdTaskAuthority -ErrorAction Stop
    $registerHouseholdTaskCreateOnly=Get-Command Register-HouseholdTaskCreateOnly -ErrorAction Stop
    $unregisterScheduledTask=Get-Command Unregister-ScheduledTask -ErrorAction Stop
    $newWindowsTaskAdapter=Get-Command New-WindowsTaskAdapter -ErrorAction Stop
    $invokeHouseholdLifecycle=Get-Command Invoke-HouseholdLifecycle -ErrorAction Stop
    $getHouseholdRuntimeState=Get-Command Get-HouseholdRuntimeState -ErrorAction Stop
    $testCodexlessReady=Get-Command Test-CodexlessReady -ErrorAction Stop
    $sleepCommand=Get-Command Start-Sleep -ErrorAction Stop

    @{
        Validate={
            param($candidateRoot,$payload)
            $rootCheck=& $resolvePath $candidateRoot 'destination root'
            if ($rootCheck -ine $binding.Root) { throw 'NATIVE_ADAPTER_ROOT_MISMATCH' }
            if (!(& $verifyStage $binding $payload)) { throw 'NATIVE_ADAPTER_PAYLOAD_INVALID' }
        }.GetNewClosure()

        VerifyStage={
            param($path)
            & $verifyStage $binding $path
        }.GetNewClosure()

        GetTask={
            & $getTask $binding
        }.GetNewClosure()

        RegisterTask={
            param($generation,$record)
            $null=& $assertFence $binding $record @('install/registering')
            if ((& $resolvePath $generation 'generation' Directory -MustExist) -ine
                (& $getGeneration $binding $record)) { throw 'NATIVE_ADAPTER_GENERATION_MISMATCH' }
            if (!(& $verifyStage $binding $generation)) { throw 'NATIVE_ADAPTER_PAYLOAD_INVALID' }
            if ($null -ne (& $getTask $binding)) { throw 'NATIVE_ADAPTER_FOREIGN_TASK' }

            & $writeInitial $binding $record
            $definition=& $newDefinitionHelper $binding $record
            & $registerHouseholdTaskCreateOnly -Definition $definition
            $taskAuthority=$null
            try {
                # Pin the just-created task before adopting it into native receipt
                # authority. Delete/update/replacement remain blocked through both
                # XML proof and receipt publication.
                $taskAuthority=& $openHouseholdTaskAuthority -Definition $definition
                $registered=& $getTask $binding
                if ($null -eq $registered) { throw 'NATIVE_ADAPTER_TASK_REGISTRATION_FAILED' }
                & $assertHouseholdTaskIdentity $registered.xml $definition
                & $writeJson (Join-Path $binding.Root 'native-adapter-owner.json') (& $newOwnerReceipt $binding $record) -CreateNew
                $null=& $assertNativeTask $binding $record
            } finally { if($taskAuthority){$taskAuthority.Dispose()} }
        }.GetNewClosure()

        AssertTask={
            param($record)
            $null=& $assertNativeTask $binding $record
        }.GetNewClosure()

        Start={
            param($generation,$record)
            $null=& $assertFence $binding $record @(
                'install/starting','repair/starting','update/starting-candidate','update/restarting-prior'
            )
            if ((& $resolvePath $generation 'generation' Directory -MustExist) -ine
                (& $getGeneration $binding $record)) { throw 'NATIVE_ADAPTER_GENERATION_MISMATCH' }
            $task=& $assertNativeTask $binding $record
            if ($task.state -eq 'Running') { return }

            $definition=& $newDefinitionHelper $binding $record
            $windows=& $newWindowsTaskAdapter $definition
            $null=& $invokeHouseholdLifecycle -Action Start -Definition $definition -Adapter $windows -TimeoutSeconds $binding.ReadyTimeoutSeconds
        }.GetNewClosure()

        VerifyReady={
            param($generation,$record)
            $null=& $assertFence $binding $record @(
                'install/verifying','repair/verifying','update/verifying-candidate','update/restarting-prior'
            )
            if ((& $resolvePath $generation 'generation' Directory -MustExist) -ine
                (& $getGeneration $binding $record)) { throw 'NATIVE_ADAPTER_GENERATION_MISMATCH' }

            $deadline=[DateTime]::UtcNow.AddSeconds($binding.ReadyTimeoutSeconds)
            do {
                $null=& $assertNativeTask $binding $record
                $definition=& $newDefinitionHelper $binding $record
                $state=& $getHouseholdRuntimeState $definition
                $tunnelsReady=$true
                foreach ($tunnel in @($state.tunnels)) {
                    if (!$tunnel.ready) { $tunnelsReady=$false;break }
                }
                if ($state.taskState -eq 'Running' -and $state.ownerVerified -and
                    $state.piecesVerified -and $state.listenerPresent -and
                    !$state.cleanupRequired -and $tunnelsReady) {
                    $cfg=& $assertNativeConfig $binding
                    if (& $testCodexlessReady $cfg) { return $true }
                }
                if ([DateTime]::UtcNow -ge $deadline) { return $false }
                & $sleepCommand -Milliseconds 250
            } while ($true)
        }.GetNewClosure()

        Stop={
            param($generation,$record)
            $null=& $assertFence $binding $record @(
                'repair/stopping','uninstall/stopping','update/stopping-current','update/stopping-failed-candidate'
            )
            if ((& $resolvePath $generation 'generation' Directory -MustExist) -ine
                (& $getGeneration $binding $record)) { throw 'NATIVE_ADAPTER_GENERATION_MISMATCH' }

            $null=& $assertNativeTask $binding $record
            $definition=& $newDefinitionHelper $binding $record
            $windows=& $newWindowsTaskAdapter $definition
            $null=& $invokeHouseholdLifecycle -Action Stop -Definition $definition -Adapter $windows -TimeoutSeconds $binding.ReadyTimeoutSeconds
        }.GetNewClosure()

        VerifyStopped={
            param($record)
            $null=& $assertFence $binding $record @(
                'repair/stopping','uninstall/stopping','update/stopping-current',
                'update/stopping-failed-candidate','update/promoting-candidate'
            )
            & $testStopped $binding $record
        }.GetNewClosure()

        RemoveTask={
            param($record)
            $null=& $assertFence $binding $record @('uninstall/unregistering')
            if (!(& $testStopped $binding $record)) { throw 'NATIVE_ADAPTER_STOP_UNPROVEN' }
            $null=& $assertNativeTask $binding $record

            $definition=& $newDefinitionHelper $binding $record
            $taskAuthority=$null
            try {
                # Allow only delete sharing while the exact task file is held.
                # A raced update/re-registration cannot replace the proven task
                # before Scheduler removes it, and recreation is blocked until
                # owned state retirement completes.
                $taskAuthority=& $openHouseholdTaskAuthority -Definition $definition -AllowDelete
                $task=& $getTask $binding
                if ($null -eq $task) { throw 'NATIVE_ADAPTER_TASK_MISSING' }
                & $assertHouseholdTaskIdentity $task.xml $definition
                & $unregisterScheduledTask -TaskName $binding.TaskName -TaskPath '\' -Confirm:$false -ErrorAction Stop
                if ($null -ne (& $getTask $binding)) { throw 'NATIVE_ADAPTER_TASK_REMOVE_UNPROVEN' }
                & $removeOwnedState $binding $record
            } finally { if($taskAuthority){$taskAuthority.Dispose()} }
        }.GetNewClosure()

        Promote={
            param($generation,$record)
            $null=& $assertFence $binding $record @('update/promoting-candidate','update/restoring-prior')
            if ((& $resolvePath $generation 'generation' Directory -MustExist) -ine
                (& $getGeneration $binding $record)) { throw 'NATIVE_ADAPTER_GENERATION_MISMATCH' }
            if (!(& $verifyStage $binding $generation)) { throw 'NATIVE_ADAPTER_PAYLOAD_INVALID' }

            $current=& $readJson (Join-Path $binding.Root 'install-owner.json')
            $null=& $assertNativeTask $binding $current
            if (!(& $testStopped $binding $current)) { throw 'NATIVE_ADAPTER_STOP_UNPROVEN' }

            $currentDefinition=& $newDefinitionHelper $binding $current
            $currentAuthority=$null
            try {
                # Linearize retirement against the exact currently-owned task file.
                # Same-name update/re-registration is blocked until Scheduler has
                # removed that object and this handle is released.
                $currentAuthority=& $openHouseholdTaskAuthority -Definition $currentDefinition -AllowDelete
                $existing=& $getTask $binding
                if ($null -eq $existing) { throw 'NATIVE_ADAPTER_TASK_MISSING' }
                & $assertHouseholdTaskIdentity $existing.xml $currentDefinition
                & $unregisterScheduledTask -TaskName $binding.TaskName -TaskPath '\' -Confirm:$false -ErrorAction Stop
                if ($null -ne (& $getTask $binding)) { throw 'NATIVE_ADAPTER_TASK_REMOVE_UNPROVEN' }
            } finally { if($currentAuthority){$currentAuthority.Dispose()} }

            # Registration is create-only. A foreign task that wins the gap after
            # exact retirement makes this fail closed instead of being overwritten.
            $newTaskDefinition=& $newDefinitionHelper $binding $record
            & $registerHouseholdTaskCreateOnly -Definition $newTaskDefinition
            $newAuthority=$null
            try {
                # Pin the candidate through XML proof and native receipt adoption.
                $newAuthority=& $openHouseholdTaskAuthority -Definition $newTaskDefinition
                $newTask=& $getTask $binding
                if ($null -eq $newTask) { throw 'NATIVE_ADAPTER_TASK_REGISTRATION_FAILED' }
                & $assertHouseholdTaskIdentity $newTask.xml $newTaskDefinition
                & $writeJson (Join-Path $binding.Root 'native-adapter-owner.json') (& $newOwnerReceipt $binding $record)
                $null=& $assertNativeTask $binding $record
            } finally { if($newAuthority){$newAuthority.Dispose()} }
        }.GetNewClosure()
    }
}

Export-ModuleMember -Function New-NativeTransactionAdapter
