Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'BoundedNative.psm1')
Import-Module (Join-Path $PSScriptRoot 'ArtifactProvenance.psm1')

$script:SupportedHostContractVersion = 'codexless-public-preview-v1'
$script:QualifiedCodexlessRelease = [pscustomobject]@{
    version='0.1.2-preview.1'
    buildId='7e416d0f32e67cffa6af1ba9ea4339dc738fdc86115263336229cc9fd46c8308'
    sourceRevision='1da3cb5b8563370f3656c831d17a1c73354df282'
    manifestSha256='14583de39b1218ff44477b62519f7cc6351ec7c33259cf24c334ef0ed5cccb9d'
}

function Get-RequiredProperty {
    param($Object,[string]$Name,[string]$Label)
    if ($null -eq $Object -or !$Object.PSObject.Properties[$Name]) { throw "COMPANION_SETTINGS_INVALID: Missing $Label." }
    $Object.$Name
}

function Resolve-CompanionLocalPath {
    param([string]$Path,[string]$Label,[ValidateSet('Any','File','Directory')][string]$Kind='Any',[switch]$MustExist)
    if ([string]::IsNullOrWhiteSpace($Path) -or
        $Path -notmatch '^[A-Za-z]:[\\/]' -or
        $Path.Contains('"') -or $Path.Contains([char]13) -or $Path.Contains([char]10)) {
        throw "COMPANION_SETTINGS_INVALID: $Label must be a fully-qualified local drive path."
    }
    $full=[IO.Path]::GetFullPath($Path)
    $driveRoot=[IO.Path]::GetPathRoot($full)
    if($full.Length -gt $driveRoot.Length){$full=$full.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)}
    if ($MustExist -and !(Test-Path -LiteralPath $full)) { throw "COMPANION_SETTINGS_INVALID: $Label does not exist." }
    if ($MustExist -and $Kind -eq 'File' -and !(Test-Path -LiteralPath $full -PathType Leaf)) { throw "COMPANION_SETTINGS_INVALID: $Label must be a file." }
    if ($MustExist -and $Kind -eq 'Directory' -and !(Test-Path -LiteralPath $full -PathType Container)) { throw "COMPANION_SETTINGS_INVALID: $Label must be a directory." }
    $full
}

function Get-ReleaseFileEntry {
    param($Manifest,[string]$RelativePath)
    $entries=@($Manifest.files | Where-Object { [string]$_.path -ceq $RelativePath })
    if ($entries.Count -ne 1 -or [string]$entries[0].sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw "CODEXLESS_RELEASE_INVALID: Missing or invalid manifest entry $RelativePath."
    }
    $entries[0]
}

function Assert-ReleaseRelativePath {
    param([string]$RelativePath)
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        $RelativePath.Contains('\') -or
        $RelativePath.StartsWith('/') -or
        $RelativePath.EndsWith('/') -or
        $RelativePath.Contains('//')) {
        throw 'CODEXLESS_RELEASE_INVALID: Unsafe release path.'
    }
    foreach($segment in $RelativePath.Split('/')){
        if([string]::IsNullOrWhiteSpace($segment) -or $segment -eq '.' -or $segment -eq '..'){
            throw 'CODEXLESS_RELEASE_INVALID: Unsafe release path.'
        }
    }
    $RelativePath
}

function Assert-CodexlessReleaseFile {
    param([string]$Root,$Manifest,[string]$RelativePath)
    $safeRelative=Assert-ReleaseRelativePath $RelativePath
    $entry=Get-ReleaseFileEntry $Manifest $safeRelative
    $path=Join-Path $Root ($safeRelative.Replace('/','\'))
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw "CODEXLESS_RELEASE_INVALID: Missing $safeRelative." }
    if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "CODEXLESS_RELEASE_INVALID: Reparse point $safeRelative is not accepted." }
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne ([string]$entry.sha256).ToLowerInvariant()) {
        throw "CODEXLESS_RELEASE_INVALID: File hash mismatch for $safeRelative."
    }
    $path
}

