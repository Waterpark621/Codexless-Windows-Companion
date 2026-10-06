Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'ArtifactProvenance.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'InstallTransaction.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'NativeTransactionAdapter.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'BoundedNative.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'MutationLock.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'CompanionRuntime.psm1') -DisableNameChecking

function Resolve-PublicInstallPath([string]$Path,[string]$Kind='Any') {
    if([string]::IsNullOrWhiteSpace($Path) -or $Path -notmatch '^[A-Za-z]:[\\/]' -or $Path -match '["\r\n]'){throw 'INSTALL_INPUT_INVALID'}
    $full=[IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    if($full.Length -le 3){throw 'INSTALL_INPUT_INVALID'}
    $cursor=$full
    while($cursor){
        if(Test-Path -LiteralPath $cursor){if((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'INSTALL_REPARSE_POINT'}}
        $cursor=Split-Path $cursor -Parent
    }
    if($Kind -ne 'Any' -and !(Test-Path -LiteralPath $full -PathType $Kind)){throw 'INSTALL_INPUT_INVALID'}
    $full
}

function Assert-PublicInstallPrerequisites {
    if($env:OS -cne 'Windows_NT' -or !$([Environment]::Is64BitOperatingSystem) -or !$([Environment]::Is64BitProcess) -or $PSVersionTable.PSVersion.Major -lt 5){throw 'INSTALL_WINDOWS_X64_REQUIRED'}
    if([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -notmatch '^S-1-5-21-[0-9]+-[0-9]+-[0-9]+-[0-9]+$'){throw 'INSTALL_USER_REQUIRED'}
    foreach($name in @('Get-ScheduledTask','Register-ScheduledTask','Unregister-ScheduledTask')){
        if(!(Get-Command $name -ErrorAction SilentlyContinue)){throw 'INSTALL_SCHEDULER_REQUIRED'}
    }
}

function Stage-PublicInstallBinary([string]$Role,[string]$Directory) {
    $policy=Get-ArtifactPolicy $Role
    $download=Save-QualifiedArtifact $Role $Directory
    $expanded=Expand-QualifiedArtifact $Role $download.archivePath (Join-Path $Directory 'expanded')
    Join-Path $expanded.stagedRoot $policy.executableRelativePath
}

function Initialize-PublicCodexlessRuntime([string]$Root,[string]$QualifiedNode) {
    # npm comes from the same hash-verified Node archive, not a PATH npm shim.
    $npm=Join-Path (Split-Path $QualifiedNode -Parent) 'node_modules\npm\bin\npm-cli.js'
    $userConfig=Join-Path (Split-Path $Root -Parent) 'empty-npmrc'
    [IO.File]::WriteAllText($userConfig,'',[Text.UTF8Encoding]::new($false))
    $policy=Get-ArtifactPolicy node
    $oldOptions=$env:NODE_OPTIONS
    try {
        $env:NODE_OPTIONS=$null
        $result=Invoke-BoundedNative $QualifiedNode $policy.executableSha256 @($npm,'ci','--omit=dev','--ignore-scripts','--no-audit','--no-fund','--userconfig',$userConfig,'--cache',(Join-Path (Split-Path $Root -Parent) 'npm-cache')) $Root -TimeoutMs 30000
        if(!$result.Ok){throw 'INSTALL_DEPENDENCIES_FAILED'}
        # Dependency installation may add node_modules but cannot change controlled bytes.
        $null=Get-CodexlessReleaseIdentity $Root
    } finally { $env:NODE_OPTIONS=$oldOptions;$result=$null }
}

function Invoke-PublicInstallDoctor([string]$Generation,[string]$Root) {
    $raw=& (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Generation 'Doctor.ps1') -InstallDirectory $Root -Json 2>$null
    if($LASTEXITCODE -ne 0){return $false}
    try {$r=($raw|Out-String)|ConvertFrom-Json -ErrorAction Stop;return ($r.ok -eq $true -and $r.verdict -ceq 'PASS')}catch{return $false}
}

function New-PublicInstallServices {
    # Internal boundaries are replaced only in deterministic fixture module scopes.
    # The public script exposes no adapter, task-name, policy or verifier overrides.
    @{
        Prerequisites=(Get-Command Assert-PublicInstallPrerequisites).ScriptBlock
        Policy=(Get-Command Get-ArtifactPolicy)
        Stage=(Get-Command Stage-QualifiedCodexlessDistribution)
        StageArchive=(Get-Command Stage-QualifiedCodexlessArchive)
        Binary=(Get-Command Stage-PublicInstallBinary).ScriptBlock
        Provision=(Get-Command Initialize-PublicCodexlessRuntime).ScriptBlock
        Adapter=(Get-Command New-NativeTransactionAdapter)
        Doctor=(Get-Command Invoke-PublicInstallDoctor).ScriptBlock
        Config=(Get-Command Get-CompanionConfig)
    }
}

function Invoke-PublicCompanionInstall {
    param(
        [string]$PayloadRoot,[string]$TrustedPayloadSha256,[string]$InstallDirectory,[string]$ProjectPath,
        [string]$NodeExe,[ValidateRange(1,65535)][int]$Port=7690,[string]$CodexlessArchivePath,
        [string]$TunnelClientExe,[string]$TunnelId,[string]$TunnelAlias='codexless',
        [Security.SecureString]$TunnelRuntimeKey,[switch]$NoTunnel,[switch]$Recover
    )
    $services=New-PublicInstallServices
    # Unpublished or incomplete metadata refuses before any directory or key mutation.
    $policy=& $services.Policy codexless
    & $services.Prerequisites
    if($TrustedPayloadSha256 -cnotmatch '^[0-9a-f]{64}$'){throw 'INSTALL_TRUSTED_PAYLOAD_REQUIRED: Use the payload digest from the authenticated Companion release notes.'}
    $payload=Resolve-PublicInstallPath $PayloadRoot Container
    if((Get-TransactionTreeDigest $payload) -cne $TrustedPayloadSha256){throw 'INSTALL_PAYLOAD_PROVENANCE_INVALID'}
    $root=Resolve-PublicInstallPath $InstallDirectory
    $parent=Resolve-PublicInstallPath (Split-Path $root -Parent) Container
    $project=Resolve-PublicInstallPath $ProjectPath Container
    if($root -ieq $payload -or $root.StartsWith($payload+'\',[StringComparison]::OrdinalIgnoreCase) -or $payload.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase) -or $root -ieq $project -or $root.StartsWith($project+'\',[StringComparison]::OrdinalIgnoreCase) -or $project.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'INSTALL_ROOT_OVERLAP'}
    if($NoTunnel -and ($TunnelClientExe -or $TunnelId -or $null -ne $TunnelRuntimeKey)){throw 'INSTALL_TUNNEL_INPUT_INVALID'}
    $tunnelEnabled=($TunnelClientExe -or $TunnelId -or $null -ne $TunnelRuntimeKey)
    if($tunnelEnabled -and ($TunnelAlias -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$' -or $TunnelId -cnotmatch '^tunnel_[A-Za-z0-9_-]+$')){throw 'INSTALL_TUNNEL_INPUT_INVALID'}
    if($null -ne $TunnelRuntimeKey -and $TunnelRuntimeKey.Length -lt 1){throw 'INSTALL_TUNNEL_INPUT_INVALID'}
    $parameters=@{Root=$root;ProjectPath=$project;Port=$Port;TrustedPayloadSha256=@($TrustedPayloadSha256)}
    Invoke-CompanionMutationLocked $root {
    if($Recover){
        if($null -ne $TunnelRuntimeKey){throw 'INSTALL_RECOVERY_SETTINGS_MISMATCH'}
        if(!(Test-Path -LiteralPath (Join-Path $root 'incomplete-install.json') -PathType Leaf)){throw 'INSTALL_RECOVERY_EVIDENCE_REQUIRED'}
        $cfg=& $services.Config $root
        if($cfg.projectPath -ine $project -or $cfg.port -ne $Port -or @($cfg.tunnels).Count -gt 1){throw 'INSTALL_RECOVERY_SETTINGS_MISMATCH'}
        if($NodeExe -and [IO.Path]::GetFullPath($NodeExe) -ine $cfg.nodeExe){throw 'INSTALL_RECOVERY_SETTINGS_MISMATCH'}
        $parameters.NodeExe=$cfg.nodeExe;$parameters.CodexlessRoot=$cfg.codexlessRoot
        if(@($cfg.tunnels).Count){
            $t=$cfg.tunnels[0]
            if(($TunnelId -and $TunnelId -cne $t.tunnelId) -or $NoTunnel){throw 'INSTALL_RECOVERY_SETTINGS_MISMATCH'}
            $parameters.TunnelClientExe=$cfg.tunnelExe;$parameters.TunnelId=$t.tunnelId;$parameters.TunnelAlias=$t.alias
            $parameters.TunnelRuntimeKey=ConvertTo-SecureString ((Get-Content -LiteralPath $t.keyPath -Raw -ErrorAction Stop).Trim())
        }
    } else {
        # Never repair/adopt an existing root or overwrite an existing transaction.
        if(Test-Path -LiteralPath $root){
            if((Test-Path -LiteralPath (Join-Path $root 'install-owner.json')) -or (Test-Path -LiteralPath (Join-Path $root 'incomplete-install.json')) -or !(Test-Path -LiteralPath (Join-Path $root 'uninstalled-owner.json'))){throw 'TRANSACTION_DESTINATION_EXISTS'}
        }
        $stage=Join-Path $parent ('.companion-dependencies-'+[Guid]::NewGuid().ToString('N'))
        if($CodexlessArchivePath){
            $archive=Resolve-PublicInstallPath $CodexlessArchivePath Leaf
            $qualified=& $services.StageArchive $archive (Join-Path $stage 'codexless')
        } else {$qualified=& $services.Stage (Join-Path $stage 'codexless')}
        $qualifiedNode=& $services.Binary node (Join-Path $stage 'node')
        if($NodeExe){
            $NodeExe=Resolve-PublicInstallPath $NodeExe Leaf
            $nodePolicy=& $services.Policy node
            if((Get-FileHash -LiteralPath $NodeExe -Algorithm SHA256).Hash.ToLowerInvariant() -cne $nodePolicy.executableSha256){throw 'INSTALL_NODE_PROVENANCE_INVALID'}
        } else {$NodeExe=$qualifiedNode}
        & $services.Provision $qualified.stagedRoot $qualifiedNode
        $parameters.NodeExe=$NodeExe;$parameters.CodexlessRoot=$qualified.stagedRoot
        if($tunnelEnabled){
            if(!$TunnelClientExe){$TunnelClientExe=& $services.Binary tunnel (Join-Path $stage 'tunnel')}
            $parameters.TunnelClientExe=Resolve-PublicInstallPath $TunnelClientExe Leaf
            $tunnelPolicy=& $services.Policy tunnel
            if((Get-FileHash -LiteralPath $parameters.TunnelClientExe -Algorithm SHA256).Hash.ToLowerInvariant() -cne $tunnelPolicy.executableSha256){throw 'INSTALL_TUNNEL_PROVENANCE_INVALID'}
            if($null -eq $TunnelRuntimeKey){$TunnelRuntimeKey=Read-Host 'Runtime API key for this tunnel (current PC only)' -AsSecureString}
            if($null -eq $TunnelRuntimeKey -or $TunnelRuntimeKey.Length -lt 1){throw 'INSTALL_TUNNEL_INPUT_INVALID'}
            $parameters.TunnelId=$TunnelId;$parameters.TunnelAlias=$TunnelAlias;$parameters.TunnelRuntimeKey=$TunnelRuntimeKey
        }
    }
    try {
        $adapter=& $services.Adapter @parameters
        $verify=$adapter.VerifyReady;$doctor=$services.Doctor
        $adapter.VerifyReady={param($generation,$record) if(!(& $verify $generation $record)){return $false}; & $doctor $generation $root}.GetNewClosure()
        if($Recover){$result=Invoke-VerifiedIncompleteInstallRecovery -Root $root -Adapter $adapter}
        else {$result=Invoke-InstallTransaction -Root $root -Payload $payload -Adapter $adapter}
        [pscustomobject]@{state=$result.state;verified=$result.verified;doctorVerdict='PASS';transactionId=$result.transactionId;distributionBuildId=$policy.buildId}
    } finally {$TunnelRuntimeKey=$null;$parameters.TunnelRuntimeKey=$null;$adapter=$null}
    }
}

Export-ModuleMember -Function Invoke-PublicCompanionInstall
