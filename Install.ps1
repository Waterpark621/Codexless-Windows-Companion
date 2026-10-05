param(
    [Parameter(Mandatory=$true)][string]$CodexlessRoot,
    [Parameter(Mandatory=$true)][string]$ProjectPath,
    [string]$NodeExe,
    [ValidateRange(1,65535)][int]$Port=7690,
    [string]$InstallDirectory=(Join-Path $env:LOCALAPPDATA 'CodexlessCompanion'),
    [switch]$NoTunnel,
    [string]$TunnelClientExe,
    [string]$TunnelId,
    [string]$TunnelAlias='codexless',
    [SecureString]$RuntimeApiKey,
    [switch]$PlanOnly
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

function Resolve-InputPath([string]$Value,[string]$Label,[ValidateSet('File','Directory')][string]$Kind) {
    $sep=[IO.Path]::DirectorySeparatorChar
    $uncPrefix=[string]$sep+[string]$sep
    if([string]::IsNullOrWhiteSpace($Value)-or![IO.Path]::IsPathRooted($Value)-or$Value.StartsWith($uncPrefix,[StringComparison]::Ordinal)){
        throw "INSTALL_INPUT_INVALID: $Label must be an absolute local path."
    }
    $full=[IO.Path]::GetFullPath($Value).TrimEnd($sep)
    if($Kind -eq 'File' -and !(Test-Path -LiteralPath $full -PathType Leaf)){throw "INSTALL_INPUT_INVALID: $Label must be an existing file."}
    if($Kind -eq 'Directory' -and !(Test-Path -LiteralPath $full -PathType Container)){throw "INSTALL_INPUT_INVALID: $Label must be an existing directory."}
    $full
}

function Test-IsAdministrator {
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PayloadFiles {
    @(
        'CompanionRuntime.psm1','Household-Host.ps1','Household-Task.ps1','PrivateConsole.psm1',
        'Signal-PrivateConsole.ps1','Task-Host.ps1','UserSessionTask.psm1','VerifiedTunnel.psm1',
        'WindowsTaskAdapter.psm1','PriorBootOwnership.psm1','Start.ps1','Stop.ps1','Restart.ps1',
        'Status.ps1','Doctor.ps1','COMPATIBILITY.json','VERSION'
    )
}

function Get-SecureStringLength([SecureString]$Value) {
    if($null -eq $Value){return 0}
    $Value.Length
}

if(Test-IsAdministrator){
    throw 'INSTALL_ELEVATION_NOT_SUPPORTED: Run Install.ps1 from a normal interactive PowerShell window.'
}

$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if($sid -notmatch '^S-1-5-21-[0-9]+-[0-9]+-[0-9]+-[0-9]+$'){
    throw 'INSTALL_IDENTITY_INVALID: A normal Windows user SID is required.'
}

$codexlessRoot=Resolve-InputPath $CodexlessRoot 'CodexlessRoot' Directory
$projectPath=Resolve-InputPath $ProjectPath 'ProjectPath' Directory

$installFull=[IO.Path]::GetFullPath($InstallDirectory)
$installParent=Split-Path $installFull -Parent
if([string]::IsNullOrWhiteSpace($installParent)){throw 'INSTALL_INPUT_INVALID: InstallDirectory is invalid.'}
$sep=[IO.Path]::DirectorySeparatorChar
$installDirectory=$installFull.TrimEnd($sep)
$uncPrefix=[string]$sep+[string]$sep
if($installDirectory.StartsWith($uncPrefix,[StringComparison]::Ordinal)){
    throw 'INSTALL_INPUT_INVALID: Network install directories are not supported.'
}

Import-Module (Join-Path $PSScriptRoot 'CompanionRuntime.psm1') -Force
$release=Get-CodexlessReleaseIdentity $codexlessRoot

if([string]::IsNullOrWhiteSpace($NodeExe)){
    $node=(Get-Command node.exe -ErrorAction Stop)
    $nodeExeResolved=Resolve-InputPath $node.Source 'node.exe' File
}else{
    $nodeExeResolved=Resolve-InputPath $NodeExe 'NodeExe' File
}

$tunnel=$null
if(!$NoTunnel){
    $tunnelExeResolved=Resolve-InputPath $TunnelClientExe 'TunnelClientExe' File
    if($TunnelAlias -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$'){throw 'INSTALL_INPUT_INVALID: TunnelAlias is invalid.'}
    if([string]::IsNullOrWhiteSpace($TunnelId) -or $TunnelId -notmatch '^tunnel_[A-Za-z0-9_-]+$'){
        throw 'INSTALL_INPUT_INVALID: TunnelId must be an existing tunnel_... identifier.'
    }
    if(!$PlanOnly -and (Get-SecureStringLength $RuntimeApiKey) -eq 0){
        $RuntimeApiKey=Read-Host 'Paste the destination user runtime API key (stored only as Windows DPAPI ciphertext)' -AsSecureString
    }
    if(!$PlanOnly -and (Get-SecureStringLength $RuntimeApiKey) -eq 0){
        throw 'INSTALL_INPUT_INVALID: Runtime API key is required when tunnel support is enabled.'
    }
    $tunnel=[ordered]@{
        enabled=$true
        executable=$tunnelExeResolved
        profileDir='tunnel-profile'
        alias=$TunnelAlias
        tunnelId=$TunnelId
        keyFile='keys/runtime-key.dpapi'
    }
}

$taskName="Codexless-Household-$sid"
if(Test-Path -LiteralPath $installDirectory){
    if(@(Get-ChildItem -LiteralPath $installDirectory -Force -ErrorAction Stop).Count -gt 0){
        throw 'INSTALL_EXISTING_DIRECTORY: Destination is not empty; use Repair/Update rather than fresh Install.'
    }
}

$settings=[ordered]@{
    schemaVersion=1
    project=[ordered]@{path=$projectPath}
    codexless=[ordered]@{root=$codexlessRoot;nodeExe=$nodeExeResolved;port=$Port}
    tunnel=if($NoTunnel){[ordered]@{enabled=$false}}else{$tunnel}
}

$plan=[pscustomobject]@{
    installDirectory=$installDirectory
    taskName=$taskName
    userSid=$sid
    codexless=[pscustomobject]@{
        version=$release.version
        buildId=$release.buildId
        hostContractVersion=$release.hostContractVersion
        root=$release.root
    }
    projectPath=$projectPath
    nodeExe=$nodeExeResolved
    port=$Port
    tunnel=if($NoTunnel){
        [pscustomobject]@{enabled=$false}
    }else{
        [pscustomobject]@{
            enabled=$true
            alias=$TunnelAlias
            tunnelId=$TunnelId
            executable=$tunnelExeResolved
            credentialStorage='Windows DPAPI in install directory'
        }
    }
}

if($PlanOnly){
    $plan|ConvertTo-Json -Depth 7
    exit 0
}

$taskRoot=[string][char]92
$existingTask=Get-ScheduledTask -TaskName $taskName -TaskPath $taskRoot -ErrorAction SilentlyContinue
if($null -ne $existingTask){
    throw 'INSTALL_EXISTING_TASK: A Codexless household task already exists; use Repair/Update rather than fresh Install.'
}

$stage=Join-Path $installParent ('.CodexlessCompanion-stage-'+[Guid]::NewGuid().ToString('N'))
$installed=$false
try{
    New-Item -ItemType Directory -Force -Path $stage|Out-Null
    foreach($name in Get-PayloadFiles){
        $source=Join-Path $PSScriptRoot $name
        if(!(Test-Path -LiteralPath $source -PathType Leaf)){
            throw "INSTALL_PACKAGE_INVALID: Missing payload file $name."
        }
        Copy-Item -LiteralPath $source -Destination (Join-Path $stage $name) -Force
    }

    New-Item -ItemType Directory -Force -Path (Join-Path $stage 'keys'),(Join-Path $stage 'tunnel-profile'),(Join-Path $stage 'logs')|Out-Null
    $settings|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $stage 'settings.json') -Encoding utf8

    if(!$NoTunnel){
        $keyPath=Join-Path (Join-Path $stage 'keys') 'runtime-key.dpapi'
        ConvertFrom-SecureString -SecureString $RuntimeApiKey|Set-Content -LiteralPath $keyPath -Encoding ascii
    }

    Import-Module (Join-Path $stage 'CompanionRuntime.psm1') -Force
    $stagedCfg=Get-CompanionConfig $stage
    if($stagedCfg.release.buildId -cne $release.buildId){
        throw 'INSTALL_STAGE_INVALID: Release identity changed during staging.'
    }

    if(!(Test-Path -LiteralPath $installParent)){
        New-Item -ItemType Directory -Force -Path $installParent|Out-Null
    }
    if(Test-Path -LiteralPath $installDirectory){
        if(@(Get-ChildItem -LiteralPath $installDirectory -Force).Count -ne 0){
            throw 'INSTALL_DESTINATION_CHANGED'
        }
        Remove-Item -LiteralPath $installDirectory -Force
    }

    Move-Item -LiteralPath $stage -Destination $installDirectory
    $installed=$true

    $ownerSid=(Get-Acl -LiteralPath (Join-Path $installDirectory 'settings.json')).GetOwner([Security.Principal.SecurityIdentifier]).Value
    if($ownerSid -cne $sid){
        throw 'INSTALL_OWNER_INVALID: Installed settings are not owned by the current user.'
    }

    $registered=((& (Join-Path $installDirectory 'Household-Task.ps1') -Action Register -LauncherDirectory $installDirectory|Out-String).Trim()|ConvertFrom-Json)
    if($registered.state -cne 'registered'){throw 'INSTALL_TASK_REGISTER_FAILED'}

    $started=((& (Join-Path $installDirectory 'Household-Task.ps1') -Action Start -LauncherDirectory $installDirectory|Out-String).Trim()|ConvertFrom-Json)
    if($started.state -notin @('starting','already-running')){throw 'INSTALL_START_FAILED'}

    $deadline=(Get-Date).AddSeconds(90)
    $ok=$false
    do{
        Start-Sleep -Seconds 2
        try{
            $raw=(& (Join-Path $installDirectory 'Doctor.ps1') -InstallDirectory $installDirectory -Json|Out-String).Trim()
            $doctor=$raw|ConvertFrom-Json
            $blocking=@($doctor.checks|Where-Object {$_.state -eq 'FAIL'})
            if($blocking.Count -eq 0){$ok=$true;break}
        }catch{}
    }while((Get-Date)-lt$deadline)

    if(!$ok){
        throw 'INSTALL_VALIDATION_FAILED: Installed files/task are retained for fail-closed diagnosis; no process was force-killed or adopted.'
    }

    [pscustomobject]@{
        installed=$true
        installDirectory=$installDirectory
        taskName=$taskName
        codexlessVersion=$release.version
        codexlessBuildId=$release.buildId
        tunnelEnabled=(-not $NoTunnel)
        doctor='PASS_WITH_BROWSER_PROBE_PENDING'
    }|ConvertTo-Json -Depth 5
}catch{
    if(!$installed){
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
    throw
}
