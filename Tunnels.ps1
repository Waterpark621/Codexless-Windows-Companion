param(
    [Parameter(Mandatory=$true)][string]$Root,
    [ValidateSet('List','Status','Add','Remove','RotateKey')][string]$Action='List',
    [string]$ProfileId,
    [string]$Alias,
    [string]$TunnelId,
    [string]$TunnelClientExe,
    [Security.SecureString]$RuntimeApiKey,
    [switch]$Disabled,
    [string]$DisposableTaskName
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'NativeTransactionAdapter.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'InstallTransaction.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'VerifiedTunnel.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'CompanionRuntime.psm1') -DisableNameChecking

$cfg=Get-CompanionConfig $Root
if($Action -in @('List','Status')){
    foreach($tunnel in @(Get-ConfiguredTunnels $cfg -IncludeDisabled)){
        $alive=$false;$ready=$false;$owned=$false;$known=$false
        if($Action -ceq 'Status'){
            $status=Get-TunnelStatus $cfg $tunnel
            if($null -ne $status){
                $known=$true;$alive=$status.process_running
                $ready=Test-TunnelReady $cfg $tunnel
                if($alive){try {$owned=Test-OwnedTunnel $cfg.companionRoot $cfg $tunnel $status}catch {$owned=$false}}
            }
        }
        [pscustomobject]@{profileId=$tunnel.profileId;alias=$tunnel.alias;tunnelId=$tunnel.tunnelId;enabled=$tunnel.enabled;statusKnown=$known;alive=$alive;ready=$ready;owned=$owned}
    }
    return
}

# Mutation requires the current installed payload, not an arbitrary source checkout.
$record=Get-Content -LiteralPath (Join-Path $cfg.companionRoot 'install-owner.json') -Raw | ConvertFrom-Json
if([string]$record.generationId -cnotmatch '^[0-9a-f]{32}$'){throw 'TUNNEL_PROFILE_INSTALL_INVALID'}
$generation=Join-Path (Join-Path $cfg.companionRoot 'generations') $record.generationId
if([IO.Path]::GetFullPath($PSScriptRoot) -ine [IO.Path]::GetFullPath($generation)){throw 'TUNNEL_PROFILES_USE_INSTALLED_GENERATION'}
if($Action -ceq 'Add' -and [string]::IsNullOrWhiteSpace($ProfileId)){$ProfileId=[Guid]::NewGuid().ToString('N')}
if($Action -in @('Add','RotateKey') -and $null -eq $RuntimeApiKey){$RuntimeApiKey=Read-Host 'Runtime API key for this tunnel (current PC only)' -AsSecureString}
try {
    $adapter=New-NativeTransactionAdapter -Root $cfg.companionRoot -ProjectPath $cfg.projectPath -CodexlessRoot $cfg.codexlessRoot -NodeExe $cfg.nodeExe -Port $cfg.port -TrustedPayloadSha256 @([string]$record.payloadSha256) -DisposableTaskName $DisposableTaskName
    $request=[pscustomobject]@{Action=$Action;ProfileId=$ProfileId;Alias=$Alias;TunnelId=$TunnelId;TunnelClientExe=$TunnelClientExe;RuntimeKey=$RuntimeApiKey;Enabled=(!$Disabled)}
    Invoke-OwnedTunnelProfiles -Root $cfg.companionRoot -Adapter $adapter -Request $request
} finally {$RuntimeApiKey=$null;$request=$null}
