Set-StrictMode -Version Latest

function Get-LauncherReleaseTrust([string]$Version) {
    # Automation of the existing authenticated-release-note trust step. Never
    # derive an expected digest from the local payload or an owner receipt.
    if($Version -cnotmatch '^0\.1\.0-preview\.[1-9][0-9]{0,2}$'){throw 'LAUNCHER_VERSION_INVALID'}
    $url='https://api.github.com/repos/Waterpark621/Codexless-Windows-Companion/releases/tags/v'+$Version
    $request=[Net.HttpWebRequest]::Create($url)
    $request.Method='GET';$request.AllowAutoRedirect=$false
    $request.Timeout=20000;$request.ReadWriteTimeout=20000
    $request.UserAgent='Codexless-Windows-Companion-Launcher'
    $request.Accept='application/vnd.github+json'
    $request.UseDefaultCredentials=$false
    $response=$null;$stream=$null;$memory=$null
    try {
        $response=$request.GetResponse()
        if([int]$response.StatusCode -ne 200 -or $response.ContentLength -gt 1048576){throw 'invalid'}
        $stream=$response.GetResponseStream();$memory=[IO.MemoryStream]::new()
        $buffer=New-Object byte[] 8192;$deadline=[DateTime]::UtcNow.AddSeconds(20)
        while(($n=$stream.Read($buffer,0,$buffer.Length)) -gt 0){
            if($memory.Length+$n -gt 1048576 -or [DateTime]::UtcNow -gt $deadline){throw 'invalid'}
            $memory.Write($buffer,0,$n)
        }
        $document=[Text.Encoding]::UTF8.GetString($memory.ToArray())|ConvertFrom-Json -ErrorAction Stop
        Get-LauncherReleaseDigest $document $Version
    } catch {throw 'LAUNCHER_RELEASE_TRUST_UNAVAILABLE: This exact Preview must be published with its verified payload digest before installation. Check Internet access and download the attached Preview ZIP.'}
    finally {if($stream){$stream.Dispose()};if($memory){$memory.Dispose()};if($response){$response.Dispose()}}
}

function Get-LauncherReleaseDigest($Document,[string]$Version) {
    $tag='v'+$Version
    if($Document.draft -ne $false -or $Document.prerelease -ne $true -or
       $Document.tag_name -cne $tag -or
       $Document.html_url -cne ('https://github.com/Waterpark621/Codexless-Windows-Companion/releases/tag/'+$tag) -or
       [string]$Document.target_commitish -cnotmatch '^[0-9a-f]{40}$'){throw 'LAUNCHER_RELEASE_TRUST_INVALID'}
    $digestMatches=[regex]::Matches([string]$Document.body,'(?m)^- \*\*Companion payload tree SHA-256\*\* \(required by Install\.ps1\): `([0-9a-f]{64})`\s*$')
    if($digestMatches.Count -ne 1){throw 'LAUNCHER_RELEASE_TRUST_INVALID'}
    $assets=@($Document.assets)
    $name='Codexless-Windows-Companion-'+$Version+'-'+([string]$Document.target_commitish).Substring(0,12)+'.zip'
    if($assets.Count -ne 1 -or $assets[0].name -cne $name -or
       $assets[0].browser_download_url -cne ('https://github.com/Waterpark621/Codexless-Windows-Companion/releases/download/'+$tag+'/'+$name) -or
       [string]$assets[0].digest -cnotmatch '^sha256:[0-9a-f]{64}$'){throw 'LAUNCHER_RELEASE_TRUST_INVALID'}
    $digestMatches[0].Groups[1].Value
}

function Get-LauncherVersion([string]$Directory) {
    $path=Join-Path $Directory 'VERSION'
    if(!(Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -gt 64){throw 'LAUNCHER_VERSION_INVALID'}
    $version=[IO.File]::ReadAllText($path).Trim()
    if($version -cnotmatch '^0\.1\.0-preview\.[1-9][0-9]{0,2}$'){throw 'LAUNCHER_VERSION_INVALID'}
    $version
}

function Assert-LauncherPayload([string]$Directory,[string]$Digest) {
    Import-Module (Join-Path $PSScriptRoot 'InstallTransaction.psm1') -DisableNameChecking
    if($Digest -cnotmatch '^[0-9a-f]{64}$' -or (Get-TransactionTreeDigest $Directory) -cne $Digest){throw 'LAUNCHER_PAYLOAD_CHANGED: Extract the verified Preview ZIP into a fresh folder.'}
}

function Get-LauncherOwnedGeneration([string]$Root) {
    Import-Module (Join-Path $PSScriptRoot 'CompanionRuntime.psm1') -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'NativeTransactionAdapter.psm1') -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'InstallTransaction.psm1') -DisableNameChecking
    # The candidate path is untrusted until the existing ownership verifier
    # checks the receipt, payload, provenance and exact task authority below.
    $path=Join-Path $Root 'install-owner.json'
    if(!(Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -gt 32768){throw 'LAUNCHER_INSTALL_NOT_FOUND: Run INSTALL.cmd first.'}
    $record=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json -ErrorAction Stop
    if([string]$record.generationId -cnotmatch '^[0-9a-f]{32}$'){throw 'LAUNCHER_OWNER_INVALID'}
    $candidate=Join-Path (Join-Path $Root 'generations') $record.generationId
    if([string]$record.payloadSha256 -cnotmatch '^[0-9a-f]{64}$'){throw 'LAUNCHER_OWNER_INVALID'}
    # Daily operations use the same destination-owned receipt trust as the
    # existing installed Tunnels.ps1 interface, and do not require Internet.
    $trusted=[string]$record.payloadSha256
    $cfg=Get-CompanionConfig $Root
    $adapter=New-NativeTransactionAdapter -Root $Root -ProjectPath $cfg.projectPath -CodexlessRoot $cfg.codexlessRoot -NodeExe $cfg.nodeExe -Port $cfg.port -TrustedPayloadSha256 @($trusted)
    Get-OwnedInstall $Root $adapter
}

