$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$fixtureRoot=Join-Path $PSScriptRoot '.fixtures'
$fixture=Join-Path $fixtureRoot ('install-plan-'+[Guid]::NewGuid().ToString('N'))
$release=Join-Path $fixture 'release'
$project=Join-Path $fixture 'project'
$destination=Join-Path $fixture 'destination'

New-Item -ItemType Directory -Force -Path $project,(Join-Path $release 'config'),(Join-Path $release 'scripts'),(Join-Path $release 'src')|Out-Null

$critical=@(
    @{path='scripts/launch.mjs';content='fixture launch'},
    @{path='src/mcp-http-public.mjs';content='fixture http'},
    @{path='src/codexless-runtime.mjs';content='fixture runtime'},
    @{path='package.json';content='{"name":"codexless"}'}
)
$entries=@()
foreach($f in $critical){
    $p=Join-Path $release $f.path
    New-Item -ItemType Directory -Force -Path (Split-Path $p -Parent)|Out-Null
    [IO.File]::WriteAllText($p,$f.content,[Text.UTF8Encoding]::new($false))
    $entries += [pscustomobject]@{path=$f.path;sha256=(Get-FileHash $p -Algorithm SHA256).Hash.ToLowerInvariant()}
}

$manifestPath=Join-Path (Join-Path $release 'config') 'release-manifest.json'
[ordered]@{
    manifestVersion=1
    productId='codexless'
    version='fixture'
    buildId=('b'*64)
    hostContractVersion='codexless-public-preview-v1'
    files=$entries
}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $manifestPath -Encoding utf8

$node=(Get-Command node.exe -ErrorAction Stop).Source
$raw=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'Install.ps1') -CodexlessRoot $release -ProjectPath $project -NodeExe $node -NoTunnel -InstallDirectory $destination -PlanOnly
if($LASTEXITCODE -ne 0){throw 'plan failed'}

$plan=($raw|Out-String)|ConvertFrom-Json
if($plan.installDirectory -cne [IO.Path]::GetFullPath($destination)){throw 'wrong destination'}
if($plan.codexless.buildId -cne ('b'*64)){throw 'wrong release'}
if($plan.tunnel.enabled -ne $false){throw 'tunnel should be disabled'}
if(Test-Path -LiteralPath $destination){throw 'PlanOnly mutated destination'}

$tunnelExe=Join-Path $fixture 'tunnel-client.exe'
[IO.File]::WriteAllBytes($tunnelExe,[byte[]](1,2,3))
$tunnelDestination=Join-Path $fixture 'destination-with-tunnel'
$tunnelRaw=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'Install.ps1') -CodexlessRoot $release -ProjectPath $project -NodeExe $node -TunnelClientExe $tunnelExe -TunnelId 'tunnel_fixture' -TunnelAlias 'friend' -InstallDirectory $tunnelDestination -PlanOnly
if($LASTEXITCODE -ne 0){throw 'tunnel plan failed'}
$tunnelPlan=($tunnelRaw|Out-String)|ConvertFrom-Json
if($tunnelPlan.tunnel.enabled -ne $true -or $tunnelPlan.tunnel.alias -cne 'friend' -or $tunnelPlan.tunnel.tunnelId -cne 'tunnel_fixture'){throw 'wrong tunnel plan'}
if(Test-Path -LiteralPath $tunnelDestination){throw 'Tunnel PlanOnly mutated destination'}

Remove-Item -LiteralPath $fixture -Recurse -Force
Write-Output 'RESULT: 2/2 PASS; PlanOnly validates tunnel/no-tunnel plans without filesystem/task mutation'
