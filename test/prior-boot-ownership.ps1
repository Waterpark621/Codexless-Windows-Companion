$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\PriorBootOwnership.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\UserSessionTask.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\CompanionRuntime.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\GenerationIdentity.psm1') -Force
$module=Get-Module PriorBootOwnership
$root=Join-Path $PSScriptRoot ('.fixtures\prior-boot-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$passed=0
function Assert([bool]$Value){if(!$Value){throw 'assertion failed'}}
function Test([string]$Name,[scriptblock]$Body){& $Body;$script:passed++;Write-Output "PASS $Name"}
function Save($Name,$Value){$Value | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:def.LauncherDirectory $Name) -Encoding utf8}
function Load($Name){Get-Content -LiteralPath (Join-Path $script:def.LauncherDirectory $Name) -Raw | ConvertFrom-Json}
function New-Fixture {
    $folder=Join-Path $root ([Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $folder 'tunnel-owners') -Force | Out-Null
    $script:def=New-HouseholdTaskDefinition $sid $folder (Join-Path $folder 'Task-Host.ps1') $powershell
    '{}' | Set-Content -LiteralPath (Join-Path $folder 'settings.json')
    $script:fixtureCfg=[pscustomobject]@{companionRoot=$folder;
        settingsPath=(Join-Path $folder 'settings.json')
        projectPath=$folder
        release=[pscustomobject]@{version='fixture';buildId=('b'*64);sourceRevision=('c'*40);manifestSha256=('d'*64);hostContractVersion='codexless-public-preview-v1'}
        port=7690
        codexlessRoot=(Join-Path $folder 'release')
        nodeExe='C:\fixture\node.exe';nodeSha256=('a'*64)
        launchScript=(Join-Path $folder 'release\scripts\launch.mjs')
        tunnelExe='C:\fixture\tunnel-client.exe'
        profileDir='C:\fixture\tunnel-profile'
        tunnels=@([pscustomobject]@{alias='fixture';tunnelId='fixture-registration';enabled=$false;keyPath=(Join-Path $folder 'keys\fixture.dpapi')})
    }
    $script:owner=[pscustomobject]@{version=1;pid=101;createdAt='2026-10-03T00:00:00.123456Z';userSid=$sid;taskName=$def.Name;hostScript=$def.HostScript;launcherDirectory=$folder;generationContract=(Get-CompanionGenerationContract $fixtureCfg)}
    Save 'task-owner.json' $owner
    '101' | Set-Content -LiteralPath (Join-Path $folder 'host.pid')
    $command=Get-CodexlessPrivateConsoleCommand $fixtureCfg
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    Save 'codexless-console-owner.json' ([pscustomobject]@{version=1;pid=102;createdAt='2026-10-03T00:00:01.12345Z';userSid=$sid;executable=$powershell;commandLine=('"'+$powershell+'" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand '+$encoded)})
    '102' | Set-Content -LiteralPath (Join-Path $folder 'codexless.pid')
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$digest=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('fixture-registration')))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    $context=Get-TunnelRuntimeContext $fixtureCfg $fixtureCfg.tunnels[0]
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$namespace=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($context.stateRoot)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    Save 'tunnel-owners\fixture.json' ([pscustomobject]@{version=2;connectPid=104;connectCreatedAt='2026-10-03T00:00:01.123456Z';connectExitedAt='2026-10-03T00:00:03.123456Z';generationSha256=$owner.generationContract.sha256;executableSha256='fcc85a69ec0ad82518e4f8964f60c45e31787957782a0fc9c1b0c44e82d61b9b';namespaceDigest=$namespace;alias='fixture';pid=103;createdAt='2026-10-03T00:00:02.123456Z';nativeCreatedAt='2026-10-03T00:00:02.1234567Z';userSid=$sid;executable='C:\fixture\tunnel-client.exe';registrationDigest=$digest})
    & $module {
        param($folder,$cfg)
        $script:fixtureFolder=$folder
        $script:cfg=$cfg
        $script:boot=[DateTime]::Parse('2026-10-05T04:55:16Z').ToUniversalTime()
        $script:listeners=@();$script:runs=@();$script:processes=@([pscustomobject]@{ProcessId=999;Name='explorer.exe';CommandLine='explorer'})
        $script:status=[pscustomobject]@{alias='fixture';tunnel_id='fixture-registration';process_running=$false}
        $script:probeFailure='';$script:statusCalls=0;$script:bootCalls=0;$script:changeBoot=$false;$script:changeEvidence=$false;$script:denyDelete=$false;$script:lateChange=''
        function script:Get-CompanionConfig { param($CompanionRoot) $script:cfg }
        function script:Get-ConfiguredTunnels { param($Config,[switch]$IncludeDisabled) if(!$IncludeDisabled){throw 'must include disabled'}; $Config.tunnels }
        function script:Get-CimInstance {
            param($ClassName,$OperationTimeoutSec,$ErrorAction)
            if($script:probeFailure -eq 'cim'){throw 'fixture private error'}
            if($ClassName -eq 'Win32_OperatingSystem'){$script:bootCalls++;if($script:changeBoot -and $script:bootCalls -gt 1){return [pscustomobject]@{LastBootUpTime=$script:boot.AddSeconds(1)}};return [pscustomobject]@{LastBootUpTime=$script:boot}}
            $script:processes
        }
        function script:Get-RecoveryListeners { if($script:probeFailure -eq 'listeners'){throw 'fixture private error'}; $script:listeners }
        function script:Get-RecoveryRunValues { if($script:probeFailure -eq 'registry'){throw 'fixture private error'}; $script:runs }
        function script:Get-RecoveryTunnelStatus {
            param($Config,$Tunnel)
            $script:statusCalls++
            if($script:probeFailure -eq 'status'){throw 'fixture private error'}
            if($script:changeEvidence -and $script:statusCalls -eq 1){'999' | Set-Content -LiteralPath (Join-Path $script:fixtureFolder 'host.pid')}
            if($script:statusCalls -eq 2 -and $script:lateChange -eq 'config'){'{"changed":true}' | Set-Content -LiteralPath (Join-Path $script:fixtureFolder 'settings.json')}
            if($script:statusCalls -eq 2 -and $script:lateChange -eq 'marker'){Write-HouseholdCleanupState $script:fixtureFolder 'task-host' 101}
            $script:status
        }
        function script:Remove-Item { param($LiteralPath,$ErrorAction) if($script:denyDelete){throw 'fixture deletion failed'}; Microsoft.PowerShell.Management\Remove-Item -LiteralPath $LiteralPath -ErrorAction Stop }
    } $folder $fixtureCfg
}
function Snapshot {
    $items=@(Get-ChildItem -LiteralPath $def.LauncherDirectory -Recurse -File | Sort-Object FullName | ForEach-Object {$_.FullName+':'+[IO.File]::ReadAllText($_.FullName)})
    $items -join "`n"
}
function Refuses {
    $before=Snapshot
    $caught=$false
    try{Invoke-PriorBootOwnership $def}catch{Assert ($_.Exception.Message -ceq 'HOUSEHOLD_CLEANUP_DEGRADED: Prior-boot recovery proof incomplete; ownership evidence remains fenced.');$caught=$true}
    Assert $caught
    Assert ($before -ceq (Snapshot))
}
Test 'Bound prior-boot generation retires only exact dead receipts; diagnostic is sanitized and bounded' {
    New-Fixture
    'preserved' | Set-Content -LiteralPath (Join-Path $def.LauncherDirectory 'unrelated.txt')
    Invoke-PriorBootOwnership $def
    Assert (!(Test-HouseholdOwnershipEvidence $def.LauncherDirectory))
    Assert ($null -eq (Get-HouseholdCleanupState $def.LauncherDirectory))
    $summary=Load 'prior-boot-recovery.json'
    Assert ($summary.state -ceq 'retired' -and $summary.receiptCount -eq 5)
    Assert ((ConvertTo-Json $summary) -notmatch 'commandLine|wrapper|registration|userSid|key|fixture')
    Assert ((Get-Content -LiteralPath (Join-Path $def.LauncherDirectory 'unrelated.txt')) -ceq 'preserved')
}
Test 'Controller preflight is read-only and rechecks boot and all probes' {New-Fixture;$before=Snapshot;Invoke-PriorBootOwnership $def -CheckOnly;Assert ($before -ceq (Snapshot));Assert (& $module {$script:statusCalls -eq 2 -and $script:bootCalls -eq 2})}
Test 'Owner-only prior-boot receipt is sufficient when no other evidence or components exist' {New-Fixture;foreach($name in @('host.pid','codexless.pid','codexless-console-owner.json','tunnel-owners\fixture.json')){Remove-Item -LiteralPath (Join-Path $def.LauncherDirectory $name)};Invoke-PriorBootOwnership $def;Assert (!(Test-HouseholdOwnershipEvidence $def.LauncherDirectory))}
Test 'Same-boot dead owner fails closed' {New-Fixture;$owner.createdAt='2026-10-05T04:56:00.0000000Z';Save 'task-owner.json' $owner;Refuses}
Test 'Exact boot boundary fails closed' {New-Fixture;$owner.createdAt='2026-10-05T04:55:16.0000000Z';Save 'task-owner.json' $owner;Refuses}
Test 'Live IPv6 or wildcard listener refuses retirement' {New-Fixture;& $module {$script:listeners=@([pscustomobject]@{Port=7690;Address='::'})};Refuses}
Test 'Live configured alias refuses retirement' {New-Fixture;& $module {$script:status.process_running=$true};Refuses}
Test 'Live configured tunnel process refuses despite dead alias status' {New-Fixture;& $module {$script:processes+= [pscustomobject]@{ProcessId=200;Name='tunnel-client.exe';CommandLine='foreign'}};Refuses}
Test 'Contradictory inactive-but-ready alias status refuses' {New-Fixture;& $module {$script:status | Add-Member NoteProperty ready $true};Refuses}
Test 'Inactive alias with a live foreign status PID refuses' {New-Fixture;& $module {$script:status | Add-Member NoteProperty process ([pscustomobject]@{pid=999})};Refuses}
foreach($id in @(101,102,103)) {
    Test "Any live recorded PID $id including valid or reused foreign lifetimes refuses" {New-Fixture;& $module {param($id) $script:processes+= [pscustomobject]@{ProcessId=$id;Name='foreign.exe';CommandLine='foreign'}} $id;Refuses}
}
Test 'Valid old task owner alive refuses' {New-Fixture;& $module {param($owner) $script:processes+= [pscustomobject]@{ProcessId=$owner.pid;Name='powershell.exe';CommandLine=$owner.hostScript;CreationDate=$owner.createdAt;userSid=$owner.userSid}} $owner;Refuses}
Test 'Unrecorded household wrapper refuses' {New-Fixture;& $module {param($d) $script:processes+= [pscustomobject]@{ProcessId=201;Name='powershell.exe';CommandLine=('powershell -File "'+$d.HostScript+'"')}} $def;Refuses}
Test 'Unrecorded encoded wrapper refuses' {New-Fixture;$console=Load 'codexless-console-owner.json';& $module {param($c) $script:processes+= [pscustomobject]@{ProcessId=202;Name='powershell.exe';CommandLine=$c.commandLine}} $console;Refuses}
Test 'Unreadable relevant process refuses' {New-Fixture;& $module {$script:processes+= [pscustomobject]@{ProcessId=203;Name='node.exe';CommandLine=$null}};Refuses}
Test 'Legacy Run owner refuses' {New-Fixture;& $module {$script:runs=@([pscustomobject]@{name='CodexlessLauncher';value='hidden'})};Refuses}
foreach($field in @('userSid','launcherDirectory','hostScript','taskName')) {Test "Wrong owner $field refuses" {New-Fixture;$owner.$field='wrong';Save 'task-owner.json' $owner;Refuses}}
Test 'Malformed JSON refuses' {New-Fixture;'{' | Set-Content -LiteralPath (Join-Path $def.LauncherDirectory 'task-owner.json');Refuses}
Test 'Missing owner generation refuses' {New-Fixture;Remove-Item -LiteralPath (Join-Path $def.LauncherDirectory 'task-owner.json');Refuses}
foreach($time in @('invalid','2026-02-31T00:00:00.0000000Z','2026-10-03T00:00:00','2026-10-03T00:00:00.1234567+07:00')) {Test "Invalid or non-UTC legacy timestamp refuses: $time" {New-Fixture;$owner.createdAt=$time;Save 'task-owner.json' $owner;Refuses}}
Test 'Prior-boot cleanup marker bound to dead owner is safely retired' {New-Fixture;Write-HouseholdCleanupState $def.LauncherDirectory 'console-stop' 101;$marker=Load 'household-cleanup-state.json';$marker.recordedAt='2026-10-04T00:00:00.0000000Z';Save 'household-cleanup-state.json' $marker;Invoke-PriorBootOwnership $def;Assert ($null -eq (Get-HouseholdCleanupState $def.LauncherDirectory))}
Test 'Current-boot cleanup marker refuses' {New-Fixture;Write-HouseholdCleanupState $def.LauncherDirectory 'console-stop' 101;Refuses}
Test 'Prior marker with wrong owner refuses' {New-Fixture;Write-HouseholdCleanupState $def.LauncherDirectory 'console-stop' 999;$marker=Load 'household-cleanup-state.json';$marker.recordedAt='2026-10-04T00:00:00.0000000Z';Save 'household-cleanup-state.json' $marker;Refuses}
foreach($change in @('version','userSid','commandLine','createdAt')) {Test "Inconsistent console $change refuses" {New-Fixture;$c=Load 'codexless-console-owner.json';$c.$change=if($change -eq 'version'){0}else{'wrong'};Save 'codexless-console-owner.json' $c;Refuses}}
Test 'Current-boot component in prior owner generation refuses' {New-Fixture;$c=Load 'codexless-console-owner.json';$c.createdAt='2026-10-05T05:00:00.0000000Z';Save 'codexless-console-owner.json' $c;Refuses}
Test 'Component predating owner refuses' {New-Fixture;$c=Load 'codexless-console-owner.json';$c.createdAt='2026-10-02T00:00:00.0000000Z';Save 'codexless-console-owner.json' $c;Refuses}
Test 'Mismatched wrapper PID refuses' {New-Fixture;'999' | Set-Content -LiteralPath (Join-Path $def.LauncherDirectory 'codexless.pid');Refuses}
foreach($field in @('registrationDigest','alias','nativeCreatedAt','userSid','executable')) {Test "Invalid tunnel $field refuses" {New-Fixture;$t=Load 'tunnel-owners\fixture.json';$t.$field='wrong';Save 'tunnel-owners\fixture.json' $t;Refuses}}
Test 'Unknown tunnel receipt refuses' {New-Fixture;Save 'tunnel-owners\unknown.json' @{version=1};Refuses}
Test 'Unknown nested evidence refuses' {New-Fixture;New-Item -ItemType Directory -Path (Join-Path $def.LauncherDirectory 'tunnel-owners\unknown') | Out-Null;Refuses}
foreach($probe in @('cim','listeners','status','registry')) {Test "Unavailable $probe proof refuses without mutation" {New-Fixture;& $module {param($p)$script:probeFailure=$p} $probe;Refuses}}
Test 'Missing or malformed alias status refuses' {foreach($value in @($null,[pscustomobject]@{process_running='false'},[pscustomobject]@{process_running=$false;alias='fixture';tunnel_id='wrong'})){New-Fixture;& $module {param($s)$script:status=$s} $value;Refuses}}
Test 'Unknown boot kind refuses' {New-Fixture;& $module {$script:boot=[DateTime]::SpecifyKind($script:boot,[DateTimeKind]::Unspecified)};Refuses}
Test 'Boot identity change during proof refuses' {New-Fixture;& $module {$script:changeBoot=$true};Refuses}
Test 'Evidence change during proof refuses' {New-Fixture;& $module {$script:changeEvidence=$true};$caught=$false;try{Invoke-PriorBootOwnership $def}catch{$caught=$true};Assert $caught;Assert (Test-Path -LiteralPath (Join-Path $def.LauncherDirectory 'task-owner.json'));Assert (!(Test-Path -LiteralPath (Join-Path $def.LauncherDirectory 'prior-boot-recovery.json')))}
foreach($late in @('config','marker')) {Test "Late $late change refuses before retirement" {New-Fixture;& $module {param($v)$script:lateChange=$v} $late;$caught=$false;try{Invoke-PriorBootOwnership $def}catch{$caught=$true};Assert $caught;Assert (Test-Path -LiteralPath (Join-Path $def.LauncherDirectory 'task-owner.json'));Assert (!(Test-Path -LiteralPath (Join-Path $def.LauncherDirectory 'prior-boot-recovery.json')))}}
Test 'Retirement failure leaves a current-boot fence and cannot retry automatically' {New-Fixture;& $module {$script:denyDelete=$true};$caught=$false;try{Invoke-PriorBootOwnership $def}catch{$caught=$true};Assert $caught;Assert ($null -ne (Get-HouseholdCleanupState $def.LauncherDirectory));& $module {$script:denyDelete=$false};Refuses}
function Invoke-TaskHostFixture([bool]$InvalidAncestry=$false,[bool]$Duplicate=$false) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\Task-Host.ps1') -Destination $def.HostScript
    @'