function Invoke-LauncherBackend([string]$Script,[hashtable]$Parameters) {
    # Retain errors and Doctor exit status; do not turn FAIL/DEGRADED into success.
    $global:LASTEXITCODE=0
    & $Script @Parameters
    if($LASTEXITCODE -ne 0){
        $failure=[InvalidOperationException]::new('LAUNCHER_BACKEND_FAILED: The PowerShell operation failed. Review the displayed diagnostics.')
        $failure.Data['LauncherExitCode']=[int]$LASTEXITCODE
        throw $failure
    }
}

function Get-LauncherTunnelClient([string]$Root) {
    Import-Module (Join-Path $PSScriptRoot 'CompanionRuntime.psm1') -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'ArtifactProvenance.psm1') -DisableNameChecking
    $cfg=Get-CompanionConfig $Root
    if($cfg.tunnelExe){return [IO.Path]::GetFullPath($cfg.tunnelExe)}
    # Reuse qualified artifact staging; no independent downloader/verifier.
    $stage=Join-Path (Split-Path $Root -Parent) ('.companion-dependencies-'+[Guid]::NewGuid().ToString('N'))
    $download=Save-QualifiedArtifact tunnel (Join-Path $stage 'tunnel')
    $expanded=Expand-QualifiedArtifact tunnel $download.archivePath (Join-Path $stage 'expanded')
    [IO.Path]::GetFullPath((Join-Path $expanded.stagedRoot (Get-ArtifactPolicy tunnel).executableRelativePath))
}

function New-LauncherUiServices {
    @{
        Version=(Get-Command Get-LauncherVersion).ScriptBlock
        Trust=(Get-Command Get-LauncherReleaseTrust).ScriptBlock
        Verify=(Get-Command Assert-LauncherPayload).ScriptBlock
        Owned=(Get-Command Get-LauncherOwnedGeneration).ScriptBlock
        Invoke=(Get-Command Invoke-LauncherBackend).ScriptBlock
        Client=(Get-Command Get-LauncherTunnelClient).ScriptBlock
        Read={param($prompt) Read-Host $prompt}
        Write={param($message) Write-Host $message}
    }
}

function Invoke-SimpleLauncher {
    param([ValidateSet('Install','Start','Stop','Restart','Status','Doctor','Tunnels')][string]$Action,[string]$PayloadRoot,[string]$Root)
    $s=New-LauncherUiServices
    if($Action -ceq 'Install'){
        $digest=& $s.Trust (& $s.Version $PayloadRoot)
        & $s.Verify $PayloadRoot $digest
        & $s.Write 'Choose your Codexless workspace folder.'
        & $s.Write 'If you use one project, choose that project folder.'
        & $s.Write 'If you use multiple projects, choose a parent folder such as:'
        & $s.Write 'D:\Codexless Work'
        & $s.Write 'Choose a dedicated folder, not a whole drive or your user profile root.'
        $project=& $s.Read 'Workspace'
        $answer=& $s.Read 'Set up one existing OpenAI tunnel now? [y/N]'
        if([string]$answer -notmatch '^(?i:y|yes|n|no)?$'){throw 'LAUNCHER_CHOICE_INVALID: Enter y or n.'}
        $args=@{ProjectPath=$project;InstallDirectory=$Root;TrustedPayloadSha256=$digest}
        if($answer -match '^(?i:y|yes)$'){
            $args.TunnelId=& $s.Read 'Existing tunnel ID'
            $args.TunnelAlias='default'
        }else{$args.NoTunnel=$true}
        & $s.Invoke (Join-Path $PayloadRoot 'Install.ps1') $args
        return
    }
    $owned=& $s.Owned $Root
    if($Action -cne 'Tunnels'){
        & $s.Invoke (Join-Path $owned.generation ($Action+'.ps1')) @{InstallDirectory=$Root}
        return
    }
    while($true){
        & $s.Write 'Tunnels: 1 List | 2 Add | 3 Remove | 4 Rotate key | 5 Status | 0 Exit'
        & $s.Write 'Use STOP.cmd before Add/Remove/Rotate key, then START.cmd. Remove is local only.'
        $choice=& $s.Read 'Choose a number'
        if($choice -ceq '0'){return}
        $actions=@{'1'='List';'2'='Add';'3'='Remove';'4'='RotateKey';'5'='Status'}
        if(!$actions.ContainsKey([string]$choice)){& $s.Write 'Choose 0 through 5.';continue}
        $args=@{Root=$Root;Action=$actions[[string]$choice]}
        if($choice -ceq '2'){
            $args.Alias=& $s.Read 'Local tunnel name (letters, numbers, underscore or dash)'
            $args.ProfileId=$args.Alias
            $args.TunnelId=& $s.Read 'Existing tunnel ID'
            $args.TunnelClientExe=& $s.Client $Root
        }elseif($choice -in @('3','4')){$args.ProfileId=& $s.Read 'Profile ID from List'}
        & $s.Invoke (Join-Path $owned.generation 'Tunnels.ps1') $args
    }
}

Export-ModuleMember -Function Invoke-SimpleLauncher
