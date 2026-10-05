Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression

function Assert-ArtifactPath([string]$Path) {
    if($Path -notmatch '^[A-Za-z]:[\\/]' -or $Path -match '["\r\n]'){throw 'PROVENANCE_PATH_INVALID'}
    $full=[IO.Path]::GetFullPath($Path)
    $cursor=$full
    while($cursor){
        if(Test-Path -LiteralPath $cursor){if((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'PROVENANCE_PATH_INVALID'}}
        $cursor=Split-Path $cursor -Parent
    }
    $full
}

function Read-ArtifactPolicyDocument {
    try {
        $document=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'ARTIFACT-POLICY.json') -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
        if($document.schemaVersion -ne 1){throw 'invalid'}
        $document
    } catch { throw 'PROVENANCE_POLICY_INVALID: Artifact policy is unreadable or malformed.' }
}

function Assert-ArtifactPolicyBounds($Policy) {
    if($Policy.archiveType -cne 'zip' -or
       $Policy.maxArchiveBytes -le 0 -or $Policy.maxArchiveBytes -gt 536870912 -or
       $Policy.maxExpandedBytes -le 0 -or $Policy.maxExpandedBytes -gt 1073741824 -or
       $Policy.maxEntries -lt 1 -or $Policy.maxEntries -gt 10000){throw 'PROVENANCE_POLICY_INVALID: Artifact bounds are invalid.'}
}

function Get-CodexlessDistributionBinding {
    $document=Read-ArtifactPolicyDocument
    $policy=$document.codexless
    try {
        if($null -eq $policy -or $policy.role -cne 'codexless'){throw 'invalid'}
        if($policy.state -cnotin @('unpublished','published')){throw 'invalid'}
        if($policy.version -cne '0.1.2-preview.1' -or
           $policy.candidateHead -cne '1bc8b5f6f45b88cc4bc311604178407992bcc9d2' -or
           $policy.buildId -cne '7e416d0f32e67cffa6af1ba9ea4339dc738fdc86115263336229cc9fd46c8308' -or
           $policy.sourceRevision -cne '1da3cb5b8563370f3656c831d17a1c73354df282' -or
           $policy.releaseManifestSha256 -cne '14583de39b1218ff44477b62519f7cc6351ec7c33259cf24c334ef0ed5cccb9d' -or
           $policy.hostContractVersion -cne 'codexless-public-preview-v1' -or
           $policy.payloadRootRelativePath -cne '.' -or
           $policy.releaseManifestRelativePath -cne 'config/release-manifest.json' -or
           $policy.launchScriptRelativePath -cne 'scripts/launch.mjs' -or
           $policy.requireManifestFileClosure -ne $true){throw 'invalid'}
        Assert-ArtifactPolicyBounds $policy
        $required=@($policy.publicationRequiredFields)
        if($required.Count -ne 4 -or
           $required[0] -cne 'state=published' -or
           $required[1] -cne 'url' -or
           $required[2] -cne 'archiveFileName' -or
           $required[3] -cne 'sha256'){throw 'invalid'}
        if($policy.state -ceq 'unpublished'){
            if($null -ne $policy.url -or $null -ne $policy.archiveFileName -or $null -ne $policy.sha256){throw 'invalid'}
            return $policy
        }
        if([string]::IsNullOrWhiteSpace([string]$policy.url) -or
           [string]::IsNullOrWhiteSpace([string]$policy.archiveFileName) -or
           [string]$policy.sha256 -cnotmatch '^[0-9a-f]{64}$'){throw 'invalid'}
        if([string]$policy.archiveFileName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,199}\.zip$'){throw 'invalid'}
        $uri=[Uri][string]$policy.url
        if($uri.Scheme -cne 'https' -or $uri.UserInfo -or $uri.Fragment -or $uri.Query -or !$uri.IsDefaultPort){throw 'invalid'}
        if([Uri]::UnescapeDataString((Split-Path $uri.AbsolutePath -Leaf)) -cne [string]$policy.archiveFileName){throw 'invalid'}
        $policy
    } catch { throw 'PROVENANCE_POLICY_INVALID: Codexless distribution binding is malformed.' }
}

