$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\CompanionRuntime.psm1') -Force
$root=Join-Path $PSScriptRoot ('.fixtures\companion-runtime-'+[Guid]::NewGuid().ToString('N'))
$companion=Join-Path $root 'companion'
$codexless=Join-Path $root 'codexless'
$project=Join-Path $root 'project'
New-Item -ItemType Directory -Force -Path $companion,$project,(Join-Path $codexless 'config'),(Join-Path $codexless 'scripts'),(Join-Path $codexless 'src')|Out-Null
$critical=@(
  @{path='scripts/launch.mjs';content='export const fixture = true;'},
  @{path='src/mcp-http-public.mjs';content='export const fixture = true;'},
  @{path='src/codexless-runtime.mjs';content='export const fixture = true;'},
  @{path='package.json';content='{"name":"codexless","version":"0.1.2-preview.0"}'}
)
$entries=@()
foreach($f in $critical){
  $path=Join-Path $codexless ($f.path.Replace('/','\'))
  $parent=Split-Path $path -Parent
  New-Item -ItemType Directory -Force -Path $parent|Out-Null
  [IO.File]::WriteAllText($path,$f.content,[Text.UTF8Encoding]::new($false))
  $entries += [pscustomobject]@{path=$f.path;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
}
$manifest=[ordered]@{manifestVersion=1;productId='codexless';version='0.1.2-preview.0';buildId=('a'*64);hostContractVersion='codexless-public-preview-v1';files=$entries}
$manifest|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $codexless 'config\release-manifest.json') -Encoding utf8
$node=(Get-Command node.exe -ErrorAction Stop).Source
$settings=[ordered]@{schemaVersion=1;project=[ordered]@{path=$project};codexless=[ordered]@{root=$codexless;nodeExe=$node;port=17690};tunnel=[ordered]@{enabled=$false}}
$settings|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $companion 'settings.json') -Encoding utf8
$passed=0
function Assert([bool]$value){if(!$value){throw 'assertion failed'}}
function Test([string]$name,[scriptblock]$body){& $body;$script:passed++;Write-Output "PASS $name"}
Test 'Portable settings resolve project, node and Codexless release dynamically' {
  $cfg=Get-CompanionConfig $companion
  Assert ($cfg.projectPath -ceq [IO.Path]::GetFullPath($project))
  Assert ($cfg.codexlessRoot -ceq [IO.Path]::GetFullPath($codexless))
  Assert ($cfg.release.hostContractVersion -ceq 'codexless-public-preview-v1')
  Assert (@($cfg.tunnels).Count -eq 0)
}
Test 'Launch command is release-derived and contains no certified machine wrapper' {
  $cfg=Get-CompanionConfig $companion
  $command=Get-CodexlessPrivateConsoleCommand $cfg
  Assert ($command.Contains($cfg.nodeExe))
  Assert ($command.Contains($cfg.launchScript))
  Assert ($command.Contains("CODEX_TOOLBOX_PUBLIC_PORT='17690'"))
  Assert ($command -notmatch 'Core\.ps1|Host\.ps1|verified-codex-runtime|Start-VerifiedHousehold')
}
Test 'Changed critical release file fails closed' {
  $path=Join-Path $codexless 'scripts\launch.mjs'
  $before=[IO.File]::ReadAllText($path)
  try {
    [IO.File]::AppendAllText($path,'changed')
    $failed=$false
    try { Get-CompanionConfig $companion|Out-Null } catch { $failed=$_.Exception.Message -like 'CODEXLESS_RELEASE_INVALID:*' }
    Assert $failed
  } finally { [IO.File]::WriteAllText($path,$before,[Text.UTF8Encoding]::new($false)) }
}
Test 'Unknown host contract fails closed' {
  $path=Join-Path $codexless 'config\release-manifest.json'
  $saved=Get-Content -LiteralPath $path -Raw
  try {
    $m=$saved|ConvertFrom-Json;$m.hostContractVersion='unknown-contract';$m|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $path -Encoding utf8
    $failed=$false
    try { Get-CompanionConfig $companion|Out-Null } catch { $failed=$_.Exception.Message -like 'CODEXLESS_RELEASE_INVALID:*' }
    Assert $failed
  } finally { [IO.File]::WriteAllText($path,$saved,[Text.UTF8Encoding]::new($false)) }
}
Test 'Tunnel key path cannot escape Companion root' {
  $profile=Join-Path $root 'tunnel-profile';New-Item -ItemType Directory -Force -Path $profile|Out-Null
  $exe=Join-Path $root 'tunnel-client.exe';[IO.File]::WriteAllBytes($exe,[byte[]](1,2,3))
  $bad=[ordered]@{schemaVersion=1;project=[ordered]@{path=$project};codexless=[ordered]@{root=$codexless;nodeExe=$node;port=17690};tunnel=[ordered]@{enabled=$true;executable=$exe;profileDir=$profile;alias='fixture';tunnelId='fixture-id';keyFile='..\outside.dpapi'}}
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
  $good=[ordered]@{schemaVersion=1;project=[ordered]@{path=$project};codexless=[ordered]@{root=$codexless;nodeExe=$node;port=17690};tunnel=[ordered]@{enabled=$true;executable=$exe;profileDir='tunnel-profile';alias='fixture';tunnelId='fixture-id';keyFile='keys/runtime-key.dpapi'}}
  $good|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $companion 'settings.json') -Encoding utf8
  $cfg=Get-CompanionConfig $companion
  Assert ($cfg.profileDir -ceq [IO.Path]::GetFullPath($profile))
  Assert ($cfg.tunnels[0].keyPath -ceq [IO.Path]::GetFullPath((Join-Path $keys 'runtime-key.dpapi')))
  $plain=Get-PlainRuntimeKey $cfg.tunnels[0]
  try { Assert ($plain -ceq 'fixture-runtime-key') } finally { $plain=$null }
}
Test 'Root-relative drive-relative and UNC paths are rejected' {
  $module=Get-Module CompanionRuntime
  foreach($badPath in @('\Windows','C:Windows','\\server\share')) {
    $failed=$false
    try { & $module { param($p) Resolve-CompanionLocalPath $p 'fixture' } $badPath | Out-Null } catch { $failed=$_.Exception.Message -like 'COMPANION_SETTINGS_INVALID:*' }
    Assert $failed
  }
}
Test 'Tunnel connect suppresses client output and restores ambient runtime-key environment' {
  $cmd=Join-Path $root 'fake-tunnel.cmd'
  Set-Content -LiteralPath $cmd -Value '@echo should-not-be-returned& exit /b 0' -Encoding ascii
  $connectCfg=[pscustomobject]@{tunnelExe=$cmd;profileDir=$root;mcpUrl='http://127.0.0.1:17690/mcp'}
  $connectTunnel=[pscustomobject]@{alias='fixture';tunnelId='fixture-id'}
  $env:CONTROL_PLANE_API_KEY='pre-existing-value'
  try {
    $result=Connect-TunnelRuntime $connectCfg $connectTunnel 'fixture-secret'
    Assert ($result -eq $true)
    Assert ($env:CONTROL_PLANE_API_KEY -ceq 'pre-existing-value')
  } finally { Remove-Item Env:CONTROL_PLANE_API_KEY -ErrorAction SilentlyContinue }
  $result=Connect-TunnelRuntime $connectCfg $connectTunnel 'fixture-secret'
  Assert ($result -eq $true)
  Assert (!(Test-Path Env:CONTROL_PLANE_API_KEY))
}
Remove-Item -LiteralPath $root -Recurse -Force
Write-Output ("RESULT: {0}/{0} PASS; portable config/release contract only; no live deployment actions" -f $passed)
