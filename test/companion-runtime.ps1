$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\CompanionRuntime.psm1') -Force
$module=Get-Module CompanionRuntime

$root=Join-Path $PSScriptRoot ('.fixtures\companion-runtime-'+[Guid]::NewGuid().ToString('N'))
$companion=Join-Path $root 'companion'
$codexless=Join-Path $root 'codexless'
$project=Join-Path $root 'project'
New-Item -ItemType Directory -Force -Path $companion,$project,(Join-Path $codexless 'config'),(Join-Path $codexless 'scripts'),(Join-Path $codexless 'src'),(Join-Path $codexless 'docs')|Out-Null

$fixtureVersion='0.1.2-preview.1-fixture'
$fixtureBuild=('b'*64)
$fixtureSource=('c'*40)
$fixtureHost='codexless-public-preview-v1'
$critical=@(
  @{path='scripts/launch.mjs';content='export const fixture = true;'},
  @{path='src/mcp-http-public.mjs';content='export const fixture = true;'},
  @{path='src/codexless-runtime.mjs';content='export const fixture = true;'},
  @{path='package.json';content='{"name":"codexless","version":"0.1.2-preview.1-fixture"}'},
  @{path='docs/fixture.txt';content='noncritical fixture payload'}
)
$entries=@()
foreach($f in $critical){
  $path=Join-Path $codexless ($f.path.Replace('/','\'))
  $parent=Split-Path $path -Parent
  New-Item -ItemType Directory -Force -Path $parent|Out-Null
  [IO.File]::WriteAllText($path,$f.content,[Text.UTF8Encoding]::new($false))
  $entries += [pscustomobject]@{path=$f.path;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
}
$manifestPath=Join-Path $codexless 'config\release-manifest.json'

function Set-FixtureQualification {
  param(
    [string]$Version=$script:fixtureVersion,
    [string]$BuildId=$script:fixtureBuild,
    [string]$SourceRevision=$script:fixtureSource
  )
  $sha=(Get-FileHash -LiteralPath $script:manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $q=[pscustomobject]@{
    version=$Version
    buildId=$BuildId
    sourceRevision=$SourceRevision
    manifestSha256=$sha
  }
  & $script:module { param($value) $script:QualifiedCodexlessRelease=$value } $q
}

function Write-FixtureManifest {
  param(
    [string]$Version=$script:fixtureVersion,
    [string]$BuildId=$script:fixtureBuild,
    [string]$SourceRevision=$script:fixtureSource,
    [string]$HostContract=$script:fixtureHost,
    [object[]]$Files=$script:entries
  )
  [ordered]@{
    manifestVersion=1
    productId='codexless'
    version=$Version
    buildId=$BuildId
    sourceRevision=$SourceRevision
    hostContractVersion=$HostContract
    files=$Files
  }|ConvertTo-Json -Depth 7|Set-Content -LiteralPath $script:manifestPath -Encoding utf8
  Set-FixtureQualification
}

Write-FixtureManifest

$node=(Get-Command node.exe -ErrorAction Stop).Source
$settings=[ordered]@{schemaVersion=1;project=[ordered]@{path=$project};codexless=[ordered]@{root=$codexless;nodeExe=$node;nodeSha256='2ffe3acc0458fdde999f50d11809bbe7c9b7ef204dcf17094e325d26ace101d8';port=17690};tunnel=[ordered]@{enabled=$false}}
$settings|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $companion 'settings.json') -Encoding utf8

$passed=0
function Assert([bool]$value){if(!$value){throw 'assertion failed'}}
function Test([string]$name,[scriptblock]$body){& $body;$script:passed++;Write-Output "PASS $name"}
function Assert-ReleaseFailure {
  $failed=$false
  try { Get-CompanionConfig $script:companion|Out-Null } catch { $failed=$_.Exception.Message -like 'CODEXLESS_RELEASE_INVALID:*' }
  Assert $failed
}

Test 'Portable settings resolve exact qualified release identity dynamically' {
  $cfg=Get-CompanionConfig $companion
  Assert ($cfg.projectPath -ceq [IO.Path]::GetFullPath($project))
  Assert ($cfg.codexlessRoot -ceq [IO.Path]::GetFullPath($codexless))
  Assert ($cfg.release.version -ceq $fixtureVersion)
  Assert ($cfg.release.buildId -ceq $fixtureBuild)
  Assert ($cfg.release.sourceRevision -ceq $fixtureSource)
  Assert ($cfg.release.fileCount -eq $entries.Count)
  Assert ($cfg.release.hostContractVersion -ceq $fixtureHost)
  Assert ($cfg.release.launchScript -ceq [IO.Path]::GetFullPath((Join-Path $codexless 'scripts\launch.mjs')))
  Assert (Test-Path -LiteralPath $cfg.release.launchScript -PathType Leaf)
  Assert (@($cfg.tunnels).Count -eq 0)
}

Test 'Every manifest-controlled release file is hash verified' {
  $path=Join-Path $codexless 'docs\fixture.txt'
  $before=[IO.File]::ReadAllText($path)
  try {
    [IO.File]::AppendAllText($path,'changed')
    Assert-ReleaseFailure
  } finally {
    [IO.File]::WriteAllText($path,$before,[Text.UTF8Encoding]::new($false))
  }
}

Test 'Changed critical release file fails closed' {
  $path=Join-Path $codexless 'scripts\launch.mjs'
  $before=[IO.File]::ReadAllText($path)
  try {
    [IO.File]::AppendAllText($path,'changed')
    Assert-ReleaseFailure
  } finally {
    [IO.File]::WriteAllText($path,$before,[Text.UTF8Encoding]::new($false))
  }
}

Test 'Qualified manifest bytes are pinned exactly' {
  $saved=[IO.File]::ReadAllBytes($manifestPath)
  try {
    [IO.File]::AppendAllText($manifestPath," ")
    Assert-ReleaseFailure
  } finally {
    [IO.File]::WriteAllBytes($manifestPath,$saved)
  }
}

Test 'Manifest snapshot hashes and parses the same bytes across replacement' {
  $qualifiedBytes=[IO.File]::ReadAllBytes($manifestPath)
  $qualifiedSha=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
  try {
    $snapshot=& $module { param($p) Read-CodexlessReleaseManifestSnapshot $p } $manifestPath
    $replacement=(Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json)
    $replacement.files=@($replacement.files|Where-Object {[string]$_.path -ceq 'scripts/launch.mjs'})
    $replacement|ConvertTo-Json -Depth 7|Set-Content -LiteralPath $manifestPath -Encoding utf8

    $diskAfter=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
    Assert ($snapshot.sha256 -ceq $qualifiedSha)
    Assert (@($snapshot.manifest.files).Count -eq $entries.Count)
    Assert (@($diskAfter.files).Count -eq 1)
    Assert (@($snapshot.manifest.files).Count -ne @($diskAfter.files).Count)
  } finally {
    [IO.File]::WriteAllBytes($manifestPath,$qualifiedBytes)
    Set-FixtureQualification
  }
}

Test 'Release identity consumes one manifest snapshot with no separate hash or content read' {
  $source=Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\CompanionRuntime.psm1') -Raw
  $start=$source.IndexOf('function Get-CodexlessReleaseIdentity {')
  $end=$source.IndexOf('function Assert-PathWithinRoot {')
  Assert ($start -ge 0 -and $end -gt $start)
  $block=$source.Substring($start,$end-$start)
  Assert ($block.Contains('$snapshot=Read-CodexlessReleaseManifestSnapshot $manifestPath'))
  Assert (!$block.Contains('Get-FileHash -LiteralPath $manifestPath'))
  Assert (!$block.Contains('Get-Content -LiteralPath $manifestPath'))
}

Test 'Version build and source identity mismatches fail closed even with current manifest hash' {
  foreach($field in @('version','buildId','sourceRevision')){
    $saved=Get-Content -LiteralPath $manifestPath -Raw
    try {
      $m=$saved|ConvertFrom-Json
      if($field -eq 'version'){$m.version='other-version'}
      elseif($field -eq 'buildId'){$m.buildId=('d'*64)}
      else{$m.sourceRevision=('e'*40)}
      $m|ConvertTo-Json -Depth 7|Set-Content -LiteralPath $manifestPath -Encoding utf8
      Set-FixtureQualification
      Assert-ReleaseFailure
    } finally {
      [IO.File]::WriteAllText($manifestPath,$saved,[Text.UTF8Encoding]::new($false))
      Set-FixtureQualification
    }
  }
}

Test 'Unknown host contract fails closed' {
  $saved=Get-Content -LiteralPath $manifestPath -Raw
  try {
    $m=$saved|ConvertFrom-Json
    $m.hostContractVersion='unknown-contract'
    $m|ConvertTo-Json -Depth 7|Set-Content -LiteralPath $manifestPath -Encoding utf8
    Set-FixtureQualification
    Assert-ReleaseFailure
  } finally {
    [IO.File]::WriteAllText($manifestPath,$saved,[Text.UTF8Encoding]::new($false))
    Set-FixtureQualification
  }
}

Test 'Duplicate case-insensitive manifest paths fail closed' {
  $saved=Get-Content -LiteralPath $manifestPath -Raw
  try {
    $m=$saved|ConvertFrom-Json
    $duplicate=[pscustomobject]@{path='DOCS/FIXTURE.TXT';sha256=('f'*64)}
    $m.files=@($m.files)+@($duplicate)
    $m|ConvertTo-Json -Depth 7|Set-Content -LiteralPath $manifestPath -Encoding utf8
    Set-FixtureQualification
    Assert-ReleaseFailure
  } finally {
    [IO.File]::WriteAllText($manifestPath,$saved,[Text.UTF8Encoding]::new($false))
    Set-FixtureQualification
  }
}

Test 'Launch command is release-derived and strips NODE_OPTIONS before Node' {
  $cfg=Get-CompanionConfig $companion
  $command=Get-CodexlessPrivateConsoleCommand $cfg
  Assert ($command.Contains($cfg.nodeExe))
  Assert ($command.Contains($cfg.launchScript))
  Assert ($command.Contains("CODEX_TOOLBOX_PUBLIC_PORT='17690'"))
  Assert ($command.Contains('Remove-Item Env:NODE_OPTIONS'))
  Assert ($command -notmatch 'Core\.ps1|Host\.ps1|verified-codex-runtime|Start-VerifiedHousehold')
}

Test 'Qualified launch child receives no ambient NODE_OPTIONS' {
  $probeScript=Join-Path $root 'node-options-probe.mjs'
  $probeOutput=Join-Path $root 'node-options-result.json'
  [IO.File]::WriteAllText($probeScript,@'
import fs from "node:fs";
const target = process.env.COMPANION_TEST_OUTPUT;
fs.writeFileSync(target, JSON.stringify({
  nodeOptions: process.env.NODE_OPTIONS ?? null,
  port: process.env.CODEX_TOOLBOX_PUBLIC_PORT ?? null
}));
'@,[Text.UTF8Encoding]::new($false))
  $probeCfg=[pscustomobject]@{nodeExe=$node;nodeSha256='2ffe3acc0458fdde999f50d11809bbe7c9b7ef204dcf17094e325d26ace101d8';launchScript=$probeScript;port=17691}
  $command=Get-CodexlessPrivateConsoleCommand $probeCfg
  $hadNodeOptions=Test-Path Env:NODE_OPTIONS
  $savedNodeOptions=if($hadNodeOptions){[string]$env:NODE_OPTIONS}else{$null}
  $hadOutput=Test-Path Env:COMPANION_TEST_OUTPUT
  $savedOutput=if($hadOutput){[string]$env:COMPANION_TEST_OUTPUT}else{$null}
  try {
    $env:NODE_OPTIONS='--trace-warnings'
    $env:COMPANION_TEST_OUTPUT=$probeOutput
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $command
    Assert ($LASTEXITCODE -eq 0)
    $result=Get-Content -LiteralPath $probeOutput -Raw|ConvertFrom-Json
    Assert ($null -eq $result.nodeOptions)
    Assert ([string]$result.port -ceq '17691')
  } finally {
    if($hadNodeOptions){$env:NODE_OPTIONS=$savedNodeOptions}else{Remove-Item Env:NODE_OPTIONS -ErrorAction SilentlyContinue}
    if($hadOutput){$env:COMPANION_TEST_OUTPUT=$savedOutput}else{Remove-Item Env:COMPANION_TEST_OUTPUT -ErrorAction SilentlyContinue}
  }
}

Test 'Qualified launch rejects same-path Node byte replacement before execution' {
  $fakeNode=Join-Path $root 'node-replaced.exe'
  $probeScript=Join-Path $root 'node-replaced-probe.mjs'
  $probeOutput=Join-Path $root 'node-replaced-result.txt'
  Copy-Item -LiteralPath $node -Destination $fakeNode -Force
  [IO.File]::WriteAllText($probeScript,'process.exitCode = 0;',[Text.UTF8Encoding]::new($false))
  $expected=(Get-FileHash -LiteralPath $fakeNode -Algorithm SHA256).Hash.ToLowerInvariant()
  $probeCfg=[pscustomobject]@{nodeExe=$fakeNode;nodeSha256=$expected;launchScript=$probeScript;port=17692}
  $command=Get-CodexlessPrivateConsoleCommand $probeCfg
  [IO.File]::WriteAllBytes($fakeNode,[Text.Encoding]::ASCII.GetBytes('same-path replacement'))
  $hadOutput=Test-Path Env:COMPANION_TEST_OUTPUT
  $savedOutput=if($hadOutput){[string]$env:COMPANION_TEST_OUTPUT}else{$null}
  $savedPreference=$ErrorActionPreference
  try {
    $env:COMPANION_TEST_OUTPUT=$probeOutput
    $ErrorActionPreference='Continue'
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $command 2>$null
    $exitCode=$LASTEXITCODE
    Assert ($exitCode -ne 0)
    Assert (!(Test-Path -LiteralPath $probeOutput))
  } finally {
    $ErrorActionPreference=$savedPreference
    if($hadOutput){$env:COMPANION_TEST_OUTPUT=$savedOutput}else{Remove-Item Env:COMPANION_TEST_OUTPUT -ErrorAction SilentlyContinue}
  }
}

Test 'Readiness requires exact build and source and rejects cwd metadata' {
  $serverScript=Join-Path $root 'ready-server.mjs'
  $serverInfo=Join-Path $root 'ready-server.json'
  $payloadPath=Join-Path $root 'ready-payload.json'
  [IO.File]::WriteAllText($serverScript,@'
import http from "node:http";
import fs from "node:fs";
const infoPath = process.argv[2];
const payloadPath = process.argv[3];
const server = http.createServer((req, res) => {
  if (req.url !== "/readyz") {
    res.writeHead(404, {"content-type":"application/json"});
    res.end("{}");
    return;
  }
  const body = fs.readFileSync(payloadPath, "utf8");
  res.writeHead(200, {"content-type":"application/json"});
  res.end(body);
});
server.listen(0, "127.0.0.1", () => {
  fs.writeFileSync(infoPath, JSON.stringify({port:server.address().port}));
});
const timer=setInterval(() => {
  if(fs.existsSync(infoPath+'.stop')) {clearInterval(timer);server.close();}
},50);
setTimeout(()=>{clearInterval(timer);server.close();},30000).unref();
'@,[Text.UTF8Encoding]::new($false))

  $payload=[ordered]@{
    ok=$true
    service='codexless-public'
    transport='streamable-http'
    publicPreview=$true
    version=$fixtureVersion
    surfaceVersion=$fixtureHost
    buildId=$fixtureBuild
    sourceRevision=$fixtureSource
    toolCount=44
  }
  $payload|ConvertTo-Json -Compress|Set-Content -LiteralPath $payloadPath -Encoding ascii
  $server=Start-Process -FilePath $node -ArgumentList @($serverScript,$serverInfo,$payloadPath) -PassThru -WindowStyle Hidden
  try {
    $deadline=[DateTime]::UtcNow.AddSeconds(5)
    while(!(Test-Path -LiteralPath $serverInfo)){
      if([DateTime]::UtcNow -ge $deadline){throw 'ready fixture timeout'}
      Start-Sleep -Milliseconds 50
    }
    $port=[int]((Get-Content -LiteralPath $serverInfo -Raw|ConvertFrom-Json).port)
    $readyCfg=[pscustomobject]@{
      readyUrl="http://127.0.0.1:$port/readyz"
      release=[pscustomobject]@{
        version=$fixtureVersion
        buildId=$fixtureBuild
        sourceRevision=$fixtureSource
        hostContractVersion=$fixtureHost
      }
    }
    Assert (Test-CodexlessReady $readyCfg 1500)

    $bad=[ordered]@{}+$payload
    $bad.buildId=('0'*64)
    $bad|ConvertTo-Json -Compress|Set-Content -LiteralPath $payloadPath -Encoding ascii
    Assert (!(Test-CodexlessReady $readyCfg 1500))

    $bad=[ordered]@{}+$payload
    $bad.sourceRevision=('1'*40)
    $bad|ConvertTo-Json -Compress|Set-Content -LiteralPath $payloadPath -Encoding ascii
    Assert (!(Test-CodexlessReady $readyCfg 1500))

    $bad=[ordered]@{}+$payload
    $bad.defaultCwd='C:\private\project'
    $bad|ConvertTo-Json -Compress|Set-Content -LiteralPath $payloadPath -Encoding ascii
    Assert (!(Test-CodexlessReady $readyCfg 1500))

    $payload|ConvertTo-Json -Compress|Set-Content -LiteralPath $payloadPath -Encoding ascii
    Assert (Test-CodexlessReady $readyCfg 1500)
  } finally {
    if($null -ne $server -and !$server.HasExited){
      [IO.File]::WriteAllText($serverInfo+'.stop','stop')
      if(!$server.WaitForExit(10000)){throw 'readiness fixture did not cooperatively exit; retained without force termination'}
    }
    if($null -ne $server){$server.Dispose()}
  }
}

Test 'Tunnel key path cannot escape Companion root' {
  $profile=Join-Path $root 'tunnel-profile';New-Item -ItemType Directory -Force -Path $profile|Out-Null
  $exe=Join-Path $root 'tunnel-client.exe';[IO.File]::WriteAllBytes($exe,[byte[]](1,2,3))
  $bad=[ordered]@{schemaVersion=1;project=[ordered]@{path=$project};codexless=[ordered]@{root=$codexless;nodeExe=$node;nodeSha256='2ffe3acc0458fdde999f50d11809bbe7c9b7ef204dcf17094e325d26ace101d8';port=17690};tunnel=[ordered]@{enabled=$true;executable=$exe;profileDir=$profile;alias='fixture';tunnelId='fixture-id';keyFile='..\outside.dpapi'}}
  $bad|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $companion 'settings.json') -Encoding utf8
  $failed=$false
  try { Get-CompanionConfig $companion|Out-Null } catch { $failed=$_.Exception.Message -like 'COMPANION_SETTINGS_INVALID:*' }
  Assert $failed
}

Test 'Relative tunnel profile and DPAPI key stay inside Companion root' {
  $profile=Join-Path $companion 'tunnel-profile';New-Item -ItemType Directory -Force -Path $profile|Out-Null
  $keys=Join-Path $companion 'keys';New-Item -ItemType Directory -Force -Path $keys|Out-Null
  $exe=Join-Path $root 'tunnel-client.exe'
  $secret=ConvertTo-SecureString 'fixture-runtime-key' -AsPlainText -Force
  ConvertFrom-SecureString -SecureString $secret|Set-Content -LiteralPath (Join-Path $keys 'runtime-key.dpapi') -Encoding ascii
  $good=[ordered]@{schemaVersion=1;project=[ordered]@{path=$project};codexless=[ordered]@{root=$codexless;nodeExe=$node;nodeSha256='2ffe3acc0458fdde999f50d11809bbe7c9b7ef204dcf17094e325d26ace101d8';port=17690};tunnel=[ordered]@{enabled=$true;executable=$exe;profileDir='tunnel-profile';alias='fixture';tunnelId='fixture-id';keyFile='keys/runtime-key.dpapi'}}
  $good|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $companion 'settings.json') -Encoding utf8
  $cfg=Get-CompanionConfig $companion
  Assert ($cfg.profileDir -ceq [IO.Path]::GetFullPath($profile))
  Assert ($cfg.tunnels[0].keyPath -ceq [IO.Path]::GetFullPath((Join-Path $keys 'runtime-key.dpapi')))
  $plain=Get-PlainRuntimeKey $cfg.tunnels[0]
  try { Assert ($plain -ceq 'fixture-runtime-key') } finally { $plain=$null }
}

Test 'Root-relative drive-relative and UNC paths are rejected' {
  foreach($badPath in @('\Windows','C:Windows','\\server\share')) {
    $failed=$false
    try { & $module { param($p) Resolve-CompanionLocalPath $p 'fixture' } $badPath | Out-Null } catch { $failed=$_.Exception.Message -like 'COMPANION_SETTINGS_INVALID:*' }
    Assert $failed
  }
}

Test 'Tunnel connect uses bounded argv and child-only environment key reference' {
 & $module {param($root)
   function script:Get-TunnelRuntimeContext {param($Config,$Tunnel) [pscustomobject]@{intentPath=$script:Intent;profileRoot=$script:Profile}}
   $script:Intent=Join-Path $root 'intent.json';$script:Profile=$root;[IO.File]::WriteAllText($script:Intent,'{}')
   function script:Invoke-TunnelNative {param($Config,$Tunnel,$Arguments,$TimeoutMs,$PlainKey)
     if($TimeoutMs -ne 30000 -or $Arguments -contains $PlainKey -or $Arguments -notcontains 'env:CONTROL_PLANE_API_KEY' -or $PlainKey -cne 'fixture-secret'){throw 'bad bounded contract'}
     [pscustomobject]@{Ok=$true;Stdout='fixture-output';ProcessId=900;CreatedAt='fixture';ExitedAt='fixture'}
   }
 } $root
 $cfg=[pscustomobject]@{tunnelExe='C:\fixture\tunnel-client.exe';mcpUrl='http://127.0.0.1:17690/mcp'};$t=[pscustomobject]@{alias='fixture';tunnelId='fixture-id'}
 $env:CONTROL_PLANE_API_KEY='fixture-ambient'
 try{$v=Connect-TunnelRuntime $cfg $t 'fixture-secret';Assert ($v.Ok -and !$v.Stdout -and $env:CONTROL_PLANE_API_KEY -ceq 'fixture-ambient')}finally{Remove-Item Env:CONTROL_PLANE_API_KEY -ErrorAction SilentlyContinue}
}

Remove-Item -LiteralPath $root -Recurse -Force
Write-Output ("RESULT: {0}/{0} PASS; exact release/readiness/Node environment contract only; no live deployment actions" -f $passed)
