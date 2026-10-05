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
    [switch]$PlanOnly
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

function Resolve-InputPath {
    param([string]$Value,[string]$Label,[ValidateSet('File','Directory')][string]$Kind)
    if([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch '^[A-Za-z]:[\\/]'){
        throw "INSTALL_INPUT_INVALID: $Label must be a fully-qualified local drive path."
    }
    if($Value.Contains('"') -or $Value.Contains([char]13) -or $Value.Contains([char]10)){
        throw "INSTALL_INPUT_INVALID: $Label contains unsupported characters."
    }
    $full=[IO.Path]::GetFullPath($Value)
    $driveRoot=[IO.Path]::GetPathRoot($full)
    if($full.Length -gt $driveRoot.Length){
        $full=$full.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    }
    if($Kind -eq 'File' -and !(Test-Path -LiteralPath $full -PathType Leaf)){
        throw "INSTALL_INPUT_INVALID: $Label must be an existing file."
    }
    if($Kind -eq 'Directory' -and !(Test-Path -LiteralPath $full -PathType Container)){
        throw "INSTALL_INPUT_INVALID: $Label must be an existing directory."
    }
    $full
}

$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if($sid -notmatch '^S-1-5-21-[0-9]+-[0-9]+-[0-9]+-[0-9]+$'){
    throw 'INSTALL_IDENTITY_INVALID: A normal Windows user SID is required.'
}

$codexlessRoot=Resolve-InputPath $CodexlessRoot 'CodexlessRoot' Directory
$projectPath=Resolve-InputPath $ProjectPath 'ProjectPath' Directory
$installFull=[IO.Path]::GetFullPath($InstallDirectory)
if($installFull -notmatch '^[A-Za-z]:[\\/]'){
    throw 'INSTALL_INPUT_INVALID: InstallDirectory must be a fully-qualified local drive path.'
}
$installDriveRoot=[IO.Path]::GetPathRoot($installFull)
$installDirectory=if($installFull.Length -gt $installDriveRoot.Length){
    $installFull.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
}else{$installFull}

Import-Module (Join-Path $PSScriptRoot 'CompanionRuntime.psm1') -Force
$release=Get-CodexlessReleaseIdentity $codexlessRoot

if([string]::IsNullOrWhiteSpace($NodeExe)){
    $node=(Get-Command node.exe -ErrorAction Stop)
    $nodeExeResolved=Resolve-InputPath $node.Source 'node.exe' File
}else{
    $nodeExeResolved=Resolve-InputPath $NodeExe 'NodeExe' File
}

$tunnelPlan=[pscustomobject]@{enabled=$false}
if(!$NoTunnel){
    $tunnelExeResolved=Resolve-InputPath $TunnelClientExe 'TunnelClientExe' File
    if($TunnelAlias -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$'){
        throw 'INSTALL_INPUT_INVALID: TunnelAlias is invalid.'
    }
    if([string]::IsNullOrWhiteSpace($TunnelId) -or $TunnelId -notmatch '^tunnel_[A-Za-z0-9_-]+$'){
        throw 'INSTALL_INPUT_INVALID: TunnelId must be an existing tunnel_... identifier.'
    }
    $tunnelPlan=[pscustomobject]@{
        enabled=$true
        alias=$TunnelAlias
        tunnelId=$TunnelId
        executable=$tunnelExeResolved
        credentialStorage='planned: current-user Windows DPAPI under Companion install root'
        automaticConnect='disabled in public preview pending launch-provenance qualification'
    }
}

$plan=[pscustomobject]@{
    preview=$true
    mutatingInstallEnabled=$false
    installDirectory=$installDirectory
    taskName=("Codexless-Household-"+$sid)
    userSid=$sid
    codexless=[pscustomobject]@{
        version=$release.version
        buildId=$release.buildId
        sourceRevision=$release.sourceRevision
        manifestSha256=$release.manifestSha256
        hostContractVersion=$release.hostContractVersion
        root=$release.root
    }
    projectPath=$projectPath
    nodeExe=$nodeExeResolved
    port=$Port
    tunnel=$tunnelPlan
    blockers=@(
        'tunnel launch provenance',
        'repair/uninstall/update rollback',
        'clean second-user/machine acceptance'
    )
}

if($PlanOnly){
    $plan|ConvertTo-Json -Depth 7
    exit 0
}

throw 'INSTALL_DISABLED_PUBLIC_PREVIEW: Mutating installation is intentionally disabled. Re-run with -PlanOnly to inspect the proposed destination and dependencies.'