param($LauncherDirectory)
$saved=Get-Content -LiteralPath (Join-Path $LauncherDirectory 'task-owner.json') -Raw | ConvertFrom-Json
if($saved.version -ne 1 -or $saved.pid -ne $PID){throw 'new receipt invalid'}
$PID | Set-Content -LiteralPath (Join-Path $LauncherDirectory 'host.pid')
'1' | Set-Content -LiteralPath (Join-Path $LauncherDirectory 'fixture-host-ran')
New-Item -ItemType File -Path (Join-Path $LauncherDirectory 'stop.flag') -Force | Out-Null
'@ | Set-Content -LiteralPath (Join-Path $def.LauncherDirectory 'Household-Host.ps1')
    $script:hostMock=[pscustomobject]@{recoveries=0;gateHeld=$false}
    function Import-Module {}
    function Enter-CompanionHostLease {
        param($Definition,$Phase)
        $lease=[pscustomobject]@{}
        $lease|Add-Member ScriptMethod Dispose {}
        $lease
    }
    function Get-CompanionConfig {param($CompanionRoot) $fixtureCfg}
    function Get-ProcessIdentity {param($ProcessId) [pscustomobject]@{pid=$ProcessId;parentPid=999;createdAt='2026-10-05T05:00:00.0000000Z';userSid=$sid}}
    function Get-TaskSchedulerParentIdentity {param($ProcessId) [pscustomobject]@{pid=$ProcessId;executable=(Join-Path $env:SystemRoot 'System32\taskhostw.exe');createdAt='2026-10-05T04:55:20.0000000Z'}}
    function Get-AuthenticodeSignature { [pscustomobject]@{Status=$(if($InvalidAncestry){'Invalid'}else{'Valid'});SignerCertificate=[pscustomobject]@{Subject='O=Microsoft Corporation, CN=fixture'}} }
    function Get-CimInstance { [pscustomobject]@{Name='Schedule';State='Running';ProcessId=999} }
    function New-Object {
        param($TypeName,$ArgumentList)
        if($TypeName -cne 'Threading.Mutex'){return Microsoft.PowerShell.Utility\New-Object -TypeName $TypeName -ArgumentList $ArgumentList}
        $ArgumentList[2].Value=!$Duplicate
        $hostMock.gateHeld=!$Duplicate
        $gate=[pscustomobject]@{}
        $gate | Add-Member ScriptMethod ReleaseMutex {$hostMock.gateHeld=$false}
        $gate | Add-Member ScriptMethod Dispose {}
        $gate
    }
    function Get-HouseholdRuntimeState {param($Definition) [pscustomobject]@{taskState='Running';cleanupRequired=(Test-HouseholdOwnershipEvidence $Definition.LauncherDirectory);hostPresent=$false;listenerPresent=$false;tunnelPresent=$false}}
    function Export-ScheduledTask {$def.Xml}
    function Invoke-WindowsPriorBootRecovery {param($Definition) Assert $hostMock.gateHeld;$hostMock.recoveries++;Invoke-PriorBootOwnership $Definition}
    & $def.HostScript -LauncherDirectory $def.LauncherDirectory -UserSid $sid 2>$null
}
Test 'Actual task-owner script reconciles under gate, establishes unchanged v1 receipt, and completes normal stop' {
    New-Fixture
    Invoke-TaskHostFixture
    Assert ($hostMock.recoveries -eq 1 -and !$hostMock.gateHeld)
    Assert (Test-Path -LiteralPath (Join-Path $def.LauncherDirectory 'fixture-host-ran'))
    Assert (!(Test-HouseholdOwnershipEvidence $def.LauncherDirectory))
}
Test 'Actual task-owner script still refuses same-boot evidence before host launch' {
    New-Fixture;$owner.createdAt='2026-10-05T05:00:00.0000000Z';Save 'task-owner.json' $owner
    Invoke-TaskHostFixture
    Assert ($hostMock.recoveries -eq 1 -and !$hostMock.gateHeld)
    Assert (!(Test-Path -LiteralPath (Join-Path $def.LauncherDirectory 'fixture-host-ran')))
    Assert (Test-HouseholdOwnershipEvidence $def.LauncherDirectory)
}
Test 'Scheduler ancestry failure cannot reach reconciliation' {
    New-Fixture;$caught=$false
    try{Invoke-TaskHostFixture -InvalidAncestry $true}catch{$caught=$true}
    Assert ($caught -and $hostMock.recoveries -eq 0)
    Assert (Test-HouseholdOwnershipEvidence $def.LauncherDirectory)
}
Test 'Duplicate owner gate cannot reach reconciliation or host launch' {
    New-Fixture;Invoke-TaskHostFixture -Duplicate $true
    Assert ($hostMock.recoveries -eq 0)
    Assert (!(Test-Path -LiteralPath (Join-Path $def.LauncherDirectory 'fixture-host-ran')))
}
foreach($field in @('buildId','sourceRevision','version','manifestSha256','hostContractVersion')) {
    Test "Changed generation release $field refuses without mutation" {New-Fixture;$fixtureCfg.release.$field=if($field -eq 'sourceRevision'){'e'*40}elseif($field -in @('buildId','manifestSha256')){'e'*64}else{'changed'};Refuses}
}
foreach($field in @('projectPath','codexlessRoot','nodeExe','port','profileDir')) {
    Test "Changed generation setting $field refuses without mutation" {New-Fixture;$fixtureCfg.$field=if($field -eq 'port'){7691}else{'C:\fixture\changed'};Refuses}
}
foreach($field in @('tunnelId','alias','enabled','keyPath')) {
    Test "Changed generation tunnel $field refuses without mutation" {New-Fixture;$fixtureCfg.tunnels[0].$field=if($field -eq 'enabled'){$true}else{'changed'};Refuses}
}
Test 'Changed settings bytes refuse even if parsed observations are unchanged' {New-Fixture;'{"changed":true}'|Set-Content -LiteralPath $fixtureCfg.settingsPath;Refuses}
Test 'Missing generation contract refuses legacy authority without mutation' {New-Fixture;$owner.PSObject.Properties.Remove('generationContract');Save 'task-owner.json' $owner;Refuses}
foreach($value in @($null,[pscustomobject]@{version=0;sha256=('e'*64)},[pscustomobject]@{version=1;sha256='invalid'},[pscustomobject]@{version=1;sha256=('e'*64);path='private'})) {
    Test 'Malformed generation contract fails closed with sanitized diagnostics' {New-Fixture;$owner.generationContract=$value;Save 'task-owner.json' $owner;Refuses}
}
Test 'Generation contract contains only version and digest and repeats deterministically' {New-Fixture;$a=Get-CompanionGenerationContract $fixtureCfg;$b=Get-CompanionGenerationContract $fixtureCfg;Assert ($a.sha256 -ceq $b.sha256);Assert (@($a.PSObject.Properties).Count -eq 2);Assert (($a|ConvertTo-Json)-notmatch 'fixture|userSid|project|command|tunnel|path')}
Test 'Recovery source has no force kill, stop, connect, adoption, or Scheduler mutation' {
    $source=Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\PriorBootOwnership.psm1') -Raw
    Assert ($source -notmatch '(?i)Stop-Process|taskkill|\.Kill\(|Stop-ScheduledTask|Register-ScheduledTask|runtimes (connect|stop)')
}
foreach($field in @('generationSha256','executableSha256','namespaceDigest')){Test "Prior-boot tunnel $field mismatch remains fenced" {New-Fixture;$v=Load 'tunnel-owners\fixture.json';$v.$field='0'*64;Save 'tunnel-owners\fixture.json' $v;Refuses}}
Test 'Missing prior-boot tunnel connect interval remains fenced' {New-Fixture;$v=Load 'tunnel-owners\fixture.json';$v.PSObject.Properties.Remove('connectExitedAt');Save 'tunnel-owners\fixture.json' $v;Refuses}
Write-Output ("RESULT: {0}/{0} PASS; fixture receipt I/O only; native observations mocked; no live deployment/task/tunnel actions" -f $passed)
