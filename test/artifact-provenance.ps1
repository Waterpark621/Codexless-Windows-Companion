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
foreach($role in @('codexless','tunnel')){Test "Unbound $role cannot initiate download or mutation" {$dest=Join-Path $root $role;$failed=$false;try{Save-QualifiedArtifact $role $dest|Out-Null}catch{$failed=$_.Exception.Message -like 'PROVENANCE_POLICY_UNBOUND:*'};Assert $failed;Assert (!(Test-Path -LiteralPath $dest))}}

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
Test 'Checksum mismatch is rejected before destination mutation' {$f=Fixture @('payload.txt');$f.policy.sha256='0'*64;Refuses $f}
foreach($name in @('../escape.txt','/absolute.txt','C:/drive.txt','safe\escape.txt','safe/name.','safe/CON.txt')) {Test "Unsafe ZIP entry rejected: $name" {$f=Fixture @($name);Refuses $f}}
Test 'Case-insensitive duplicate entries are rejected before mutation' {$f=Fixture @('safe.txt','SAFE.txt');Refuses $f}
Test 'Symlink entry is rejected before mutation' {$f=Fixture @('link') -Attributes (-1610612736);Refuses $f}
Test 'Archive byte limit is checked before mutation' {$f=Fixture @('safe.txt');$f.policy.maxArchiveBytes=1;Refuses $f}
Test 'Expanded byte limit is checked before mutation' {$f=Fixture @('safe.txt');$f.policy.maxExpandedBytes=1;Refuses $f}
Test 'Entry count limit is checked before mutation' {$f=Fixture @('one','two');$f.policy.maxEntries=1;Refuses $f}
Test 'Existing destination is never overwritten' {$f=Fixture @('safe.txt');New-Item -ItemType Directory -Path $f.destination|Out-Null;'sentinel'|Set-Content -LiteralPath (Join-Path $f.destination 'sentinel');$failed=$false;try{Expand-QualifiedArtifact node $f.archive $f.destination|Out-Null}catch{$failed=$true};Assert $failed;Assert ((Get-Content -LiteralPath (Join-Path $f.destination 'sentinel')) -ceq 'sentinel')}
Write-Output ("RESULT: {0}/{0} PASS; synthetic ZIP fixtures only; no downloads or binary execution" -f $passed)