function Get-ArtifactPolicy {
    param([ValidateSet('node','codexless','tunnel')][string]$Role)
    if($Role -eq 'codexless'){
        $policy=Get-CodexlessDistributionBinding
        if($policy.state -cne 'published'){throw 'PROVENANCE_POLICY_UNBOUND: Codexless public artifact is unpublished; publication fields must be bound before staging or mutation.'}
        return $policy
    }
    $document=Read-ArtifactPolicyDocument
    try {
        $policy=$document.$Role
        if($null -eq $policy){throw 'invalid'}
        $uri=[Uri]$policy.url
        if($policy.role -cne $Role -or $policy.sha256 -cnotmatch '^[0-9a-f]{64}$' -or $uri.Scheme -cne 'https' -or $uri.UserInfo -or $uri.Fragment -or $uri.Query -or !$uri.IsDefaultPort){throw 'invalid'}
        if($Role -eq 'node' -and ($policy.version -cne '24.12.0' -or $policy.architecture -cne 'win-x64' -or $policy.url -cne 'https://nodejs.org/dist/v24.12.0/node-v24.12.0-win-x64.zip' -or $policy.executableSha256 -cne '2ffe3acc0458fdde999f50d11809bbe7c9b7ef204dcf17094e325d26ace101d8')){throw 'invalid'}
        if($Role -eq 'tunnel' -and ($policy.version -cne '0.0.14' -or $policy.architecture -cne 'windows-amd64' -or $policy.url -cne 'https://github.com/openai/tunnel-client/releases/download/v0.0.14/tunnel-client-v0.0.14-windows-amd64.zip' -or $policy.executableSha256 -cne 'fcc85a69ec0ad82518e4f8964f60c45e31787957782a0fc9c1b0c44e82d61b9b')){throw 'invalid'}
        Assert-ArtifactPolicyBounds $policy
        $policy
    } catch {
        if($_.Exception.Message -like 'PROVENANCE_POLICY_*'){throw}
        throw 'PROVENANCE_POLICY_INVALID: Artifact policy is malformed.'
    }
}

