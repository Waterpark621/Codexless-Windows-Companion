$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\WindowsTaskAdapter.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\UserSessionTask.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\GenerationIdentity.psm1') -Force
$module=Get-Module WindowsTaskAdapter
$fixture=Join-Path $PSScriptRoot ('.fixtures\runtime-state-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null

$definition=New-HouseholdTaskDefinition 'S-1-5-21-111-222-333-1001' $fixture (Join-Path $fixture 'Task-Host.ps1') 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
'{}' | Set-Content -LiteralPath (Join-Path $fixture 'settings.json')
$cfg=[pscustomobject]@{settingsPath=(Join-Path $fixture 'settings.json');projectPath=$fixture;codexlessRoot=(Join-Path $fixture 'release');nodeExe='C:\fixture\node.exe';launchScript=(Join-Path $fixture 'release\scripts\launch.mjs');profileDir=$fixture;port=7690;tunnelExe='C:\fixture\tunnel-client.exe';tunnels=@([pscustomobject]@{alias='fixture';tunnelId='fixture-exact-tunnel';enabled=$true;keyPath=(Join-Path $fixture 'keys\fixture.dpapi')});release=[pscustomobject]@{version='fixture';buildId=('b'*64);sourceRevision=('c'*40);manifestSha256=('d'*64);hostContractVersion='codexless-public-preview-v1'}}
$receipt=[pscustomobject]@{version=1;pid=101;createdAt='2026-10-03T00:00:00.0000000Z';userSid=$definition.UserSid;taskName=$definition.Name;hostScript=$definition.HostScript;launcherDirectory=$definition.LauncherDirectory;generationContract=(Get-CompanionGenerationContract $cfg)}
$receipt | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $fixture 'task-owner.json')
'101' | Set-Content -LiteralPath (Join-Path $fixture 'host.pid')
'102' | Set-Content -LiteralPath (Join-Path $fixture 'codexless.pid')
$consoleReceipt=[pscustomobject]@{version=1;pid=102;createdAt='2026-10-03T00:00:01.0000000Z';userSid=$definition.UserSid;executable=$definition.PowerShellExe;commandLine='fixture wrapper'}
$consoleReceiptPath=Join-Path $fixture 'codexless-console-owner.json'
$consoleReceipt | ConvertTo-Json | Set-Content -LiteralPath $consoleReceiptPath
& $module {
    param($definition,$receipt,$cfg)
    $script:FixtureConfig=$cfg
    $script:FixtureListener=$true
    $script:TunnelReceiptValid=$true;$script:FixtureTunnel=[pscustomobject]@{healthy=$true;process=[pscustomobject]@{pid=103};runtime_state='running';process_running=$true;ready=$true;tunnel_id='fixture-exact-tunnel'}
    $script:FixtureTask=[pscustomobject]@{State='Running'}
    $script:FixtureProcesses=@{
        101=[pscustomobject]@{pid=101;parentPid=1;userSid=$definition.UserSid;executable=$definition.PowerShellExe;commandLine=('powershell -File "'+$definition.HostScript+'"');createdAt=$receipt.createdAt}
        102=[pscustomobject]@{pid=102;parentPid=101;userSid=$definition.UserSid;executable=$definition.PowerShellExe;commandLine='fixture wrapper';createdAt='2026-10-03T00:00:01.0000000Z'}
        103=[pscustomobject]@{pid=103;parentPid=102;userSid=$definition.UserSid;executable=$script:FixtureConfig.tunnelExe;commandLine='fixture tunnel';createdAt='2026-10-03T00:00:02.0000000Z'}
    }
    function script:Get-CompanionConfig { param($CompanionRoot) $script:FixtureConfig }
    function script:Test-TcpPort { param([int]$Port) $script:FixtureListener }
    function script:Get-ConfiguredTunnels { param($Config,[switch]$IncludeDisabled) @($Config.tunnels) }
    function script:Test-OwnedTunnel {param($launcher,$Config,$Tunnel,$Status) $script:TunnelReceiptValid}
    function script:Get-TunnelStatus { param($Config,$Tunnel) $script:FixtureTunnel }
    function script:Get-ScheduledTask { param($TaskName,$TaskPath,$ErrorAction) if($TaskPath -cne '\'){throw 'Task scope must be root'}; $script:FixtureTask }
    function script:Get-ProcessIdentity { param([int]$ProcessId) $script:FixtureProcesses[$ProcessId] }
} $definition $receipt $cfg
$passed=0
function Assert-State([string]$Name,[bool]$Expected) {
    $state=Get-HouseholdRuntimeState $definition
    if ($state.piecesVerified -ne $Expected) { throw "FAIL $Name" }
    $script:passed++;Write-Output "PASS $Name"
}
& $module {$script:TunnelReceiptValid=$false}
Assert-State 'Unreceipted ready tunnel never grants adapter stop authority' $false
& $module {$script:TunnelReceiptValid=$true}
Assert-State 'Owned household and exact tunnel fixture passes actual adapter' $true
& $module {$script:FixtureConfig.projectPath='C:\fixture\changed'}
Assert-State 'Changed live generation does not authorize stop through adapter' $false
& $module {param($p) $script:FixtureConfig.projectPath=$p} $fixture
Assert-State 'Exact saved generation restores adapter authority' $true
Remove-Item -LiteralPath $consoleReceiptPath
Assert-State 'Missing private-console receipt fails actual adapter' $false
$consoleReceipt.createdAt='2026-10-02T00:00:01.0000000Z'
$consoleReceipt | ConvertTo-Json | Set-Content -LiteralPath $consoleReceiptPath
Assert-State 'Reused console PID creation time fails actual adapter' $false
$consoleReceipt.createdAt='2026-10-03T00:00:01.0000000Z'
$consoleReceipt | ConvertTo-Json | Set-Content -LiteralPath $consoleReceiptPath
& $module {$script:FixtureProcesses[102].parentPid=999}
Assert-State 'Unrelated/reused wrapper PID fails actual adapter' $false
& $module {$script:FixtureProcesses[102].parentPid=101;$script:FixtureProcesses[103].userSid='S-1-5-21-111-222-333-1002'}
Assert-State 'Foreign tunnel user fails actual adapter' $false
& $module {$script:FixtureProcesses[103].userSid=$script:FixtureProcesses[101].userSid;$script:FixtureTunnel.tunnel_id='wrong-tunnel'}
Assert-State 'Mismatched tunnel registration fails actual adapter' $false
& $module {$script:FixtureTunnel.tunnel_id='fixture-exact-tunnel';$script:FixtureProcesses[103].createdAt='2026-10-02T00:00:00.0000000Z'}
Assert-State 'Tunnel predating owner fails actual adapter' $false
& $module {$script:FixtureProcesses[103].createdAt='2026-10-03T00:00:02.0000000Z';$script:FixtureProcesses[101].createdAt='2026-10-03T01:00:00.0000000Z'}
Assert-State 'Reused host PID creation date fails actual adapter' $false
& $module {$script:FixtureProcesses[101].createdAt='2026-10-03T00:00:00.0000000Z'}
& $module {$script:FixtureTunnel.process=[pscustomobject]@{}}
Assert-State 'Missing nested official process PID fails closed' $false
& $module {$script:FixtureTunnel.process=$null}
Assert-State 'Missing official process object fails closed' $false
foreach ($invalidPid in @('bad',0,-1,'2147483648')) {
    & $module {param($value) $script:FixtureTunnel.process=[pscustomobject]@{pid=$value}} $invalidPid
    Assert-State ('Invalid nested process PID fails closed: '+$invalidPid) $false
}
& $module {$script:FixtureTunnel.process=[pscustomobject]@{pid=103}}
Assert-State 'Supported nested process PID validates ownership without a top-level PID' $true
$cleanupPath=Join-Path $fixture 'household-cleanup-state.json'
Write-HouseholdCleanupState $fixture 'console-stop' 101
Assert-State 'Degraded marker blocks piece ownership even with a verified live owner' $false
$state=Get-HouseholdRuntimeState $definition
if (!$state.cleanupRequired -or $state.cleanupState.stage -cne 'console-stop') { throw 'Cleanup marker must be surfaced' }
Remove-Item -LiteralPath $cleanupPath
Remove-Item -LiteralPath (Join-Path $fixture 'host.pid')
& $module {$script:FixtureListener=$false;$script:FixtureTunnel.process_running=$false}
$state=Get-HouseholdRuntimeState $definition
if ($state.cleanupRequired) { throw 'Running task cleanup transition must not be marked as degraded merely between receipt removals' }
$passed++;Write-Output 'PASS Running task tolerates successful between-receipt cleanup transition'
& $module {$script:FixtureTask.State='Ready'}
$state=Get-HouseholdRuntimeState $definition
if (!$state.cleanupRequired -or $null -ne $state.cleanupState) { throw 'Exited owner receipts must fence recovery even without a writable marker' }
$passed++;Write-Output 'PASS Stopped task with retained receipts requires recovery without a marker'
'' | Set-Content -LiteralPath $cleanupPath
$state=Get-HouseholdRuntimeState $definition
if (!$state.cleanupRequired -or $state.cleanupState.reasonCode -cne 'HOUSEHOLD_CLEANUP_STATE_INVALID') { throw 'Empty marker must fail closed' }
$passed++;Write-Output 'PASS Empty marker remains a recovery fence with sanitized status'
Write-Output ("RESULT: {0}/{0} PASS; no native task/process/network APIs called" -f $passed)
