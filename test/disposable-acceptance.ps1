[CmdletBinding()]
param(
    [string]$ReportPath,
    [Parameter(Mandatory=$true)][string]$LocalCandidateRoot,
    [Parameter(Mandatory=$true)][string]$QualifiedTunnelExe,
    [string]$QualifiedNodeExe
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')
Import-Module (Join-Path $repo 'InstallTransaction.psm1') -Force
Import-Module (Join-Path $repo 'UserSessionTask.psm1') -Force
Import-Module (Join-Path $repo 'CompanionRuntime.psm1') -Force

$runId=[Guid]::NewGuid().ToString('N')
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('CodexlessDisposableAcceptance-'+$runId)
$projectRoot=Join-Path $fixtureRoot 'project'
$stateRoot=Join-Path $fixtureRoot 'state'
$profileRoot=Join-Path $fixtureRoot 'profile'
$keyRoot=Join-Path $fixtureRoot 'keys'
$taskName='Codexless-Acceptance-'+$runId
$results=[Collections.Generic.List[object]]::new()
$schedulerTaskRegistered=$false
$schedulerTaskName=$null

function Add-Result {
    param([string]$Name,[ValidateSet('PASS','FAIL','SKIP_EXTERNAL','BLOCKED_UNPUBLISHED_ARTIFACT')][string]$Status,[string]$Code,[string]$Category)
    $results.Add([pscustomobject]@{name=$Name;status=$Status;code=$Code;category=$Category}) | Out-Null
    Write-Output ("{0} {1} [{2}]" -f $Status,$Name,$Code)
}
function Assert-True([bool]$Value){if(!$Value){throw 'ACCEPTANCE_ASSERTION_FAILED'}}
function Assert-Throws {
    param([scriptblock]$Body,[string]$Prefix)
    $caught=$false
    try { & $Body | Out-Null } catch { $caught=$_.Exception.Message.StartsWith($Prefix,[StringComparison]::Ordinal) }
    if(!$caught){throw 'ACCEPTANCE_EXPECTED_REFUSAL_MISSING'}
}
function Invoke-Case {
    param([string]$Name,[string]$Category,[scriptblock]$Body,[string]$PassCode='VERIFIED')
    try { & $Body; Add-Result $Name PASS $PassCode $Category }
    catch { Add-Result $Name FAIL 'ASSERTION_FAILED' $Category }
}
function New-FreePort {
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    try {$listener.Start();[int]$listener.LocalEndpoint.Port} finally {$listener.Stop()}
}
function New-Payload {
    param([string]$Parent,[string]$Name,[string]$Value)
    $p=Join-Path $Parent $Name
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $p 'fixture.txt'),$Value,[Text.UTF8Encoding]::new($false))
    $p
}
function New-TransactionFixture {
    param([string]$Name)
    $folder=Join-Path $fixtureRoot ('tx-'+$Name+'-'+[Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $folder | Out-Null
    $payload1=New-Payload $folder 'payload-v1' 'disposable generation one'
    $payload2=New-Payload $folder 'payload-v2' 'disposable generation two'
    $destination=Join-Path $folder 'destination'
    $state=[pscustomobject]@{Task=$null;Running=$false;Foreign=$false;VerifyFail=$false;Fail='';FailCandidate='';UncertainStop=$false;OldDigest=(Get-TransactionTreeDigest $payload1);NewDigest=(Get-TransactionTreeDigest $payload2)}
    $adapter=@{
        Validate={param($root,$payload) if($state.Fail -ceq 'validate'){throw 'fixture-refusal'}}.GetNewClosure()
        VerifyStage={param($path) if($state.VerifyFail){return $false};$d=Get-TransactionTreeDigest $path;$d -cin @($state.OldDigest,$state.NewDigest)}.GetNewClosure()
        GetTask={if($state.Foreign){return [pscustomobject]@{foreign=$true}};$state.Task}.GetNewClosure()
        RegisterTask={param($path,$record) if($state.Fail -ceq 'register-before'){throw 'fixture-refusal'};$state.Task=$record.transactionId;if($state.Fail -ceq 'register-after'){throw 'fixture-refusal'}}.GetNewClosure()
        AssertTask={param($record) if($state.Foreign -or $state.Task -cne $record.transactionId){throw 'foreign task'}}.GetNewClosure()
        Start={param($path,$record) if($state.Fail -ceq 'start-before'){throw 'fixture-refusal'};if($record.payloadSha256 -ceq $state.NewDigest -and $state.FailCandidate -ceq 'start'){throw 'fixture-refusal'};$state.Running=$true;if($state.Fail -ceq 'start-after'){throw 'fixture-refusal'}}.GetNewClosure()
        VerifyReady={param($path,$record) if($record.payloadSha256 -ceq $state.NewDigest -and $state.FailCandidate -ceq 'ready'){return $false};$state.Running -and $state.Fail -cne 'ready'}.GetNewClosure()
        Stop={param($path,$record) if($state.Fail -ceq 'stop' -or ($record.payloadSha256 -ceq $state.NewDigest -and $state.UncertainStop)){throw 'fixture-refusal'};$state.Running=$false}.GetNewClosure()
        VerifyStopped={param($record) !$state.Running}.GetNewClosure()
        RemoveTask={param($record) if($state.Fail -ceq 'remove-task'){throw 'fixture-refusal'};$state.Task=$null}.GetNewClosure()
        Promote={param($path,$record) if($state.FailCandidate -ceq 'promote-before'){throw 'fixture-refusal'};$state.Task=$record.transactionId;if($state.FailCandidate -ceq 'promote-after'){throw 'fixture-refusal'}}.GetNewClosure()
    }
    [pscustomobject]@{payload1=$payload1;payload2=$payload2;destination=$destination;state=$state;adapter=$adapter}
}
function New-LifecycleFixture {
    $state=[pscustomobject]@{taskState='Ready';hostPresent=$false;ownerVerified=$false;piecesVerified=$false;listenerPresent=$false;tunnelPresent=$false;cleanupRequired=$false}
    $clock=[DateTime]::UtcNow
    $calls=[Collections.Generic.List[string]]::new()
    $definition=New-HouseholdTaskDefinition 'S-1-5-21-111-222-333-1001' $fixtureRoot (Join-Path $fixtureRoot 'fixture-host.ps1') (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') $taskName
    $task=[pscustomobject]@{xml=$definition.Xml}
    $adapter=@{
        GetTask={$task}.GetNewClosure()
        RegisterTask={param($value) throw 'unexpected registration'}.GetNewClosure()
        StartTask={$calls.Add('start')|Out-Null;$state.taskState='Running';$state.hostPresent=$true;$state.ownerVerified=$true;$state.piecesVerified=$true}.GetNewClosure()
        GetStatus={$state}.GetNewClosure()
        RequestGracefulStop={$calls.Add('stop')|Out-Null;$state.taskState='Ready';$state.hostPresent=$false;$state.ownerVerified=$false;$state.piecesVerified=$false}.GetNewClosure()
        Now={$clock}.GetNewClosure()
        Sleep={}.GetNewClosure()
    }
    [pscustomobject]@{state=$state;calls=$calls;definition=$definition;adapter=$adapter}
}
function Invoke-LiveSchedulerProbe {
    Import-Module ScheduledTasks -ErrorAction Stop
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $launcher=Join-Path $fixtureRoot 'scheduler'
    New-Item -ItemType Directory -Path $launcher | Out-Null
    $hostScript=Join-Path $launcher 'fixture-host.ps1';$ready=Join-Path $launcher 'ready.flag';$stop=Join-Path $launcher 'stop.flag';$count=Join-Path $launcher 'launch-count.txt'
    [IO.File]::WriteAllText($hostScript,@'
param([string]$Ready,[string]$Stop,[string]$Count)
$ErrorActionPreference='Stop'
Add-Content -LiteralPath $Count -Value 'launch'
New-Item -ItemType File -Path $Ready -Force|Out-Null
$deadline=[DateTime]::UtcNow.AddSeconds(30)
while(!(Test-Path -LiteralPath $Stop) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 100}
'@,[Text.UTF8Encoding]::new($false))
    $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $definition=New-HouseholdTaskDefinition $sid $launcher $hostScript $exe
    [xml]$xml=$definition.Xml
    $ns=New-Object Xml.XmlNamespaceManager($xml.NameTable);$ns.AddNamespace('t','http://schemas.microsoft.com/windows/2004/02/mit/task')
    $xml.SelectSingleNode('/t:Task/t:Triggers',$ns).RemoveAll()
    $xml.SelectSingleNode('/t:Task/t:Actions/t:Exec/t:Arguments',$ns).InnerText='-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$hostScript+'" -Ready "'+$ready+'" -Stop "'+$stop+'" -Count "'+$count+'"'
    $script:schedulerTaskName=$taskName
    if(Get-ScheduledTask -TaskName $script:schedulerTaskName -TaskPath '\' -ErrorAction SilentlyContinue){throw 'DISPOSABLE_TASK_COLLISION'}
    Register-ScheduledTask -TaskName $script:schedulerTaskName -TaskPath '\' -Xml $xml.OuterXml -ErrorAction Stop | Out-Null
    $script:schedulerTaskRegistered=$true
    Start-ScheduledTask -TaskName $script:schedulerTaskName -TaskPath '\' -ErrorAction Stop
    $deadline=[DateTime]::UtcNow.AddSeconds(15)
    while(!(Test-Path -LiteralPath $ready)){if([DateTime]::UtcNow -ge $deadline){throw 'DISPOSABLE_TASK_START_TIMEOUT'};Start-Sleep -Milliseconds 100}
    Start-ScheduledTask -TaskName $script:schedulerTaskName -TaskPath '\' -ErrorAction Stop
    Start-Sleep -Milliseconds 500
    Assert-True (@(Get-Content -LiteralPath $count).Count -eq 1)
    New-Item -ItemType File -Path $stop -Force | Out-Null
    $deadline=[DateTime]::UtcNow.AddSeconds(15)
    while((Get-ScheduledTask -TaskName $script:schedulerTaskName -TaskPath '\' -ErrorAction Stop).State -eq 'Running'){if([DateTime]::UtcNow -ge $deadline){throw 'DISPOSABLE_TASK_STOP_TIMEOUT'};Start-Sleep -Milliseconds 100}
    Unregister-ScheduledTask -TaskName $script:schedulerTaskName -TaskPath '\' -Confirm:$false -ErrorAction Stop
    $script:schedulerTaskRegistered=$false
}
function Invoke-HarmlessTunnelFixture {
    $scriptPath=Join-Path $fixtureRoot 'tunnel-fixture.ps1'
    [IO.File]::WriteAllText($scriptPath,@'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Args)
if($Args -contains '--version'){Write-Output 'fixture-tunnel 0.0.0';exit 0}
if($Args.Count -ge 3 -and $Args[0] -ceq 'runtimes' -and $Args[1] -ceq 'status'){
    [pscustomobject]@{alias=$Args[2];tunnel_id='fixture-only';process_running=$false;healthy=$true;ready=$true}|ConvertTo-Json -Compress
    exit 0
}
exit 2
'@,[Text.UTF8Encoding]::new($false))
    $oldState=$env:TUNNEL_CLIENT_STATE_DIR;$oldProfile=$env:TUNNEL_CLIENT_PROFILE_DIR;$oldKey=$env:CONTROL_PLANE_API_KEY
    try {
        $env:TUNNEL_CLIENT_STATE_DIR=$stateRoot;$env:TUNNEL_CLIENT_PROFILE_DIR=$profileRoot;$env:CONTROL_PLANE_API_KEY='fixture-only-not-a-real-credential'
        $raw=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath runtimes status fixture --json
        if($LASTEXITCODE -ne 0){throw 'fixture client failed'}
        $v=($raw|Out-String)|ConvertFrom-Json
        Assert-True ($v.alias -ceq 'fixture' -and $v.tunnel_id -ceq 'fixture-only' -and $v.process_running -eq $false)
    } finally {$env:TUNNEL_CLIENT_STATE_DIR=$oldState;$env:TUNNEL_CLIENT_PROFILE_DIR=$oldProfile;$env:CONTROL_PLANE_API_KEY=$oldKey}
}

try {
    New-Item -ItemType Directory -Path $fixtureRoot,$projectRoot,$stateRoot,$profileRoot,$keyRoot | Out-Null
    [IO.File]::WriteAllText((Join-Path $projectRoot 'project.txt'),'disposable project',[Text.UTF8Encoding]::new($false))
    $portA=New-FreePort;$portB=New-FreePort
    Assert-True ($portA -gt 0 -and $portB -gt 0 -and $portA -ne $portB)

    Invoke-Case 'fresh_install_and_duplicate_install' 'transaction' {
        $f=New-TransactionFixture 'install';$v=Invoke-InstallTransaction $f.destination $f.payload1 $f.adapter
        Assert-True ($v.state -ceq 'installed' -and $v.verified)
        Assert-Throws {Invoke-InstallTransaction $f.destination $f.payload1 $f.adapter} 'TRANSACTION_DESTINATION_EXISTS'
    }
    Invoke-Case 'repair_exact_generation' 'transaction' {
        $f=New-TransactionFixture 'repair';Invoke-InstallTransaction $f.destination $f.payload1 $f.adapter|Out-Null
        $v=Invoke-OwnedRepair $f.destination $f.adapter;Assert-True ($v.state -ceq 'repaired' -and $f.state.Running)
    }
    Invoke-Case 'uninstall_and_reinstall' 'transaction' {
        $f=New-TransactionFixture 'reinstall';Invoke-InstallTransaction $f.destination $f.payload1 $f.adapter|Out-Null
        $old=(Get-OwnedInstall $f.destination $f.adapter).record.generationId;$u=Invoke-OwnedUninstall $f.destination $f.adapter
        Assert-True ($u.state -ceq 'uninstalled');Invoke-InstallTransaction $f.destination $f.payload1 $f.adapter|Out-Null
        Assert-True ((Get-OwnedInstall $f.destination $f.adapter).record.generationId -cne $old)
    }
    Invoke-Case 'update_success_and_failed_update_rollback' 'transaction' {
        $f=New-TransactionFixture 'update-success';Invoke-InstallTransaction $f.destination $f.payload1 $f.adapter|Out-Null
        $u=Invoke-OwnedUpdate $f.destination $f.payload2 $f.adapter;Assert-True ($u.state -ceq 'updated' -and $u.rollbackAvailable)
        $failed=New-TransactionFixture 'update-rollback';Invoke-InstallTransaction $failed.destination $failed.payload1 $failed.adapter|Out-Null
        $current=(Get-OwnedInstall $failed.destination $failed.adapter).record.generationId;$failed.state.FailCandidate='ready'
        $r=Invoke-OwnedUpdate $failed.destination $failed.payload2 $failed.adapter
        Assert-True ($r.state -ceq 'rolled-back' -and !$r.candidateAccepted)
        Assert-True ((Get-OwnedInstall $failed.destination $failed.adapter).record.generationId -ceq $current)
    }
    Invoke-Case 'interrupted_install_and_update_fence' 'transaction' {
        $f=New-TransactionFixture 'interrupt-install';$f.state.Fail='start-after'
        Assert-Throws {Invoke-InstallTransaction $f.destination $f.payload1 $f.adapter} 'TRANSACTION_INSTALL_INCOMPLETE'
        Assert-True (Test-Path -LiteralPath (Join-Path $f.destination 'incomplete-install.json'))
        Assert-Throws {Get-OwnedInstall $f.destination $f.adapter} 'TRANSACTION_INCOMPLETE'
        $u=New-TransactionFixture 'interrupt-update';Invoke-InstallTransaction $u.destination $u.payload1 $u.adapter|Out-Null;$u.state.Fail='stop'
        Assert-Throws {Invoke-OwnedUpdate $u.destination $u.payload2 $u.adapter} 'TRANSACTION_UPDATE_INCOMPLETE'
        Assert-True (Test-Path -LiteralPath (Join-Path $u.destination 'incomplete-install.json'))
    }
    Invoke-Case 'foreign_task_refusal' 'transaction' {
        $f=New-TransactionFixture 'foreign-task';$f.state.Foreign=$true
        Assert-Throws {Invoke-InstallTransaction $f.destination $f.payload1 $f.adapter} 'TRANSACTION_FOREIGN_TASK'
        Assert-True (!(Test-Path -LiteralPath $f.destination))
    }
    Invoke-Case 'changed_generation_refusal' 'transaction' {
        $f=New-TransactionFixture 'changed-generation';Invoke-InstallTransaction $f.destination $f.payload1 $f.adapter|Out-Null
        $owned=Get-OwnedInstall $f.destination $f.adapter;[IO.File]::AppendAllText((Join-Path $owned.generation 'fixture.txt'),'tampered')
        Assert-Throws {Get-OwnedInstall $f.destination $f.adapter} 'TRANSACTION_PAYLOAD_CHANGED'
    }
    Invoke-Case 'malformed_receipt_and_state_refusal' 'state' {
        $f=New-TransactionFixture 'malformed';Invoke-InstallTransaction $f.destination $f.payload1 $f.adapter|Out-Null
        [IO.File]::WriteAllText((Join-Path $f.destination 'install-owner.json'),'{');Assert-Throws {Get-OwnedInstall $f.destination $f.adapter} 'TRANSACTION_RECORD_INVALID'
        $cleanup=Join-Path $fixtureRoot 'cleanup-state';New-Item -ItemType Directory -Path $cleanup|Out-Null
        [IO.File]::WriteAllText((Join-Path $cleanup 'household-cleanup-state.json'),'{');$s=Get-HouseholdCleanupState $cleanup
        Assert-True ($s.state -ceq 'unknown' -and $s.reasonCode -ceq 'HOUSEHOLD_CLEANUP_STATE_INVALID')
    }
    Invoke-Case 'lifecycle_start_duplicate_status_stop_start_restart' 'lifecycle-contract' {
        $f=New-LifecycleFixture;$a=Invoke-HouseholdLifecycle Start $f.definition $f.adapter;$b=Invoke-HouseholdLifecycle Start $f.definition $f.adapter
        $s=Invoke-HouseholdLifecycle Status $f.definition $f.adapter;$stop=Invoke-HouseholdLifecycle Stop $f.definition $f.adapter
        $again=Invoke-HouseholdLifecycle Start $f.definition $f.adapter;$restart=Invoke-HouseholdLifecycle Restart $f.definition $f.adapter
        Assert-True ($a.state -ceq 'starting' -and $b.state -ceq 'already-running' -and $s.taskState -ceq 'Running')
        Assert-True ($stop.state -ceq 'stopped' -and $again.state -ceq 'starting' -and $restart.state -ceq 'starting')
        Assert-True (@($f.calls|Where-Object {$_ -ceq 'start'}).Count -eq 3)
    }
    Invoke-Case 'foreign_listener_refusal' 'lifecycle-contract' {
        $f=New-LifecycleFixture;$f.state.listenerPresent=$true;Assert-Throws {Invoke-HouseholdLifecycle Start $f.definition $f.adapter} 'HOUSEHOLD_MIGRATION_REQUIRED'
        $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$portA)
        try {$listener.Start();Assert-True (Test-TcpPort -Port $portA -TimeoutMs 250)} finally {$listener.Stop()}
    }
    Invoke-Case 'missing_fixture_credential_refusal' 'credentials' {
        $t=[pscustomobject]@{keyPath=(Join-Path $keyRoot 'missing.dpapi')};Assert-Throws {Get-PlainRuntimeKey $t} 'TUNNEL_CREDENTIAL_MISSING'
    }
    Invoke-Case 'changed_release_settings_refusal' 'settings' {
        $root=Join-Path $fixtureRoot 'settings-fixture';$release=Join-Path $root 'release';New-Item -ItemType Directory -Path $root,$release | Out-Null
        $node=(Get-Command node.exe).Source
        $settings=[ordered]@{schemaVersion=1;project=[ordered]@{path=$projectRoot};codexless=[ordered]@{root=$release;nodeExe=$node;port=$portB}}
        [IO.File]::WriteAllText((Join-Path $root 'settings.json'),($settings|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
        Assert-Throws {Get-CompanionConfig $root} 'CODEXLESS_RELEASE_INVALID'
    }
    Invoke-Case 'harmless_local_tunnel_client_fixture' 'tunnel-fixture' {Invoke-HarmlessTunnelFixture}
    Invoke-Case 'unique_disposable_scheduler_duplicate_start' 'windows-live' {Invoke-LiveSchedulerProbe} 'UNIQUE_TASK_COOPERATIVE_LIFECYCLE'

    $nativeReport=Join-Path $fixtureRoot 'native-report.json'
    & powershell.exe -NoProfile -File (Join-Path $PSScriptRoot 'native-disposable-acceptance.ps1') -CandidateRoot $LocalCandidateRoot -ReportPath $nativeReport -QualifiedTunnelExe $QualifiedTunnelExe -QualifiedNodeExe $QualifiedNodeExe
    $nativeExit=$LASTEXITCODE
    if(Test-Path -LiteralPath $nativeReport){
        $native=Get-Content -LiteralPath $nativeReport -Raw|ConvertFrom-Json
        foreach($row in $native.results){Add-Result ('native_'+$row.name) $row.status $row.code 'native-local-candidate'}
    }else{Add-Result 'native_report' FAIL 'NATIVE_REPORT_MISSING' 'integration'}
    if($nativeExit -ne 0 -and @($results|Where-Object status -eq FAIL).Count -eq 0){Add-Result 'native_execution' FAIL 'NATIVE_PROCESS_FAILED' 'integration'}
    foreach($suite in @('transaction-task-replacement-race','transaction-reparse-race','tunnel-native-lifetime')){
        $suiteArgs=@('-NoProfile','-File',(Join-Path $PSScriptRoot ($suite+'.ps1')))
        if($suite -eq 'tunnel-native-lifetime'){$suiteArgs+=@('-QualifiedTunnelExe',$QualifiedTunnelExe)}
        $lines=@(& powershell.exe @suiteArgs)
        $exitCode=$LASTEXITCODE
        $index=0
        foreach($line in $lines){if([string]$line -match '^PASS '){$index++;Add-Result ($suite+'_'+$index) PASS 'REAL_DISPOSABLE_REGRESSION' $suite}}
        if($exitCode -ne 0 -or $index -eq 0){Add-Result $suite FAIL 'REGRESSION_PROCESS_FAILED' $suite}
    }
    $publishedInstall=@($native.results|Where-Object name -ceq 'fresh_install_through_public_entrypoint')
    if($publishedInstall.Count -eq 1 -and $publishedInstall[0].status -ceq 'PASS'){Add-Result 'published_codexless_fresh_install_start_status_doctor' PASS 'REAL_PUBLISHED_DOWNLOAD_NATIVE_INSTALL_BROWSER_FIXTURE' 'published-artifact'}else{Add-Result 'published_codexless_fresh_install_start_status_doctor' FAIL 'PUBLISHED_INSTALL_NOT_PROVEN' 'published-artifact'}
    Add-Result 'remote_tunnel_connect_acceptance' SKIP_EXTERNAL 'REQUIRES_SEPARATE_DISPOSABLE_BACKEND_AND_NONPRODUCTION_CREDENTIALS' 'external-backend'
}
finally {
    if($schedulerTaskRegistered -and $schedulerTaskName){
        try {
            New-Item -ItemType File -Path (Join-Path $fixtureRoot 'scheduler\stop.flag') -Force -ErrorAction SilentlyContinue|Out-Null
            $deadline=[DateTime]::UtcNow.AddSeconds(35)
            do {$task=Get-ScheduledTask -TaskName $schedulerTaskName -TaskPath '\' -ErrorAction SilentlyContinue;if($null -eq $task -or $task.State -ne 'Running'){break};Start-Sleep -Milliseconds 200} while([DateTime]::UtcNow -lt $deadline)
            $task=Get-ScheduledTask -TaskName $schedulerTaskName -TaskPath '\' -ErrorAction SilentlyContinue
            if($null -ne $task -and $task.State -ne 'Running'){Unregister-ScheduledTask -TaskName $schedulerTaskName -TaskPath '\' -Confirm:$false -ErrorAction SilentlyContinue}
        } catch {}
    }
    $resolved=[IO.Path]::GetFullPath($fixtureRoot)
    $expected=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('CodexlessDisposableAcceptance-'+$runId)))
    if($resolved -cne $expected){throw 'DISPOSABLE_CLEANUP_PATH_INVALID'}
    if(!$schedulerTaskRegistered -and (Test-Path -LiteralPath $resolved)){Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop}
}

$failed=@($results|Where-Object {$_.status -ceq 'FAIL'}).Count
$blocked=@($results|Where-Object {$_.status -ceq 'BLOCKED_UNPUBLISHED_ARTIFACT'}).Count
$skipped=@($results|Where-Object {$_.status -ceq 'SKIP_EXTERNAL'}).Count
$passed=@($results|Where-Object {$_.status -ceq 'PASS'}).Count
$overall=if($failed){'FAIL'}elseif($blocked){'BLOCKED_UNPUBLISHED_ARTIFACT'}elseif($skipped){'SKIP_EXTERNAL'}else{'PASS'}
$report=[ordered]@{schemaVersion=1;scope='same-machine-disposable';secondMachineAcceptance=$false;overall=$overall;counts=[ordered]@{pass=$passed;fail=$failed;skipExternal=$skipped;blockedUnpublishedArtifact=$blocked};results=[object[]]$results.ToArray()}
$json=$report|ConvertTo-Json -Depth 8
if($ReportPath){$reportFull=[IO.Path]::GetFullPath($ReportPath);$parent=Split-Path $reportFull -Parent;if(!(Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Path $parent -Force|Out-Null};[IO.File]::WriteAllText($reportFull,$json,[Text.UTF8Encoding]::new($false))}
$json
if($failed){exit 1}