function Assert-ArtifactStream($Stream,$Policy) {
    if($Stream.Length -le 0 -or $Stream.Length -gt [long]$Policy.maxArchiveBytes){throw 'PROVENANCE_ARCHIVE_INVALID'}
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$digest=([BitConverter]::ToString($sha.ComputeHash($Stream))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    if($digest -cne [string]$Policy.sha256){throw 'PROVENANCE_HASH_MISMATCH'}
    $Stream.Position=0
    $digest
}

function Get-ZipEntrySha256($Entry) {
    $entryStream=$Entry.Open();$entryHash=[Security.Cryptography.SHA256]::Create()
    try{([BitConverter]::ToString($entryHash.ComputeHash($entryStream))).Replace('-','').ToLowerInvariant()}
    finally{$entryHash.Dispose();$entryStream.Dispose()}
}

function Expand-QualifiedArtifact {
    param([ValidateSet('node','codexless','tunnel')][string]$Role,[string]$ArchivePath,[string]$Destination)
    $policy=Get-ArtifactPolicy $Role
    $archive=Assert-ArtifactPath $ArchivePath
    $destinationPath=Assert-ArtifactPath $Destination
    if(Test-Path -LiteralPath $destinationPath){throw 'PROVENANCE_DESTINATION_EXISTS'}
    $stream=$null;$zip=$null
    try {
        # Hash and extract through one locked stream: no archive reopen race.
        $stream=[IO.File]::Open($archive,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $digest=Assert-ArtifactStream $stream $policy
        $zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Read,$true)
        if($zip.Entries.Count -lt 1 -or $zip.Entries.Count -gt $policy.maxEntries){throw 'invalid'}
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $total=0L;$entries=@();$executableSha=$null;$requiredSha=$null
        $requiredRelativePath=$null;$requiredExpectedSha=$null
        if($Role -eq 'codexless'){
            $requiredRelativePath=[string]$policy.releaseManifestRelativePath
            $requiredExpectedSha=[string]$policy.releaseManifestSha256
        } elseif($policy.PSObject.Properties['executableRelativePath']) {
            $requiredRelativePath=[string]$policy.executableRelativePath
            if($policy.PSObject.Properties['executableSha256']){$requiredExpectedSha=[string]$policy.executableSha256}
        }
        foreach($entry in $zip.Entries){
            $relative=$entry.FullName.TrimEnd('/')
            if(!$relative -or $relative -match '[\\<>:"|?*\x00-\x1f]' -or $relative.StartsWith('/')){throw 'invalid'}
            foreach($part in $relative.Split('/')){if(!$part -or $part -in @('.','..') -or $part -match '[. ]$' -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)'){throw 'invalid'}}
            if(!$seen.Add($relative) -or ($entry.ExternalAttributes -band 0x400) -or (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000){throw 'invalid'}
            $total+=$entry.Length
            if($total -gt $policy.maxExpandedBytes){throw 'invalid'}
            $entries+= [pscustomobject]@{entry=$entry;relative=$relative;directory=$entry.FullName.EndsWith('/')}
            if($requiredRelativePath -and $relative -ceq $requiredRelativePath){
                $requiredSha=Get-ZipEntrySha256 $entry
                if($Role -ne 'codexless'){$executableSha=$requiredSha}
            }
        }
        if($requiredRelativePath -and !$requiredSha){throw 'invalid'}
        if($requiredExpectedSha -and $requiredSha -cne $requiredExpectedSha){throw 'invalid'}
        # Destination creation happens only after the complete archive preflight.
        New-Item -ItemType Directory -Path $destinationPath -ErrorAction Stop|Out-Null
        foreach($item in $entries){
            $target=Assert-ArtifactPath (Join-Path $destinationPath $item.relative.Replace('/','\'))
            if($item.directory){New-Item -ItemType Directory -Path $target -Force|Out-Null;continue}
            New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force|Out-Null
            $input=$null;$output=$null
            try{
                $input=$item.entry.Open();$output=[IO.File]::Open($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                $buffer=New-Object byte[] 81920;$written=0L
                while(($count=$input.Read($buffer,0,$buffer.Length)) -gt 0){$written+=$count;if($written -gt $item.entry.Length){throw 'invalid'};$output.Write($buffer,0,$count)}
                if($written -ne $item.entry.Length){throw 'invalid'}
                $output.Flush($true)
            }finally{if($input){$input.Dispose()};if($output){$output.Dispose()}}
        }
        [pscustomobject]@{role=$Role;version=$policy.version;archiveSha256=$digest;executableSha256=$executableSha;requiredFileSha256=$requiredSha;fileCount=$zip.Entries.Count;stagedRoot=$destinationPath;promoted=$false}
    } catch { throw 'PROVENANCE_STAGE_FAILED: Artifact was not promoted or executed.' }
    finally{if($zip){$zip.Dispose()};if($stream){$stream.Dispose()}}
}

function Assert-ArtifactRedirect($Policy,[Uri]$Target) {
    # An exact pinned GitHub release asset may redirect once to the official asset CDN.
    # The signed target URL is temporary in-memory transport data; never persist it.
    $origin=[Uri][string]$Policy.url
    $approvedOrigin=(
        ($Policy.role -ceq 'tunnel' -and [string]$Policy.url -ceq 'https://github.com/openai/tunnel-client/releases/download/v0.0.14/tunnel-client-v0.0.14-windows-amd64.zip') -or
        ($Policy.role -ceq 'codexless' -and $origin.Scheme -ceq 'https' -and $origin.Host -ceq 'github.com' -and $origin.IsDefaultPort -and !$origin.UserInfo -and !$origin.Query -and !$origin.Fragment -and $origin.AbsolutePath.StartsWith('/Waterpark621/Codexless/releases/download/',[StringComparison]::Ordinal))
    )
    if(!$approvedOrigin -or $Target.Scheme -cne 'https' -or $Target.Host -cne 'release-assets.githubusercontent.com' -or !$Target.IsDefaultPort -or $Target.UserInfo -or $Target.Fragment -or !$Target.AbsolutePath.StartsWith('/github-production-release-asset/')){throw 'PROVENANCE_REDIRECT_INVALID'}
}

function Save-QualifiedArtifact {
    param([ValidateSet('node','codexless','tunnel')][string]$Role,[string]$StagingDirectory,[ValidateRange(1000,120000)][int]$TimeoutMs=60000)
    $policy=Get-ArtifactPolicy $Role
    $stage=Assert-ArtifactPath $StagingDirectory
    if(Test-Path -LiteralPath $stage){throw 'PROVENANCE_DESTINATION_EXISTS'}
    New-Item -ItemType Directory -Path $stage -ErrorAction Stop|Out-Null
    $path=Join-Path $stage 'download.partial'
    $response=$null;$input=$null;$output=$null
    try{
        $request=[Net.HttpWebRequest]::Create([Uri]$policy.url)
        $request.AllowAutoRedirect=$false;$request.Timeout=$TimeoutMs;$request.ReadWriteTimeout=[Math]::Min(1500,$TimeoutMs)
        $clock=[Diagnostics.Stopwatch]::StartNew()
        $response=$request.GetResponse()
        $expectedUrl=$policy.url
        if([int]$response.StatusCode -eq 302){
            $target=[Uri]$response.Headers['Location']
            Assert-ArtifactRedirect $policy $target
            $response.Dispose();$response=$null
            $remaining=$TimeoutMs-[int]$clock.ElapsedMilliseconds
            if($remaining -le 0){throw 'invalid'}
            # New request: no auth, cookies, or origin headers forwarded.
            $request=[Net.HttpWebRequest]::Create($target)
            $request.AllowAutoRedirect=$false;$request.Timeout=$remaining;$request.ReadWriteTimeout=[Math]::Min(1500,$remaining)
            $response=$request.GetResponse();$expectedUrl=$target.AbsoluteUri
        }
        if([int]$response.StatusCode -ne 200 -or $response.ResponseUri.AbsoluteUri -cne $expectedUrl -or $response.ContentLength -gt $policy.maxArchiveBytes){throw 'invalid'}
        $input=$response.GetResponseStream();$output=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $buffer=New-Object byte[] 81920;$total=0L
        while(($count=$input.Read($buffer,0,$buffer.Length)) -gt 0){
            $total+=$count
            if($total -gt $policy.maxArchiveBytes -or $clock.ElapsedMilliseconds -ge $TimeoutMs){throw 'invalid'}
            $output.Write($buffer,0,$count)
        }
        if($clock.ElapsedMilliseconds -ge $TimeoutMs){throw 'invalid'}
        $output.Flush($true);$output.Position=0
        [void](Assert-ArtifactStream $output $policy)
        $output.Dispose();$output=$null
        $verified=Join-Path $stage 'verified.zip'
        Move-Item -LiteralPath $path -Destination $verified -ErrorAction Stop
        [pscustomobject]@{role=$Role;version=$policy.version;sha256=$policy.sha256;archivePath=$verified;promoted=$false}
    }catch{throw 'PROVENANCE_DOWNLOAD_FAILED: Partial stage retained; nothing was promoted or executed.'}
    finally{if($output){$output.Dispose()};if($input){$input.Dispose()};if($response){$response.Dispose()}}
}

function Assert-CodexlessRelativePath([string]$RelativePath) {
    if([string]::IsNullOrWhiteSpace($RelativePath) -or
       $RelativePath.Contains('\') -or
       $RelativePath -match '[<>:"|?*\x00-\x1f]' -or
       $RelativePath.StartsWith('/') -or
       $RelativePath.EndsWith('/') -or
       $RelativePath.Contains('//')){throw 'invalid'}
    foreach($segment in $RelativePath.Split('/')){
        if([string]::IsNullOrWhiteSpace($segment) -or $segment -in @('.','..') -or
           $segment -match '[. ]$' -or $segment -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)'){throw 'invalid'}
    }
    $RelativePath
}

function Get-ArtifactFileSha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Read-CodexlessDistributionManifest([string]$ManifestPath) {
    if(!(Test-Path -LiteralPath $ManifestPath -PathType Leaf)){throw 'invalid'}
    if((Get-Item -LiteralPath $ManifestPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'invalid'}
    $bytes=[IO.File]::ReadAllBytes($ManifestPath)
    if($bytes.Length -lt 2 -or $bytes.Length -gt 4194304){throw 'invalid'}
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$digest=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    try{
        $utf8=[Text.UTF8Encoding]::new($false,$true);$offset=0
        if($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF){$offset=3}
        $manifest=$utf8.GetString($bytes,$offset,$bytes.Length-$offset)|ConvertFrom-Json -ErrorAction Stop
    }finally{$bytes=$null}
    [pscustomobject]@{sha256=$digest;manifest=$manifest}
}

function Assert-CodexlessDistributionRoot {
    param([string]$Root)
    $policy=Get-ArtifactPolicy codexless
    try {
        $rootPath=Assert-ArtifactPath $Root
        if(!(Test-Path -LiteralPath $rootPath -PathType Container)){throw 'invalid'}
        if($policy.payloadRootRelativePath -cne '.'){throw 'invalid'}
        $manifestRelative=Assert-CodexlessRelativePath ([string]$policy.releaseManifestRelativePath)
        $manifestPath=Join-Path $rootPath $manifestRelative.Replace('/','\')
        $snapshot=Read-CodexlessDistributionManifest $manifestPath
        if($snapshot.sha256 -cne [string]$policy.releaseManifestSha256){throw 'invalid'}
        $manifest=$snapshot.manifest
        if($manifest.manifestVersion -ne 1 -or
           $manifest.productId -cne 'codexless' -or
           [string]$manifest.version -cne [string]$policy.version -or
           [string]$manifest.buildId -cne [string]$policy.buildId -or
           [string]$manifest.sourceRevision -cne [string]$policy.sourceRevision -or
           [string]$manifest.hostContractVersion -cne [string]$policy.hostContractVersion -or
           $manifest.files -isnot [System.Array] -or @($manifest.files).Count -lt 1){throw 'invalid'}

        $expected=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($entry in @($manifest.files)){
            if($null -eq $entry -or !$entry.PSObject.Properties['path'] -or !$entry.PSObject.Properties['sha256']){throw 'invalid'}
            $relative=Assert-CodexlessRelativePath ([string]$entry.path)
            if($relative -ieq $manifestRelative -or !$expected.Add($relative) -or [string]$entry.sha256 -cnotmatch '^[0-9a-f]{64}$'){throw 'invalid'}
            $path=Join-Path $rootPath $relative.Replace('/','\')
            if(!(Test-Path -LiteralPath $path -PathType Leaf)){throw 'invalid'}
            if((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'invalid'}
            if((Get-ArtifactFileSha256 $path) -cne [string]$entry.sha256){throw 'invalid'}
        }
        $launchRelative=Assert-CodexlessRelativePath ([string]$policy.launchScriptRelativePath)
        if(!$expected.Contains($launchRelative)){throw 'invalid'}

        if($policy.requireManifestFileClosure -eq $true){
            if(!$expected.Add($manifestRelative)){throw 'invalid'}
            $actual=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach($item in @(Get-ChildItem -LiteralPath $rootPath -Recurse -Force)){
                if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'invalid'}
                if($item.PSIsContainer){continue}
                $relative=$item.FullName.Substring($rootPath.Length).TrimStart('\').Replace('\','/')
                if(!$actual.Add($relative)){throw 'invalid'}
            }
            if($actual.Count -ne $expected.Count){throw 'invalid'}
            foreach($relative in $actual){if(!$expected.Contains($relative)){throw 'invalid'}}
        }

        [pscustomobject]@{
            role='codexless'
            qualified=$true
            promoted=$false
            root=$rootPath
            version=[string]$manifest.version
            buildId=[string]$manifest.buildId
            sourceRevision=[string]$manifest.sourceRevision
            hostContractVersion=[string]$manifest.hostContractVersion
            manifestSha256=[string]$snapshot.sha256
            controlledFileCount=@($manifest.files).Count
            launchScript=(Join-Path $rootPath $launchRelative.Replace('/','\'))
        }
    } catch { throw 'CODEXLESS_DISTRIBUTION_INVALID: Expanded payload does not match the exact qualified release contract.' }
}

function Stage-QualifiedCodexlessArchive {
    param([string]$ArchivePath,[string]$Destination)
    $policy=Get-ArtifactPolicy codexless
    $expanded=Expand-QualifiedArtifact codexless $ArchivePath $Destination
    $qualified=Assert-CodexlessDistributionRoot $expanded.stagedRoot
    [pscustomobject]@{
        role='codexless'
        qualified=$true
        promoted=$false
        archiveSha256=$expanded.archiveSha256
        stagedRoot=$qualified.root
        version=$qualified.version
        buildId=$qualified.buildId
        sourceRevision=$qualified.sourceRevision
        hostContractVersion=$qualified.hostContractVersion
        manifestSha256=$qualified.manifestSha256
        controlledFileCount=$qualified.controlledFileCount
        launchScript=$qualified.launchScript
    }
}

function Stage-QualifiedCodexlessDistribution {
    param([string]$StagingDirectory,[ValidateRange(1000,120000)][int]$TimeoutMs=60000)
    # This first policy read is intentionally before path normalization or directory creation.
    # An unpublished/partial binding therefore cannot start download or staging mutation.
    $policy=Get-ArtifactPolicy codexless
    $stage=Assert-ArtifactPath $StagingDirectory
    if(Test-Path -LiteralPath $stage){throw 'PROVENANCE_DESTINATION_EXISTS'}
    $download=Save-QualifiedArtifact codexless $stage -TimeoutMs $TimeoutMs
    $expandedPath=Join-Path $stage 'expanded'
    $qualified=Stage-QualifiedCodexlessArchive $download.archivePath $expandedPath
    [pscustomobject]@{
        role='codexless'
        qualified=$true
        promoted=$false
        archivePath=$download.archivePath
        archiveFileName=[string]$policy.archiveFileName
        archiveSha256=$qualified.archiveSha256
        stagedRoot=$qualified.stagedRoot
        version=$qualified.version
        buildId=$qualified.buildId
        sourceRevision=$qualified.sourceRevision
        hostContractVersion=$qualified.hostContractVersion
        manifestSha256=$qualified.manifestSha256
        controlledFileCount=$qualified.controlledFileCount
        launchScript=$qualified.launchScript
    }
}

Export-ModuleMember -Function Get-ArtifactPolicy,Get-CodexlessDistributionBinding,Save-QualifiedArtifact,Expand-QualifiedArtifact,Assert-CodexlessDistributionRoot,Stage-QualifiedCodexlessArchive,Stage-QualifiedCodexlessDistribution
