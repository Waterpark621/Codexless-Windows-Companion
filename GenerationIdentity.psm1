Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'CompanionRuntime.psm1')

function Get-GenerationDigest([string]$Text) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-CompanionGenerationContract($Config) {
    try {
        $release=$Config.release
        foreach($field in @('version','buildId','sourceRevision','manifestSha256','hostContractVersion')) {
            if([string]::IsNullOrWhiteSpace([string]$release.$field)){throw 'invalid'}
        }
        if($release.buildId -cnotmatch '^[0-9a-f]{64}$' -or $release.sourceRevision -cnotmatch '^[0-9a-f]{40}$' -or $release.manifestSha256 -cnotmatch '^[0-9a-f]{64}$'){throw 'invalid'}
        $files=@(Get-ChildItem -LiteralPath $PSScriptRoot -File | Where-Object {$_.Extension -in @('.ps1','.psm1','.mjs') -or $_.Name -eq 'VERSION'} | Sort-Object Name | ForEach-Object {
            if($_.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'invalid'}
            [ordered]@{name=$_.Name;sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
        })
        if(!$files.Count){throw 'invalid'}
        $tunnels=@($Config.tunnels | Sort-Object alias | ForEach-Object {
            [ordered]@{alias=[string]$_.alias;tunnelId=[string]$_.tunnelId;enabled=[bool]$_.enabled;keyPath=[string]$_.keyPath}
        })
        $canonical=[ordered]@{
            contractVersion=1
            release=[ordered]@{version=[string]$release.version;buildId=[string]$release.buildId;sourceRevision=[string]$release.sourceRevision;manifestSha256=[string]$release.manifestSha256;hostContractVersion=[string]$release.hostContractVersion}
            settingsSha256=(Get-FileHash -LiteralPath $Config.settingsPath -Algorithm SHA256).Hash.ToLowerInvariant()
            projectPath=[string]$Config.projectPath
            codexlessRoot=[string]$Config.codexlessRoot
            nodeExe=[string]$Config.nodeExe
            port=[int]$Config.port
            launchCommand=(Get-CodexlessPrivateConsoleCommand $Config)
            tunnelExe=[string]$Config.tunnelExe
            profileDir=[string]$Config.profileDir
            tunnels=$tunnels
            companionFiles=$files
        }
        # Private paths/configuration exist only in this local canonical buffer.
        $json=$canonical | ConvertTo-Json -Depth 12 -Compress
        [pscustomobject]@{version=1;sha256=(Get-GenerationDigest $json)}
    } catch { throw 'GENERATION_CONTRACT_INVALID: Generation identity cannot be established.' }
    finally { $canonical=$null;$json=$null }
}

function Assert-CompanionGenerationContract($Saved,$Config) {
    try {
        if($null -eq $Saved -or $Saved.version -ne 1 -or [string]$Saved.sha256 -cnotmatch '^[0-9a-f]{64}$' -or @($Saved.PSObject.Properties).Count -ne 2){throw 'invalid'}
        $current=Get-CompanionGenerationContract $Config
        if($Saved.sha256 -cne $current.sha256){throw 'mismatch'}
    } catch { throw 'GENERATION_CONTRACT_MISMATCH: Saved generation does not authorize current configuration.' }
}

Export-ModuleMember -Function Get-CompanionGenerationContract,Assert-CompanionGenerationContract
