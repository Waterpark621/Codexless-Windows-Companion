$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$fixtureRoot=Join-Path $PSScriptRoot '.fixtures'
$fixture=Join-Path $fixtureRoot ('install-plan-'+[Guid]::NewGuid().ToString('N'))
$release=Join-Path $fixture 'release'
$project=Join-Path $fixture 'project'
$destination=Join-Path $fixture 'destination'
New-Item -ItemType Directory -Force -Path $release,$project|Out-Null

$node=(Get-Command node.exe -ErrorAction Stop).Source
$fixtureScript=Join-Path $fixture 'Install.fixture.ps1'
$source=Get-Content -LiteralPath (Join-Path $repo 'Install.ps1') -Raw
$target=@'
Import-Module (Join-Path $PSScriptRoot 'CompanionRuntime.psm1') -Force
$release=Get-CodexlessReleaseIdentity $codexlessRoot
'@
$replacement=@'
$release=[pscustomobject]@{
    version='fixture'
    buildId=('b'*64)
    sourceRevision=('c'*40)
    manifestSha256=('d'*64)
    hostContractVersion='codexless-public-preview-v1'
    root=$codexlessRoot
}
'@
if(([regex]::Matches($source,[regex]::Escape($target))).Count -ne 1){throw 'installer fixture injection target drifted'}
$source=$source.Replace($target,$replacement)
[IO.File]::WriteAllText($fixtureScript,$source,[Text.UTF8Encoding]::new($false))

$raw=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fixtureScript -CodexlessRoot $release -ProjectPath $project -NodeExe $node -NoTunnel -InstallDirectory $destination -PlanOnly
if($LASTEXITCODE -ne 0){throw 'plan failed'}
$plan=($raw|Out-String)|ConvertFrom-Json
if($plan.installDirectory -cne [IO.Path]::GetFullPath($destination)){throw 'wrong destination'}
if($plan.codexless.buildId -cne ('b'*64)){throw 'wrong release build'}
if($plan.codexless.sourceRevision -cne ('c'*40)){throw 'wrong release source'}
if($plan.codexless.manifestSha256 -cne ('d'*64)){throw 'wrong release manifest'}
if(@($plan.blockers) -contains 'qualified release/build trust binding'){throw 'qualified release blocker should be removed'}
if(@($plan.blockers) -notcontains 'generation-bound prior-boot release identity'){throw 'generation binding blocker missing'}
if($plan.tunnel.enabled -ne $false){throw 'tunnel should be disabled'}
if(Test-Path -LiteralPath $destination){throw 'PlanOnly mutated destination'}

$tunnelExe=Join-Path $fixture 'tunnel-client.exe'
[IO.File]::WriteAllBytes($tunnelExe,[byte[]](1,2,3))
$tunnelDestination=Join-Path $fixture 'destination-with-tunnel'
$tunnelRaw=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fixtureScript -CodexlessRoot $release -ProjectPath $project -NodeExe $node -TunnelClientExe $tunnelExe -TunnelId 'tunnel_fixture' -TunnelAlias 'friend' -InstallDirectory $tunnelDestination -PlanOnly
if($LASTEXITCODE -ne 0){throw 'tunnel plan failed'}
$tunnelPlan=($tunnelRaw|Out-String)|ConvertFrom-Json
if($tunnelPlan.tunnel.enabled -ne $true -or $tunnelPlan.tunnel.alias -cne 'friend' -or $tunnelPlan.tunnel.tunnelId -cne 'tunnel_fixture'){throw 'wrong tunnel plan'}
if(Test-Path -LiteralPath $tunnelDestination){throw 'Tunnel PlanOnly mutated destination'}

$blockedDestination=Join-Path $fixture 'blocked-destination'
$previousErrorAction=$ErrorActionPreference
$ErrorActionPreference='Continue'
try {
    $blockedOutput=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fixtureScript -CodexlessRoot $release -ProjectPath $project -NodeExe $node -NoTunnel -InstallDirectory $blockedDestination 2>&1
    $blockedExit=$LASTEXITCODE
} finally {
    $ErrorActionPreference=$previousErrorAction
}
if($blockedExit -eq 0){throw 'mutating preview install unexpectedly succeeded'}
if(($blockedOutput|Out-String) -notmatch 'INSTALL_DISABLED_PUBLIC_PREVIEW'){throw 'missing preview refusal code'}
if(Test-Path -LiteralPath $blockedDestination){throw 'refused preview install mutated destination'}

$unqualified=Join-Path $fixture 'unqualified'
New-Item -ItemType Directory -Force -Path (Join-Path $unqualified 'config')|Out-Null
'{}'|Set-Content -LiteralPath (Join-Path $unqualified 'config\release-manifest.json') -Encoding ascii
$unqualifiedDestination=Join-Path $fixture 'unqualified-destination'
$previousErrorAction=$ErrorActionPreference
$ErrorActionPreference='Continue'
try {
    $unqualifiedOutput=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'Install.ps1') -CodexlessRoot $unqualified -ProjectPath $project -NodeExe $node -NoTunnel -InstallDirectory $unqualifiedDestination -PlanOnly 2>&1
    $unqualifiedExit=$LASTEXITCODE
} finally {
    $ErrorActionPreference=$previousErrorAction
}
if($unqualifiedExit -eq 0){throw 'real installer accepted unqualified release'}
if(($unqualifiedOutput|Out-String) -notmatch 'CODEXLESS_RELEASE_INVALID'){throw 'real installer did not report release rejection'}
if(Test-Path -LiteralPath $unqualifiedDestination){throw 'unqualified release validation mutated destination'}

Remove-Item -LiteralPath $fixture -Recurse -Force
Write-Output 'RESULT: 4/4 PASS; planner fixtures only plus real unqualified-release refusal; no live mutation'
