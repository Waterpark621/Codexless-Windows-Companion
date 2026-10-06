$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression.FileSystem
Import-Module (Join-Path $PSScriptRoot '..\ArtifactProvenance.psm1') -Force
$module=Get-Module ArtifactProvenance
$root=Join-Path $PSScriptRoot ('.fixtures\codexless-distribution-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force|Out-Null
$passed=0
function Assert([bool]$value){if(!$value){throw 'assertion failed'}}
function Test([string]$name,[scriptblock]$body){& $body;$script:passed++;Write-Output "PASS $name"}

Test 'Published distribution binds the exact qualified release asset' {
    $binding=Get-CodexlessDistributionBinding
    Assert ($binding.state -ceq 'published')
    Assert ($binding.url -ceq 'https://github.com/Waterpark621/Codexless/releases/download/v0.1.2-preview.1/codexless-0.1.2-preview.1-windows-x64.zip')
    Assert ($binding.archiveFileName -ceq 'codexless-0.1.2-preview.1-windows-x64.zip')
    Assert ($binding.sha256 -ceq '519d05d0b4ed69a19083aa71f5d9884aebf8bfafae203464fd7294c5680fd8c1')
    Assert ($binding.version -ceq '0.1.2-preview.1')
    Assert ($binding.candidateHead -ceq 'f31549b635090acc78627e1fe2db7e8419dcd7b8')
    Assert ($binding.buildId -ceq '15a17579c9c78448bbbd9af5a6589b1817dbf2fbae968cea7ff16a2fe4837898')
    Assert ($binding.sourceRevision -ceq 'af80d290a265b414de9792b1b53600180be4c0e2')
    Assert ($binding.releaseManifestSha256 -ceq '56f35e9c5b92f8ffca6279ce5bcf8d63ab249489751f900ab564bd7be522fc78')
    Assert ((@($binding.publicationRequiredFields) -join '|') -ceq 'state=published|url|archiveFileName|sha256')
}
Test 'Unbound Codexless distribution refuses before staging mutation' {
    $unpublished=Get-CodexlessDistributionBinding
    $unpublished.state='unpublished';$unpublished.url=$null;$unpublished.archiveFileName=$null;$unpublished.sha256=$null
    & $module {param($p) $script:UnpublishedFixture=$p;function script:Get-CodexlessDistributionBinding {$script:UnpublishedFixture}} $unpublished
    $dest=Join-Path $root 'unbound-stage'
    $failed=$false
    try{Stage-QualifiedCodexlessDistribution $dest|Out-Null}catch{$failed=$_.Exception.Message -like 'PROVENANCE_POLICY_UNBOUND:*'}
    Assert $failed
    Assert (!(Test-Path -LiteralPath $dest))
    Import-Module (Join-Path $PSScriptRoot '../ArtifactProvenance.psm1') -Force
    $script:module=Get-Module ArtifactProvenance
}
Test 'Synthetic Codexless GitHub release redirect is bounded to official asset CDN' {
    $p=[pscustomobject]@{role='codexless';url='https://github.com/Waterpark621/Codexless/releases/download/fixture/fixture.zip'}
    & $module {param($p) Assert-ArtifactRedirect $p ([Uri]'https://release-assets.githubusercontent.com/github-production-release-asset/fixture?temporary=fixture')} $p
    $failed=$false
    try{& $module {param($p) Assert-ArtifactRedirect $p ([Uri]'https://foreign.invalid/github-production-release-asset/fixture')} $p}catch{$failed=$true}
    Assert $failed
}

function New-Fixture {
    param(
        [string]$ManifestVersion='fixture-version',
        [string]$ManifestBuild=('b'*64),
        [string]$ManifestSource=('c'*40),
        [switch]$TamperControlled,
        [switch]$UnexpectedFile
    )
    $id=[Guid]::NewGuid().ToString('N')
    $release=Join-Path $root ('release-'+$id)
    New-Item -ItemType Directory -Path (Join-Path $release 'scripts'),(Join-Path $release 'lib'),(Join-Path $release 'config') -Force|Out-Null
    [IO.File]::WriteAllText((Join-Path $release 'scripts\launch.mjs'),("export const fixture = true;"+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $release 'lib\runtime.mjs'),("export const runtime = 'fixture';"+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
    $files=@(
        [pscustomobject]@{path='scripts/launch.mjs';sha256=(Get-FileHash -LiteralPath (Join-Path $release 'scripts\launch.mjs') -Algorithm SHA256).Hash.ToLowerInvariant()},
        [pscustomobject]@{path='lib/runtime.mjs';sha256=(Get-FileHash -LiteralPath (Join-Path $release 'lib\runtime.mjs') -Algorithm SHA256).Hash.ToLowerInvariant()}
    )
    $manifest=[ordered]@{
        manifestVersion=1
        productId='codexless'
        version=$ManifestVersion
        buildId=$ManifestBuild
        sourceRevision=$ManifestSource
        hostContractVersion='fixture-host'
        files=$files
    }
    $manifestPath=Join-Path $release 'config\release-manifest.json'
    [IO.File]::WriteAllText($manifestPath,($manifest|ConvertTo-Json -Depth 7),[Text.UTF8Encoding]::new($false))
    $manifestSha=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if($TamperControlled){[IO.File]::AppendAllText((Join-Path $release 'lib\runtime.mjs'),'tampered',[Text.UTF8Encoding]::new($false))}
    if($UnexpectedFile){[IO.File]::WriteAllBytes((Join-Path $release 'rogue.exe'),[byte[]](1,2,3,4))}
    $archive=Join-Path $root ('fixture-'+$id+'.zip')
    $stream=[IO.File]::Open($archive,[IO.FileMode]::CreateNew)
    $zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
    try{
        foreach($file in @(Get-ChildItem -LiteralPath $release -Recurse -File | Sort-Object FullName)){
            $relative=$file.FullName.Substring($release.Length).TrimStart('\').Replace('\','/')
            $entry=$zip.CreateEntry($relative,[IO.Compression.CompressionLevel]::Optimal)
            $input=[IO.File]::OpenRead($file.FullName);$output=$entry.Open()
            try{$input.CopyTo($output)}finally{$output.Dispose();$input.Dispose()}
        }
    }finally{$zip.Dispose();$stream.Dispose()}
    $policy=[pscustomobject]@{
        role='codexless'
        state='published'
        version='fixture-version'
        buildId=('b'*64)
        sourceRevision=('c'*40)
        releaseManifestSha256=$manifestSha
        hostContractVersion='fixture-host'
        archiveType='zip'
        sha256=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
        payloadRootRelativePath='.'
        releaseManifestRelativePath='config/release-manifest.json'
        launchScriptRelativePath='scripts/launch.mjs'
        requireManifestFileClosure=$true
        maxArchiveBytes=1048576
        maxExpandedBytes=1048576
        maxEntries=50
    }
    [pscustomobject]@{archive=$archive;release=$release;policy=$policy;destination=(Join-Path $root ('expanded-'+$id))}
}
function Set-FixturePolicy($Policy){
    & $module {
        param($Policy)
        $script:FixturePolicy=$Policy
        function script:Get-ArtifactPolicy {
            param([ValidateSet('node','codexless','tunnel')][string]$Role)
            if($Role -cne 'codexless'){throw 'fixture only supports codexless'}
            $script:FixturePolicy
        }
    } $Policy
}
function Stage-Refuses($Fixture,[switch]$DestinationMustNotExist){
    Set-FixturePolicy $Fixture.policy
    $failed=$false
    try{Stage-QualifiedCodexlessArchive $Fixture.archive $Fixture.destination|Out-Null}catch{$failed=$true}
    Assert $failed
    if($DestinationMustNotExist){Assert (!(Test-Path -LiteralPath $Fixture.destination))}
}

Test 'Wrong Codexless archive checksum is rejected before extraction' {
    $f=New-Fixture
    $f.policy.sha256='0'*64
    Stage-Refuses $f -DestinationMustNotExist
}
Test 'Wrong release manifest checksum is rejected before extraction' {
    $f=New-Fixture
    $f.policy.releaseManifestSha256='0'*64
    Stage-Refuses $f -DestinationMustNotExist
}
Test 'Wrong buildId is rejected after exact manifest binding' {
    $f=New-Fixture -ManifestBuild ('d'*64)
    Stage-Refuses $f
}
Test 'Wrong sourceRevision is rejected after exact manifest binding' {
    $f=New-Fixture -ManifestSource ('e'*40)
    Stage-Refuses $f
}
Test 'Wrong version is rejected after exact manifest binding' {
    $f=New-Fixture -ManifestVersion 'wrong-version'
    Stage-Refuses $f
}
Test 'Changed controlled file is rejected' {
    $f=New-Fixture -TamperControlled
    Stage-Refuses $f
}
Test 'Unexpected executable or file path is rejected by payload closure' {
    $f=New-Fixture -UnexpectedFile
    Stage-Refuses $f
}
Test 'Clean supplied Codexless fixture returns qualified staged root' {
    $f=New-Fixture
    Set-FixturePolicy $f.policy
    $q=Stage-QualifiedCodexlessArchive $f.archive $f.destination
    Assert ($q.qualified -eq $true -and $q.promoted -eq $false)
    Assert ($q.stagedRoot -ceq [IO.Path]::GetFullPath($f.destination))
    Assert ($q.version -ceq 'fixture-version')
    Assert ($q.buildId -ceq ('b'*64))
    Assert ($q.sourceRevision -ceq ('c'*40))
    Assert ($q.hostContractVersion -ceq 'fixture-host')
    Assert ($q.manifestSha256 -ceq $f.policy.releaseManifestSha256)
    Assert ($q.controlledFileCount -eq 2)
}
Test 'Codexless policy contains no machine-local URL or path' {
    $policyPath=Join-Path $PSScriptRoot '..\ARTIFACT-POLICY.json'
    $raw=Get-Content -LiteralPath $policyPath -Raw
    $policy=$raw|ConvertFrom-Json
    Assert ($policy.codexless.state -ceq 'published' -and $policy.codexless.url.StartsWith('https://github.com/Waterpark621/Codexless/releases/download/v0.1.2-preview.1/'))
    Assert ($raw -notmatch '(?i)(?:file://|localhost|127\.0\.0\.1|[A-Z]:\\)')
}

Remove-Item -LiteralPath $root -Recurse -Force
Write-Output ("RESULT: {0}/{0} PASS; local synthetic Codexless archives only; synthetic negative cases plus exact published policy binding" -f $passed)
