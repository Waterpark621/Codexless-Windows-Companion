$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\ArtifactProvenance.psm1') -Force
$module=Get-Module ArtifactProvenance
$root=Join-Path $PSScriptRoot ('.fixtures\artifact-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root|Out-Null
$passed=0
function Assert([bool]$value){if(!$value){throw 'assertion failed'}}
function Test([string]$name,[scriptblock]$body){& $body;$script:passed++;Write-Output "PASS $name"}
Test 'Node source version and archive checksum are explicitly pinned' {$p=Get-ArtifactPolicy node;Assert ($p.version -ceq '24.12.0' -and $p.url.StartsWith('https://nodejs.org/dist/v24.12.0/') -and $p.sha256 -cmatch '^[0-9a-f]{64}$')}
foreach($role in @('codexless')){Test "Unbound $role cannot initiate download or mutation" {$dest=Join-Path $root $role;$failed=$false;try{Save-QualifiedArtifact $role $dest|Out-Null}catch{$failed=$_.Exception.Message -like 'PROVENANCE_POLICY_UNBOUND:*'};Assert $failed;Assert (!(Test-Path -LiteralPath $dest))}}

Test 'Approved full tunnel client pins archive and executable independently' {$p=Get-ArtifactPolicy tunnel;Assert ($p.version -ceq '0.0.14' -and $p.executableSha256 -ceq 'fcc85a69ec0ad82518e4f8964f60c45e31787957782a0fc9c1b0c44e82d61b9b')}
Test 'Only approved GitHub asset CDN redirect is allowed' {$p=Get-ArtifactPolicy tunnel;& $module {param($p) Assert-ArtifactRedirect $p ([Uri]'https://release-assets.githubusercontent.com/github-production-release-asset/fixture?temporary=fixture')} $p}
foreach($url in @('http://release-assets.githubusercontent.com/github-production-release-asset/fixture','https://foreign.example/github-production-release-asset/fixture','https://release-assets.githubusercontent.com/other','https://release-assets.githubusercontent.com:8443/github-production-release-asset/fixture','https://credential@release-assets.githubusercontent.com/github-production-release-asset/fixture','https://release-assets.githubusercontent.com/github-production-release-asset/fixture#fragment')){Test 'Unsafe asset redirect refused' {$p=Get-ArtifactPolicy tunnel;$failed=$false;try{& $module {param($p,$u) Assert-ArtifactRedirect $p ([Uri]$u)} $p $url}catch{$failed=$true};Assert $failed}}

function Fixture([string[]]$Names,[int]$Attributes=0){
    $path=Join-Path $root ([Guid]::NewGuid().ToString('N')+'.zip')
    $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew)
    $zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
    try{foreach($name in $Names){$e=$zip.CreateEntry($name);$e.ExternalAttributes=$Attributes;$writer=[IO.StreamWriter]::new($e.Open());try{$writer.Write('fixture payload')}finally{$writer.Dispose()}}}finally{$zip.Dispose();$stream.Dispose()}
    $p=[pscustomobject]@{role='node';version='fixture';executableRelativePath='release/payload.txt';sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant();maxArchiveBytes=1048576;maxExpandedBytes=1048576;maxEntries=20}
    & $module {param($p) $script:ReviewPolicy=$p;function script:Get-ArtifactPolicy {param($Role) $script:ReviewPolicy}} $p
    [pscustomobject]@{archive=$path;destination=(Join-Path $root ([Guid]::NewGuid().ToString('N')));policy=$p}
}
function Refuses($f){$failed=$false;try{Expand-QualifiedArtifact node $f.archive $f.destination|Out-Null}catch{$failed=$true};Assert $failed;Assert (!(Test-Path -LiteralPath $f.destination))}
Test 'Verified archive stages without executing or promoting files' {$f=Fixture @('release/payload.txt');$r=Expand-QualifiedArtifact node $f.archive $f.destination;Assert (!$r.promoted -and $r.fileCount -eq 1);Assert ((Get-Content -LiteralPath (Join-Path $f.destination 'release\payload.txt') -Raw) -ceq 'fixture payload');Assert ($r.executableSha256 -ceq (Get-FileHash -LiteralPath (Join-Path $f.destination 'release\payload.txt') -Algorithm SHA256).Hash.ToLowerInvariant())}
Test 'Pinned executable mismatch refuses extraction before mutation' {$f=Fixture @('release/payload.txt');$f.policy|Add-Member executableSha256 ('0'*64);Refuses $f}
Test 'Checksum mismatch is rejected before destination mutation' {$f=Fixture @('payload.txt');$f.policy.sha256='0'*64;Refuses $f}
foreach($name in @('../escape.txt','/absolute.txt','C:/drive.txt','safe\escape.txt','safe/name.','safe/CON.txt')) {Test "Unsafe ZIP entry rejected: $name" {$f=Fixture @($name);Refuses $f}}
Test 'Case-insensitive duplicate entries are rejected before mutation' {$f=Fixture @('safe.txt','SAFE.txt');Refuses $f}
Test 'Symlink entry is rejected before mutation' {$f=Fixture @('link') -Attributes (-1610612736);Refuses $f}
Test 'Archive byte limit is checked before mutation' {$f=Fixture @('safe.txt');$f.policy.maxArchiveBytes=1;Refuses $f}
Test 'Expanded byte limit is checked before mutation' {$f=Fixture @('safe.txt');$f.policy.maxExpandedBytes=1;Refuses $f}
Test 'Entry count limit is checked before mutation' {$f=Fixture @('one','two');$f.policy.maxEntries=1;Refuses $f}
Test 'Existing destination is never overwritten' {$f=Fixture @('safe.txt');New-Item -ItemType Directory -Path $f.destination|Out-Null;'sentinel'|Set-Content -LiteralPath (Join-Path $f.destination 'sentinel');$failed=$false;try{Expand-QualifiedArtifact node $f.archive $f.destination|Out-Null}catch{$failed=$true};Assert $failed;Assert ((Get-Content -LiteralPath (Join-Path $f.destination 'sentinel')) -ceq 'sentinel')}