function Read-CodexlessReleaseManifestSnapshot {
    param([string]$ManifestPath)
    try {
        $bytes=[IO.File]::ReadAllBytes($ManifestPath)
    } catch {
        throw 'CODEXLESS_RELEASE_INVALID: Release manifest is unreadable.'
    }

    $sha=[Security.Cryptography.SHA256]::Create()
    try {
        $manifestSha=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }

    try {
        $utf8=[Text.UTF8Encoding]::new($false,$true)
        $offset=0
        if($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF){
            $offset=3
        }
        $json=$utf8.GetString($bytes,$offset,$bytes.Length-$offset)
        $manifest=$json | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw 'CODEXLESS_RELEASE_INVALID: Release manifest is unreadable.'
    } finally {
        $json=$null
        $bytes=$null
    }

    [pscustomobject]@{
        sha256=$manifestSha
        manifest=$manifest
    }
}

function Get-CodexlessReleaseIdentity {
    param([string]$Root)
    $rootPath=Resolve-CompanionLocalPath $Root 'codexless.root' Directory -MustExist
    $manifestPath=Join-Path $rootPath 'config\release-manifest.json'
    if (!(Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'CODEXLESS_RELEASE_INVALID: Release manifest is missing.' }
    if ((Get-Item -LiteralPath $manifestPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'CODEXLESS_RELEASE_INVALID: Release manifest reparse points are not accepted.' }

    $snapshot=Read-CodexlessReleaseManifestSnapshot $manifestPath
    $manifestSha=[string]$snapshot.sha256
    if($manifestSha -cne [string]$script:QualifiedCodexlessRelease.manifestSha256){
        throw 'CODEXLESS_RELEASE_INVALID: Release manifest is not the qualified Companion build.'
    }
    $manifest=$snapshot.manifest

    if ($manifest.manifestVersion -ne 1 -or
        $manifest.productId -cne 'codexless' -or
        [string]$manifest.version -cne [string]$script:QualifiedCodexlessRelease.version -or
        [string]$manifest.buildId -cne [string]$script:QualifiedCodexlessRelease.buildId -or
        [string]$manifest.sourceRevision -cne [string]$script:QualifiedCodexlessRelease.sourceRevision -or
        [string]$manifest.hostContractVersion -cne $script:SupportedHostContractVersion -or
        $manifest.files -isnot [System.Array] -or
        @($manifest.files).Count -lt 1) {
        throw 'CODEXLESS_RELEASE_INVALID: Unsupported release identity or host contract.'
    }

    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($entry in @($manifest.files)){
        if($null -eq $entry -or !$entry.PSObject.Properties['path'] -or !$entry.PSObject.Properties['sha256']){
            throw 'CODEXLESS_RELEASE_INVALID: Manifest file entry is incomplete.'
        }
        $relative=Assert-ReleaseRelativePath ([string]$entry.path)
        if(!$seen.Add($relative)){throw 'CODEXLESS_RELEASE_INVALID: Duplicate manifest release path.'}
        if([string]$entry.sha256 -cnotmatch '^[0-9a-f]{64}$'){throw 'CODEXLESS_RELEASE_INVALID: Invalid manifest file hash.'}
        [void](Assert-CodexlessReleaseFile $rootPath $manifest $relative)
    }

    [void](Get-ReleaseFileEntry $manifest 'scripts/launch.mjs')
    [pscustomobject]@{
        productId='codexless'
        version=[string]$manifest.version
        buildId=[string]$manifest.buildId
        sourceRevision=[string]$manifest.sourceRevision
        manifestSha256=$manifestSha
        fileCount=@($manifest.files).Count
        hostContractVersion=[string]$manifest.hostContractVersion
        root=$rootPath
        launchScript=(Join-Path $rootPath 'scripts\launch.mjs')
    }
}
function Assert-PathWithinRoot {
    param([string]$Root,[string]$Path,[string]$Label)
    $rootPath=[IO.Path]::GetFullPath($Root).TrimEnd('\')+'\'
    $candidate=[IO.Path]::GetFullPath($Path)
    if (!$candidate.StartsWith($rootPath,[StringComparison]::OrdinalIgnoreCase)) { throw "COMPANION_SETTINGS_INVALID: $Label escapes the Companion root." }
    $candidate
}

function Get-CompanionConfig {
    param([string]$CompanionRoot)
    $root=Resolve-CompanionLocalPath $CompanionRoot 'companion root' Directory -MustExist
    $settingsPath=Join-Path $root 'settings.json'
    if (!(Test-Path -LiteralPath $settingsPath -PathType Leaf)) { throw 'COMPANION_SETTINGS_MISSING: Run the Companion installer first.' }
    try { $settings=Get-Content -LiteralPath $settingsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch { throw 'COMPANION_SETTINGS_INVALID: settings.json is unreadable.' }
    if ($settings.schemaVersion -ne 1) { throw 'COMPANION_SETTINGS_INVALID: Unsupported schemaVersion.' }

    $project=Get-RequiredProperty $settings 'project' 'project'
    $codexless=Get-RequiredProperty $settings 'codexless' 'codexless'
    $projectPath=Resolve-CompanionLocalPath ([string](Get-RequiredProperty $project 'path' 'project.path')) 'project.path' Directory -MustExist
    $codexlessRoot=Resolve-CompanionLocalPath ([string](Get-RequiredProperty $codexless 'root' 'codexless.root')) 'codexless.root' Directory -MustExist

    $portValue=Get-RequiredProperty $codexless 'port' 'codexless.port'
    $port=0
    if (![int]::TryParse([string]$portValue,[ref]$port) -or $port -lt 1 -or $port -gt 65535) { throw 'COMPANION_SETTINGS_INVALID: codexless.port must be 1-65535.' }

    $nodeExe=$null
    if ($codexless.PSObject.Properties['nodeExe'] -and ![string]::IsNullOrWhiteSpace([string]$codexless.nodeExe)) {
        $nodeExe=Resolve-CompanionLocalPath ([string]$codexless.nodeExe) 'codexless.nodeExe' File -MustExist
    } else {
        $node=(Get-Command node.exe -ErrorAction Stop)
        $nodeExe=Resolve-CompanionLocalPath $node.Source 'node.exe' File -MustExist
    }
    $nodePolicy=Get-ArtifactPolicy node
    $nodeSha256=[string]$nodePolicy.executableSha256
    if($nodeSha256 -cnotmatch '^[0-9a-f]{64}$'){throw 'COMPANION_NODE_PROVENANCE_INVALID: Qualified Node executable digest is not bound.'}
    if($codexless.PSObject.Properties['nodeSha256'] -and ![string]::IsNullOrWhiteSpace([string]$codexless.nodeSha256) -and [string]$codexless.nodeSha256 -cne $nodeSha256){
        throw 'COMPANION_NODE_PROVENANCE_INVALID: Installed Node digest does not match qualified artifact provenance.'
    }
    if((Get-FileHash -LiteralPath $nodeExe -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() -cne $nodeSha256){
        throw 'COMPANION_NODE_PROVENANCE_INVALID: Node executable bytes do not match qualified artifact provenance.'
    }

    $release=Get-CodexlessReleaseIdentity $codexlessRoot
    $tunnels=@()
    $tunnelExe=$null
    $profileDir=$null
    if ($settings.PSObject.Properties['tunnel'] -and $null -ne $settings.tunnel) {
        $tunnel=$settings.tunnel
        $enabled=$true
        if ($tunnel.PSObject.Properties['enabled']) { $enabled=[bool]$tunnel.enabled }
        if ($enabled) {
            $tunnelExe=Resolve-CompanionLocalPath ([string](Get-RequiredProperty $tunnel 'executable' 'tunnel.executable')) 'tunnel.executable' File -MustExist
            $profileSetting=[string](Get-RequiredProperty $tunnel 'profileDir' 'tunnel.profileDir')
            if([IO.Path]::IsPathRooted($profileSetting)){
                $profileDir=Resolve-CompanionLocalPath $profileSetting 'tunnel.profileDir' Directory -MustExist
            } else {
                $profileDir=Assert-PathWithinRoot $root (Join-Path $root $profileSetting) 'tunnel.profileDir'
                if(!(Test-Path -LiteralPath $profileDir -PathType Container)){throw 'COMPANION_SETTINGS_INVALID: tunnel.profileDir does not exist.'}
            }
            $alias=[string](Get-RequiredProperty $tunnel 'alias' 'tunnel.alias')
            $tunnelId=[string](Get-RequiredProperty $tunnel 'tunnelId' 'tunnel.tunnelId')
            if ($alias -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$' -or [string]::IsNullOrWhiteSpace($tunnelId)) { throw 'COMPANION_SETTINGS_INVALID: Tunnel alias/id are invalid.' }
            $keyFile='keys\runtime-key.dpapi'
            if ($tunnel.PSObject.Properties['keyFile'] -and ![string]::IsNullOrWhiteSpace([string]$tunnel.keyFile)) { $keyFile=[string]$tunnel.keyFile }
            if ([IO.Path]::IsPathRooted($keyFile)) { throw 'COMPANION_SETTINGS_INVALID: tunnel.keyFile must be relative to the Companion root.' }
            $keyPath=Assert-PathWithinRoot $root (Join-Path $root $keyFile) 'tunnel.keyFile'
            $tunnels=@([pscustomobject]@{alias=$alias;tunnelId=$tunnelId;keyFile=$keyFile;keyPath=$keyPath;enabled=$true})
        }
    }

    $isolatedRuntimeProfile=$null
    if($settings.PSObject.Properties['isolatedRuntimeProfile']){
        if([string]$settings.isolatedRuntimeProfile -cne 'acceptance-profile'){throw 'COMPANION_SETTINGS_INVALID: Unsupported isolation root.'}
        $isolatedRuntimeProfile=Join-Path $root 'acceptance-profile'
        if(!(Test-Path -LiteralPath $isolatedRuntimeProfile -PathType Container) -or
           ((Get-Item -LiteralPath $isolatedRuntimeProfile -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'COMPANION_SETTINGS_INVALID: Invalid isolation root.'}
    }
    [pscustomobject]@{
        isolatedRuntimeProfile=$isolatedRuntimeProfile
        schemaVersion=1
        companionRoot=$root
        settingsPath=$settingsPath
        projectPath=$projectPath
        codexlessRoot=$codexlessRoot
        nodeExe=$nodeExe
        nodeSha256=$nodeSha256
        port=$port
        mcpUrl="http://127.0.0.1:$port/mcp"
        readyUrl="http://127.0.0.1:$port/readyz"
        release=$release
        launchScript=$release.launchScript
        tunnelExe=$tunnelExe
        profileDir=$profileDir
        tunnels=$tunnels
    }
}

function Get-ConfiguredTunnels {
    param($Config,[switch]$IncludeDisabled)
    @($Config.tunnels)
}

function Get-PlainRuntimeKey {
    param($Tunnel)
    if ($null -eq $Tunnel -or [string]::IsNullOrWhiteSpace([string]$Tunnel.keyPath) -or !(Test-Path -LiteralPath $Tunnel.keyPath -PathType Leaf)) {
        throw 'TUNNEL_CREDENTIAL_MISSING: Run tunnel setup on this PC.'
    }
    $secure=ConvertTo-SecureString ((Get-Content -LiteralPath $Tunnel.keyPath -Raw).Trim())
    $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Test-TcpPort {
    param([string]$HostName='127.0.0.1',[int]$Port,[int]$TimeoutMs=600)
    $client=New-Object Net.Sockets.TcpClient
    try {
        $pending=$client.BeginConnect($HostName,$Port,$null,$null)
        if (!$pending.AsyncWaitHandle.WaitOne($TimeoutMs,$false)) { return $false }
        $client.EndConnect($pending)
        $true
    } catch { $false }
    finally { try { $client.Close() } catch {} }
}

function Test-CodexlessReady {
    param($Config,[int]$TimeoutMs=1500)
    $response=$null;$stream=$null;$reader=$null
    try {
        $request=[Net.HttpWebRequest]::Create([string]$Config.readyUrl)
        $request.Method='GET';$request.Proxy=$null;$request.AllowAutoRedirect=$false;$request.Timeout=$TimeoutMs;$request.ReadWriteTimeout=$TimeoutMs
        $response=$request.GetResponse()
        if ([int]$response.StatusCode -ne 200 -or [string]$response.ResponseUri.AbsoluteUri -cne [string]$Config.readyUrl) { return $false }
        $stream=$response.GetResponseStream();$reader=New-Object IO.StreamReader($stream)
        $body=$reader.ReadToEnd()
        if ($body.Length -gt 65536) { return $false }
        $ready=$body|ConvertFrom-Json
        ($ready.ok -eq $true -and
         $ready.service -ceq 'codexless-public' -and
         $ready.transport -ceq 'streamable-http' -and
         $ready.publicPreview -eq $true -and
         [string]$ready.version -ceq [string]$Config.release.version -and
         [string]$ready.surfaceVersion -ceq [string]$Config.release.hostContractVersion -and
         [string]$ready.buildId -ceq [string]$Config.release.buildId -and
         [string]$ready.sourceRevision -ceq [string]$Config.release.sourceRevision -and
         !$ready.PSObject.Properties['defaultCwd'])
    } catch { $false }
    finally {
        if($null -ne $reader){$reader.Dispose()}
        elseif($null -ne $stream){$stream.Dispose()}
        if($null -ne $response){$response.Dispose()}
    }
}

function Get-CodexlessPrivateConsoleCommand {
    param($Config)
    $node=([string]$Config.nodeExe).Replace("'","''")
    $launch=([string]$Config.launchScript).Replace("'","''")
    $expected=[string]$Config.nodeSha256
    $port=[int]$Config.port
    if ($port -lt 1 -or $port -gt 65535 -or $expected -cnotmatch '^[0-9a-f]{64}$') { throw 'COMPANION_SETTINGS_INVALID: Invalid launch provenance.' }
    $prefix=''
    if($Config.PSObject.Properties['isolatedRuntimeProfile'] -and $Config.isolatedRuntimeProfile){
        $isolated=([string]$Config.isolatedRuntimeProfile).Replace("'","''")
        $prefix="Get-ChildItem Env: | Where-Object { `$_.Name -match '^(CODEX|CODEXLESS|CODEX_TOOLBOX|OPENAI|AZURE_OPENAI|CONTROL_PLANE|TUNNEL_CLIENT|NODE_OPTIONS)' } | ForEach-Object { Remove-Item -LiteralPath ('Env:'+`$_.Name) -ErrorAction Stop }; "+
            "`$env:USERPROFILE='$isolated'; `$env:APPDATA='$isolated\AppData\Roaming'; `$env:LOCALAPPDATA='$isolated\AppData\Local'; `$env:CODEX_HOME='$isolated\codex'; "+
            "`$env:CODEXLESS_AGENT_TASK_STATE_FILE='$isolated\agent-task-cards.json'; `$env:CODEXLESS_BROWSER_SNAPSHOT_STORE='$isolated\browser-snapshots'; `$env:CODEXLESS_CODEX_RUNTIME='existing'; "+
            "`$env:TUNNEL_CLIENT_STATE_DIR='$isolated\tunnel-state'; `$env:TUNNEL_CLIENT_PROFILE_DIR='$isolated\tunnel-profile'; "
    }
    $d=[char]36
    $prefix+$d+"nodeStream="+$d+"null; "+$d+"hadNodeOptions=Test-Path Env:NODE_OPTIONS; "+$d+"previousNodeOptions=if("+$d+"hadNodeOptions){[string]"+$d+"env:NODE_OPTIONS}else{"+$d+"null}; Remove-Item Env:NODE_OPTIONS -ErrorAction SilentlyContinue; "+$d+"env:CODEX_TOOLBOX_PUBLIC_PORT='$port'; try { "+$d+"nodeStream=[IO.File]::Open('$node',[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read); "+$d+"sha=[Security.Cryptography.SHA256]::Create(); try { "+$d+"actual=([BitConverter]::ToString("+$d+"sha.ComputeHash("+$d+"nodeStream))).Replace('-','').ToLowerInvariant() } finally { "+$d+"sha.Dispose() }; if("+$d+"actual -cne '$expected'){throw 'NODE_EXECUTABLE_MISMATCH'}; & '$node' '$launch' http; "+$d+"exitCode="+$d+"LASTEXITCODE } finally { if("+$d+"nodeStream){"+$d+"nodeStream.Dispose()}; if("+$d+"hadNodeOptions){"+$d+"env:NODE_OPTIONS="+$d+"previousNodeOptions}else{Remove-Item Env:NODE_OPTIONS -ErrorAction SilentlyContinue}; "+$d+"previousNodeOptions="+$d+"null }; exit "+$d+"exitCode"
}

function Get-TunnelRuntimeContext($Config,$Tunnel) {
    try {
        if($Tunnel.alias -cnotmatch '^[a-z0-9][a-z0-9-]{0,63}$'){throw 'invalid'}
        $ownerPath=Join-Path $Config.companionRoot 'task-owner.json'
        if((Get-Item -LiteralPath $ownerPath).Length -gt 16384){throw 'invalid'}
        $cursor=$ownerPath
        while($cursor){if((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'invalid'};$cursor=Split-Path $cursor -Parent}
        $owner=Get-Content -LiteralPath $ownerPath -Raw|ConvertFrom-Json
        if($owner.version -ne 1 -or $owner.generationContract.version -ne 1 -or $owner.generationContract.sha256 -cnotmatch '^[0-9a-f]{64}$' -or $owner.pid -le 0 -or $owner.userSid -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -or $owner.launcherDirectory -ine $Config.companionRoot){throw 'invalid'}
        $canonical=@($owner.generationContract.sha256,[string]$owner.pid,[string]$owner.createdAt,$owner.userSid) -join '|'
        $sha=[Security.Cryptography.SHA256]::Create()
        try{$id=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
        $state=Join-Path (Join-Path (Join-Path $Config.companionRoot 'tunnel-runtime') $id) $Tunnel.alias
        Resolve-CompanionLocalPath $state 'tunnel namespace' Directory|Out-Null
        $cursor=$state
        while($cursor){if((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'invalid'};$cursor=Split-Path $cursor -Parent}
        [pscustomobject]@{stateRoot=$state;profileRoot=(Join-Path $state 'profiles');intentPath=(Join-Path $state 'connect-intent.json');owner=$owner;generationSha256=$owner.generationContract.sha256}
    }catch{throw 'TUNNEL_GENERATION_CONTEXT_INVALID'}
}

function Invoke-TunnelNative($Config,$Tunnel,[string[]]$Arguments,[int]$TimeoutMs=5000,[string]$PlainKey,[string]$StateRoot,[IntPtr]$GuardHandle=[IntPtr]::Zero) {
    $context=Get-TunnelRuntimeContext $Config $Tunnel
    $policy=Get-ArtifactPolicy tunnel
    $environment=@{TUNNEL_CLIENT_STATE_DIR=$context.stateRoot;TUNNEL_CLIENT_PROFILE_DIR=$context.profileRoot}
    if($StateRoot){Resolve-CompanionLocalPath $StateRoot 'stop namespace' Directory -MustExist|Out-Null;$environment.TUNNEL_CLIENT_STATE_DIR=$StateRoot}
    if($PlainKey){$environment.CONTROL_PLANE_API_KEY=$PlainKey}
    try{Invoke-BoundedNative -Executable $Config.tunnelExe -ExpectedSha256 $policy.executableSha256 -Arguments $Arguments -WorkingDirectory $Config.companionRoot -TimeoutMs $TimeoutMs -OutputLimit 65536 -Environment $environment -GuardHandle $GuardHandle}
    finally{$environment.Clear();$PlainKey=$null}
}

function Get-TunnelStatus {
    param($Config,$Tunnel)
    if ($null -eq $Config.tunnelExe) { return $null }
    try {
        $result=Invoke-TunnelNative $Config $Tunnel @('runtimes','status',[string]$Tunnel.alias,'--json')
        if(!$result.Ok -or [string]::IsNullOrWhiteSpace($result.Stdout)){return $null}
        $status=$result.Stdout|ConvertFrom-Json
        if($status.alias -cne $Tunnel.alias -or $status.tunnel_id -cne $Tunnel.tunnelId -or $status.process_running -isnot [bool]){return $null}
        $status
    } catch { $null }
    finally{$result=$null}
}

function Test-TunnelReady {
    param($Config,$Tunnel)
    $status=Get-TunnelStatus $Config $Tunnel
    ($null -ne $status -and $status.process_running -eq $true -and $status.PSObject.Properties['healthy'] -and $status.healthy -is [bool] -and $status.healthy -and $status.PSObject.Properties['ready'] -and $status.ready -is [bool] -and $status.ready -and $status.tunnel_id -ceq $Tunnel.tunnelId)
}

function Connect-TunnelRuntime {
    param($Config,$Tunnel,[string]$PlainKey)
    if ($null -eq $Config.tunnelExe -or [string]::IsNullOrWhiteSpace($PlainKey)) { throw 'TUNNEL_CONNECT_INVALID' }
    $context=Get-TunnelRuntimeContext $Config $Tunnel
    if(!(Test-Path -LiteralPath $context.intentPath -PathType Leaf)){throw 'TUNNEL_CONNECT_INTENT_REQUIRED'}
    try {
        $result=Invoke-TunnelNative $Config $Tunnel @('runtimes','connect','--alias',[string]$Tunnel.alias,'--profile',[string]$Tunnel.alias,'--profile-dir',$context.profileRoot,'--tunnel-id',[string]$Tunnel.tunnelId,'--runtime-api-key','env:CONTROL_PLANE_API_KEY','--mcp-server-url',[string]$Config.mcpUrl,'--json') 30000 $PlainKey
        if(!$result.Ok){if($result.Code -ceq 'NATIVE_SECURITY_POLICY_UNSUPPORTED'){throw 'TUNNEL_SECURITY_POLICY_UNSUPPORTED: Windows refused the approved unsigned client. Do not bypass security controls.'};throw 'TUNNEL_CONNECT_UNCERTAIN: Generation is fenced; verify recovery before retry.'}
        $result.Stdout=$null
        $result
    } finally { $PlainKey=$null }
}

function Write-CompanionLog {
    param([string]$CompanionRoot,[string]$Message)
    $logDir=Join-Path $CompanionRoot 'logs'
    if(!(Test-Path -LiteralPath $logDir)){New-Item -ItemType Directory -Path $logDir -Force|Out-Null}
    $path=Join-Path $logDir 'host.log'
    try {
        if((Test-Path -LiteralPath $path)-and((Get-Item -LiteralPath $path).Length -gt 2MB)){
            $previous=Join-Path $logDir 'host.previous.log'
            Remove-Item -LiteralPath $previous -Force -ErrorAction SilentlyContinue
            Move-Item -LiteralPath $path -Destination $previous -Force
        }
    } catch {}
    Add-Content -LiteralPath $path -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
}

Export-ModuleMember -Function Get-CompanionConfig,Get-CodexlessReleaseIdentity,Get-ConfiguredTunnels,Get-PlainRuntimeKey,Test-TcpPort,Test-CodexlessReady,Get-CodexlessPrivateConsoleCommand,Get-TunnelRuntimeContext,Invoke-TunnelNative,Get-TunnelStatus,Test-TunnelReady,Connect-TunnelRuntime,Write-CompanionLog
