Set-StrictMode -Version Latest

$script:SupportedHostContractVersion = 'codexless-public-preview-v1'

function Get-RequiredProperty {
    param($Object,[string]$Name,[string]$Label)
    if ($null -eq $Object -or !$Object.PSObject.Properties[$Name]) { throw "COMPANION_SETTINGS_INVALID: Missing $Label." }
    $Object.$Name
}

function Resolve-CompanionLocalPath {
    param([string]$Path,[string]$Label,[ValidateSet('Any','File','Directory')][string]$Kind='Any',[switch]$MustExist)
    if ([string]::IsNullOrWhiteSpace($Path) -or ![IO.Path]::IsPathRooted($Path) -or $Path.StartsWith('\\') -or $Path.Contains('"') -or $Path.Contains([char]13) -or $Path.Contains([char]10)) {
        throw "COMPANION_SETTINGS_INVALID: $Label must be an absolute local path."
    }
    $full=[IO.Path]::GetFullPath($Path).TrimEnd('\')
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

function Assert-CodexlessReleaseFile {
    param([string]$Root,$Manifest,[string]$RelativePath)
    if ($RelativePath.Contains('..') -or $RelativePath.StartsWith('/') -or $RelativePath.StartsWith('\')) { throw 'CODEXLESS_RELEASE_INVALID: Unsafe release path.' }
    $entry=Get-ReleaseFileEntry $Manifest $RelativePath
    $path=Join-Path $Root ($RelativePath.Replace('/','\'))
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw "CODEXLESS_RELEASE_INVALID: Missing $RelativePath." }
    if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "CODEXLESS_RELEASE_INVALID: Reparse point $RelativePath is not accepted." }
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne ([string]$entry.sha256).ToLowerInvariant()) {
        throw "CODEXLESS_RELEASE_INVALID: File hash mismatch for $RelativePath."
    }
    $path
}

function Get-CodexlessReleaseIdentity {
    param([string]$Root)
    $rootPath=Resolve-CompanionLocalPath $Root 'codexless.root' Directory -MustExist
    $manifestPath=Join-Path $rootPath 'config\release-manifest.json'
    if (!(Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'CODEXLESS_RELEASE_INVALID: Release manifest is missing.' }
    try { $manifest=Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch { throw 'CODEXLESS_RELEASE_INVALID: Release manifest is unreadable.' }
    if ($manifest.manifestVersion -ne 1 -or $manifest.productId -cne 'codexless' -or [string]::IsNullOrWhiteSpace([string]$manifest.version) -or
        [string]$manifest.buildId -cnotmatch '^[0-9a-f]{64}$' -or [string]$manifest.hostContractVersion -cne $script:SupportedHostContractVersion -or
        $manifest.files -isnot [System.Array]) {
        throw 'CODEXLESS_RELEASE_INVALID: Unsupported release identity or host contract.'
    }
    $critical=@('scripts/launch.mjs','src/mcp-http-public.mjs','src/codexless-runtime.mjs','package.json')
    $paths=@{}
    foreach($relative in $critical){$paths[$relative]=Assert-CodexlessReleaseFile $rootPath $manifest $relative}
    [pscustomobject]@{
        productId='codexless'
        version=[string]$manifest.version
        buildId=([string]$manifest.buildId).ToLowerInvariant()
        hostContractVersion=[string]$manifest.hostContractVersion
        root=$rootPath
        launchScript=$paths['scripts/launch.mjs']
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
            $profileDir=Resolve-CompanionLocalPath ([string](Get-RequiredProperty $tunnel 'profileDir' 'tunnel.profileDir')) 'tunnel.profileDir' Directory -MustExist
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

    [pscustomobject]@{
        schemaVersion=1
        companionRoot=$root
        settingsPath=$settingsPath
        projectPath=$projectPath
        codexlessRoot=$codexlessRoot
        nodeExe=$nodeExe
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
        $request.Method='GET';$request.Proxy=$null;$request.Timeout=$TimeoutMs;$request.ReadWriteTimeout=$TimeoutMs
        $response=$request.GetResponse()
        if ([int]$response.StatusCode -ne 200) { return $false }
        $stream=$response.GetResponseStream();$reader=New-Object IO.StreamReader($stream)
        $body=$reader.ReadToEnd()
        if ($body.Length -gt 65536) { return $false }
        $ready=$body|ConvertFrom-Json
        ($ready.ok -eq $true -and $ready.service -ceq 'codexless-public' -and
         [string]$ready.version -ceq [string]$Config.release.version -and
         [string]$ready.surfaceVersion -ceq [string]$Config.release.hostContractVersion)
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
    $port=[int]$Config.port
    if ($port -lt 1 -or $port -gt 65535) { throw 'COMPANION_SETTINGS_INVALID: Invalid launch port.' }
    $d=[char]36
    $d+"env:CODEX_TOOLBOX_PUBLIC_PORT='$port'; & '$node' '$launch' http; exit "+$d+'LASTEXITCODE'
}

function Get-TunnelStatus {
    param($Config,$Tunnel)
    if ($null -eq $Config.tunnelExe) { return $null }
    try {
        $raw=& $Config.tunnelExe runtimes status $Tunnel.alias --json 2>$null|Out-String
        if([string]::IsNullOrWhiteSpace($raw)){return $null}
        $raw|ConvertFrom-Json
    } catch { $null }
}

function Test-TunnelReady {
    param($Config,$Tunnel)
    $status=Get-TunnelStatus $Config $Tunnel
    ($null -ne $status -and $status.process_running -eq $true -and $status.ready -eq $true -and $status.tunnel_id -eq $Tunnel.tunnelId)
}

function Connect-TunnelRuntime {
    param($Config,$Tunnel,[string]$PlainKey)
    if ($null -eq $Config.tunnelExe -or [string]::IsNullOrWhiteSpace($PlainKey)) { throw 'TUNNEL_CONNECT_INVALID' }
    $env:CONTROL_PLANE_API_KEY=$PlainKey
    try {
        & $Config.tunnelExe runtimes connect --alias $Tunnel.alias --profile $Tunnel.alias --profile-dir $Config.profileDir --tunnel-id $Tunnel.tunnelId --runtime-api-key env:CONTROL_PLANE_API_KEY --mcp-server-url $Config.mcpUrl 2>&1|Out-String
    } finally { Remove-Item Env:CONTROL_PLANE_API_KEY -ErrorAction SilentlyContinue }
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

Export-ModuleMember -Function Get-CompanionConfig,Get-CodexlessReleaseIdentity,Get-ConfiguredTunnels,Get-PlainRuntimeKey,Test-TcpPort,Test-CodexlessReady,Get-CodexlessPrivateConsoleCommand,Get-TunnelStatus,Test-TunnelReady,Connect-TunnelRuntime,Write-CompanionLog