# Exercise the production streaming download path against an ephemeral server.
# Only policy lookup is injected in this test module; production has no hook.
$node=(Get-Command node.exe).Source
$serverScript=Join-Path $root 'download-server.mjs'
$infoPath=Join-Path $root 'download-server.json'
$hitsPath=Join-Path $root 'download-hits.json'
$f=Fixture @('release/payload.txt')
[IO.File]::WriteAllText($serverScript,@'
import http from 'node:http';
import fs from 'node:fs';
const payload=fs.readFileSync(process.argv[2]);
const hits=[];
const server=http.createServer((req,res)=>{
  hits.push(req.url);fs.writeFileSync(process.argv[4],JSON.stringify(hits));
  if(req.url==='/redirect'){res.writeHead(302,{location:'/good'});res.end();return;}
  if(req.url==='/slow'){
    res.writeHead(200);res.write('x');
    const timer=setInterval(()=>res.write('x'),100);
    res.on('close',()=>clearInterval(timer));return;
  }
  if(req.url==='/large'){res.writeHead(200);res.end(Buffer.alloc(200000));return;}
  res.writeHead(200);res.end(payload);
});
server.listen(0,'127.0.0.1',()=>fs.writeFileSync(process.argv[3],JSON.stringify({port:server.address().port})));
const watcher=setInterval(()=>{if(fs.existsSync(process.argv[5])){clearInterval(watcher);server.close(()=>process.exit(0));}},50);
'@,[Text.UTF8Encoding]::new($false))
$quitPath=Join-Path $root 'server-stop.flag'
$serverArgs=@($serverScript,$f.archive,$infoPath,$hitsPath,$quitPath)|ForEach-Object {'"'+$_+'"'}
$server=Start-Process -FilePath $node -ArgumentList $serverArgs -WindowStyle Hidden -PassThru
try {
    $deadline=[DateTime]::UtcNow.AddSeconds(5)
    while(!(Test-Path -LiteralPath $infoPath)){if([DateTime]::UtcNow -ge $deadline){throw 'fixture timeout'};Start-Sleep -Milliseconds 25}
    $port=[int]((Get-Content -LiteralPath $infoPath -Raw|ConvertFrom-Json).port)
    function Set-DownloadPolicy([string]$Mode){
        $p=[pscustomobject]@{role='node';version='fixture';url="http://127.0.0.1:$port/$Mode";sha256=(Get-FileHash -LiteralPath $f.archive -Algorithm SHA256).Hash.ToLowerInvariant();maxArchiveBytes=1048576}
        & $module {param($p) $script:ReviewPolicy=$p} $p
        $p
    }
    function Download-Refuses([string]$Mode,[int]$Timeout=5000){
        $dest=Join-Path $root ([Guid]::NewGuid().ToString('N'));$failed=$false
        try{Save-QualifiedArtifact node $dest -TimeoutMs $Timeout|Out-Null}catch{$failed=$_.Exception.Message -ceq 'PROVENANCE_DOWNLOAD_FAILED: Partial stage retained; nothing was promoted or executed.'}
        Assert $failed;Assert (!(Test-Path -LiteralPath (Join-Path $dest 'verified.zip')))
    }
    Test 'Download success requires exact pinned archive bytes without promotion' {Set-DownloadPolicy good|Out-Null;$dest=Join-Path $root ([Guid]::NewGuid().ToString('N'));$r=Save-QualifiedArtifact node $dest;Assert (!$r.promoted);Assert ($r.sha256 -ceq (Get-FileHash -LiteralPath $r.archivePath -Algorithm SHA256).Hash.ToLowerInvariant())}
    Test 'Redirect is rejected without following target' {$p=Set-DownloadPolicy redirect;Download-Refuses redirect;$after=Get-Content -LiteralPath $hitsPath -Raw|ConvertFrom-Json;Assert ($after[-1] -ceq '/redirect')}
    Test 'Checksum substitution never creates a verified archive' {$p=Set-DownloadPolicy good;$p.sha256='0'*64;Download-Refuses good}
    Test 'Stream exceeding byte limit is rejected' {$p=Set-DownloadPolicy large;$p.maxArchiveBytes=1024;Download-Refuses large}
    Test 'Trickling response obeys overall deadline' {Set-DownloadPolicy slow|Out-Null;$clock=[Diagnostics.Stopwatch]::StartNew();Download-Refuses slow 1000;Assert ($clock.ElapsedMilliseconds -lt 2500)}
} finally {
    New-Item -ItemType File -Path $quitPath -Force|Out-Null
    if(!$server.WaitForExit(5000)){throw 'fixture did not cooperatively exit'}
    $server.Dispose()
}
Write-Output ("RESULT: {0}/{0} PASS; synthetic ZIP and loopback streaming fixtures; no external downloads or artifact execution" -f $passed)
