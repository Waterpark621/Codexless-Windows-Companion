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

function Get-ArtifactPolicy {
    param([ValidateSet('node','codexless','tunnel')][string]$Role)
    try {
        $document=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'ARTIFACT-POLICY.json') -Raw|ConvertFrom-Json
        if($document.schemaVersion -ne 1){throw 'invalid'}
        $policy=$document.$Role
        if($null -eq $policy){throw 'unbound'}
        $uri=[Uri]$policy.url
        if($policy.role -cne $Role -or $policy.sha256 -cnotmatch '^[0-9a-f]{64}$' -or $uri.Scheme -cne 'https' -or $uri.UserInfo -or $uri.Fragment -or $uri.Query -or !$uri.IsDefaultPort){throw 'invalid'}
        if($Role -eq 'node' -and ($policy.version -cne '24.12.0' -or $policy.architecture -cne 'win-x64' -or $policy.url -cne 'https://nodejs.org/dist/v24.12.0/node-v24.12.0-win-x64.zip')){throw 'invalid'}
        if($Role -eq 'tunnel' -and ($policy.version -cne '0.0.14' -or $policy.architecture -cne 'windows-amd64' -or $policy.url -cne 'https://github.com/openai/tunnel-client/releases/download/v0.0.14/tunnel-client-v0.0.14-windows-amd64.zip' -or $policy.executableSha256 -cne 'fcc85a69ec0ad82518e4f8964f60c45e31787957782a0fc9c1b0c44e82d61b9b')){throw 'invalid'}
        if($Role -eq 'codexless'){throw 'unbound'}
        if($policy.archiveType -cne 'zip' -or $policy.maxArchiveBytes -le 0 -or $policy.maxArchiveBytes -gt 536870912 -or $policy.maxExpandedBytes -le 0 -or $policy.maxExpandedBytes -gt 1073741824 -or $policy.maxEntries -lt 1 -or $policy.maxEntries -gt 10000){throw 'invalid'}
        $policy
    } catch { throw 'PROVENANCE_POLICY_UNBOUND: An approved source/version/archive pin is required.' }
}

function Assert-ArtifactStream($Stream,$Policy) {
    if($Stream.Length -le 0 -or $Stream.Length -gt [long]$Policy.maxArchiveBytes){throw 'PROVENANCE_ARCHIVE_INVALID'}
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$digest=([BitConverter]::ToString($sha.ComputeHash($Stream))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    if($digest -cne [string]$Policy.sha256){throw 'PROVENANCE_HASH_MISMATCH'}
    $Stream.Position=0
    $digest
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
        $total=0L;$entries=@();$executableSha=$null
        foreach($entry in $zip.Entries){
            $relative=$entry.FullName.TrimEnd('/')
            if(!$relative -or $relative -match '[\\<>:"|?*\x00-\x1f]' -or $relative.StartsWith('/')){throw 'invalid'}
            foreach($part in $relative.Split('/')){if(!$part -or $part -in @('.','..') -or $part -match '[. ]$' -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)'){throw 'invalid'}}
            if(!$seen.Add($relative) -or ($entry.ExternalAttributes -band 0x400) -or (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000){throw 'invalid'}
            $total+=$entry.Length
            if($total -gt $policy.maxExpandedBytes){throw 'invalid'}
            $entries+= [pscustomobject]@{entry=$entry;relative=$relative;directory=$entry.FullName.EndsWith('/')}
            if($relative -ceq [string]$policy.executableRelativePath){
                $entryStream=$entry.Open();$entryHash=[Security.Cryptography.SHA256]::Create()
                try{$executableSha=([BitConverter]::ToString($entryHash.ComputeHash($entryStream))).Replace('-','').ToLowerInvariant()}finally{$entryHash.Dispose();$entryStream.Dispose()}
            }
        }
        if(!$executableSha){throw 'invalid'}
        if($policy.PSObject.Properties['executableSha256'] -and $executableSha -cne $policy.executableSha256){throw 'invalid'}
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
        [pscustomobject]@{role=$Role;version=$policy.version;archiveSha256=$digest;executableSha256=$executableSha;fileCount=$zip.Entries.Count;stagedRoot=$destinationPath;promoted=$false}
    } catch { throw 'PROVENANCE_STAGE_FAILED: Artifact was not promoted or executed.' }
    finally{if($zip){$zip.Dispose()};if($stream){$stream.Dispose()}}
}

function Assert-ArtifactRedirect($Policy,[Uri]$Target) {
    # Only the pinned GitHub asset may redirect once to its official asset CDN.
    # The signed URL is temporary in-memory transport data; never persist it.
    if($Policy.role -cne 'tunnel' -or $Policy.url -cne 'https://github.com/openai/tunnel-client/releases/download/v0.0.14/tunnel-client-v0.0.14-windows-amd64.zip' -or $Target.Scheme -cne 'https' -or $Target.Host -cne 'release-assets.githubusercontent.com' -or !$Target.IsDefaultPort -or $Target.UserInfo -or $Target.Fragment -or !$Target.AbsolutePath.StartsWith('/github-production-release-asset/')){throw 'PROVENANCE_REDIRECT_INVALID'}
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

Export-ModuleMember -Function Get-ArtifactPolicy,Save-QualifiedArtifact,Expand-QualifiedArtifact
