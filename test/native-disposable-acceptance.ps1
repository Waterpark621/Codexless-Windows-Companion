param([Parameter(Mandatory=$true)][string]$CandidateRoot,[string]$ReportPath,[string]$FixtureBase,[string]$QualifiedTunnelExe,[string]$QualifiedNodeExe)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module (Join-Path $repo 'NativeTransactionAdapter.psm1') -Force
Import-Module (Join-Path $repo 'InstallTransaction.psm1') -Force
Import-Module (Join-Path $repo 'UserSessionTask.psm1') -Force
Import-Module (Join-Path $repo 'WindowsTaskAdapter.psm1') -Force
Import-Module (Join-Path $repo 'CompanionRuntime.psm1') -Force
# Keep commands bound to this harness module instance when installed CLI imports
# another immutable generation. No native authority or test expectations change.
$definitionCommand=Get-Command New-HouseholdTaskDefinition
$lifecycleCommand=Get-Command Invoke-HouseholdLifecycle
$windowsAdapterCommand=Get-Command New-WindowsTaskAdapter
$configCommand=Get-Command Get-CompanionConfig
$readyCommand=Get-Command Test-CodexlessReady
$ownedCommand=Get-Command Get-OwnedInstall
$nativeCommand0=Get-Command New-NativeTransactionAdapter
$nativeCommand1=Get-Command Register-HouseholdTaskCreateOnly
$nativeCommand2=Get-Command Unregister-HouseholdTaskPinned
$nativeCommand3=Get-Command Invoke-InstallTransaction
$nativeCommand4=Get-Command Invoke-OwnedRepair
$nativeCommand5=Get-Command Invoke-OwnedUpdate
$nativeCommand6=Get-Command Invoke-OwnedUninstall
$nativeCommand7=Get-Command Invoke-VerifiedIncompleteInstallRecovery
$nativeCommand8=Get-Command Test-TcpPort
$nativeCommand9=Get-Command Test-HouseholdOwnershipEvidence
$nativeCommand10=Get-Command Get-PlainRuntimeKey
$nativeCommand11=Get-Command Get-CodexlessReleaseIdentity
$run=[Guid]::NewGuid().ToString('N')
if(!$FixtureBase){$FixtureBase=Join-Path $PSScriptRoot '.fixtures'}
$base=[IO.Path]::GetFullPath((Join-Path $FixtureBase ('native-acceptance-'+$run)))
New-Item -ItemType Directory -Path $base -Force|Out-Null
$results=[Collections.Generic.List[object]]::new()
$root=Join-Path $base 'installation';$project=Join-Path $base 'project';$payload=Join-Path $base 'payload-v1';$candidate=Join-Path $base 'payload-v2'
foreach($path in @($project,$payload,$candidate)){New-Item -ItemType Directory -Path $path|Out-Null}
[IO.File]::WriteAllText((Join-Path $project 'keep.txt'),'user project sentinel')
$taskName='Codexless-NativeAdapter-Test-'+$run
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$node=(Get-Command node.exe).Source
$script:RuntimeRoot=$CandidateRoot
$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop()
foreach($file in Get-ChildItem -LiteralPath $repo -File|Where-Object {$_.Extension -in @('.ps1','.psm1','.mjs','.json') -or $_.Name -eq 'VERSION'}){
 Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $payload $file.Name)
 Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $candidate $file.Name)
}
# Non-code marker makes a distinct qualified Companion generation.
[IO.File]::WriteAllText((Join-Path $candidate 'candidate-marker.txt'),'candidate two')
$d1=Get-TransactionTreeDigest $payload;$d2=Get-TransactionTreeDigest $candidate
function New-AcceptanceAdapter([string]$root){
$result=& $nativeCommand0 -Root $root -ProjectPath $project -CodexlessRoot $script:RuntimeRoot -NodeExe $node -Port $port -TrustedPayloadSha256 @($d1,$d2) -DisposableTaskName $taskName -ReadyTimeoutSeconds 60
$registerNative=$result.RegisterTask
$result.RegisterTask={
 param($generation,$record)
 & $registerNative $generation $record
 $configPath=Join-Path $root 'acceptance-profile\codex\config.toml'
 if(!(Test-Path -LiteralPath $configPath)){
  $trustedPath=$project.Replace('\','/')
  $config="sandbox_mode = 'read-only'`napproval_policy = 'never'`n[projects.'$trustedPath']`ntrust_level = 'trusted'`n"
  [IO.File]::WriteAllText($configPath,$config,[Text.UTF8Encoding]::new($false))
 }
}.GetNewClosure()
 return $result
}
$adapter=New-AcceptanceAdapter $root
function Assert([bool]$v,[string]$m='native acceptance assertion failed'){if(!$v){throw $m}}
function Refuses([scriptblock]$b,[string]$prefix){$refused=$false;try{& $b|Out-Null}catch{if($_.Exception.Message -like ($prefix+'*')){$refused=$true}else{throw}};Assert $refused ('expected '+$prefix)}
function Case([string]$name,[scriptblock]$body){
 try{& $body|Out-Null;$results.Add([pscustomobject]@{name=$name;status='PASS';code='NATIVE_VERIFIED'});Write-Output "PASS $name"}
 catch{
  $results.Add([pscustomobject]@{name=$name;status='FAIL';code='NATIVE_ASSERTION_FAILED'})
  # Local diagnostic remains inside ignored fixture root, not the portable report.
  [IO.File]::WriteAllText((Join-Path $base ($name+'.error.txt')),($_|Out-String)+$_.ScriptStackTrace)
  Write-Output "FAIL $name"
  throw
 }
}
function Definition {
 $owner=Get-Content -LiteralPath (Join-Path $root 'native-adapter-owner.json') -Raw|ConvertFrom-Json
 & $definitionCommand -UserSid $sid -LauncherDirectory $root -HostScript (Join-Path (Join-Path (Join-Path $root 'generations') $owner.generationId) 'Task-Host.ps1') -PowerShellExe $exe -TaskName $taskName -TransactionId $owner.transactionId -GenerationId $owner.generationId
}
function Lifecycle([string]$Action){$def=Definition;& $lifecycleCommand $Action $def (& $windowsAdapterCommand $def) -TimeoutSeconds 100}
function Profiles([string]$Action,[string]$Id) {
 $owned=& $ownedCommand $root $adapter
 $args=@{Root=$root;Action=$Action;DisposableTaskName=$taskName}
 if($Id){$args.ProfileId=$Id}
 if($Action -ceq 'Add'){
  $args.Alias=$Id;$args.TunnelId='tunnel_fixture_'+$Id;$args.TunnelClientExe=$QualifiedTunnelExe;$args.Disabled=$true
 }
 if($Action -in @('Add','RotateKey')){$args.RuntimeApiKey=ConvertTo-SecureString ('fixture-native-profile-'+$Id+'-'+$Action) -AsPlainText -Force}
 & (Join-Path $owned.generation 'Tunnels.ps1') @args
}
$failure=$false
try{
 Case 'qualified_local_candidate_identity' {$identity=& $nativeCommand11 $CandidateRoot;Assert ($identity.manifestSha256 -ceq '56f35e9c5b92f8ffca6279ce5bcf8d63ab249489751f900ab564bd7be522fc78')}
 Case 'foreign_task_refusal' {
  $foreign=& $definitionCommand $sid $root (Join-Path $payload 'Task-Host.ps1') $exe $taskName ([Guid]::NewGuid().ToString('N')) ([Guid]::NewGuid().ToString('N'))
  & $nativeCommand1 $foreign
  try{Refuses {& $nativeCommand3 $root $payload $adapter} 'TRANSACTION_FOREIGN_TASK'}finally{& $nativeCommand2 $foreign}
 }
 Case 'fresh_install_through_public_entrypoint' {
  Import-Module (Join-Path $repo 'PublicInstall.psm1') -Force -DisableNameChecking
  $public=Get-Module PublicInstall
  # Retain the real published policy, HTTPS download, archive/root verification
  # and locked dependency provisioner. Only test task authority and Browser
  # backend are isolated; no production tasks or Browser state are used.
  $fixtureServices=& $public {New-PublicInstallServices}
  if($QualifiedNodeExe){
   $p=& $public {Get-ArtifactPolicy node}
   Assert ((Get-FileHash -LiteralPath $QualifiedNodeExe -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $p.executableSha256)
   $fixtureServices.Binary={param($role,$directory) if($role -cne 'node'){throw 'UNEXPECTED_FIXTURE_BINARY_REQUEST'};$QualifiedNodeExe}.GetNewClosure()
  }
  $fixtureServices.Adapter={param($Root,$ProjectPath,$Port,$TrustedPayloadSha256,$NodeExe,$CodexlessRoot)
   $script:RuntimeRoot=$CodexlessRoot
   $script:adapter=New-AcceptanceAdapter $Root
   $script:adapter
  }
  # Browser acceptance stays deterministic; this native case proves task/owner/listener readiness without a production Browser backend.
  $fixtureServices.Doctor={param($generation,$root) $state=Lifecycle Status; $state.ownerVerified -and $state.piecesVerified -and !$state.cleanupRequired -and (& $readyCommand (& $configCommand $root))}
  & $public {param($s)$script:NativePublicServices=$s;function script:New-PublicInstallServices {$script:NativePublicServices}} $fixtureServices
  $r=Invoke-PublicCompanionInstall -PayloadRoot $payload -TrustedPayloadSha256 $d1 -InstallDirectory $root -ProjectPath $project -Port $port -NoTunnel
  Assert ($r.state -ceq 'installed' -and $r.verified -and $r.doctorVerdict -ceq 'PASS')
 }
 Case 'duplicate_install_refusal' {Refuses {& $nativeCommand3 $root $payload $adapter} 'TRANSACTION_DESTINATION_EXISTS'}
 Case 'installed_public_status_stop_start_restart' {
  $owned=& $ownedCommand $root $adapter
  $arguments=@{DisposableTaskName=$taskName}
  $s=(& (Join-Path $owned.generation 'Status.ps1') @arguments|Out-String)|ConvertFrom-Json
  Assert ($s.ownerVerified -and $s.piecesVerified -and $s.listenerPresent -and !$s.cleanupRequired)
  $r=(& (Join-Path $owned.generation 'Stop.ps1') @arguments|Out-String)|ConvertFrom-Json
  Assert ($r.state -ceq 'stopped' -and !(& $nativeCommand8 $port))
  $r=(& (Join-Path $owned.generation 'Start.ps1') @arguments|Out-String)|ConvertFrom-Json
  Assert ($r.state -ceq 'starting' -and (& $readyCommand (& $configCommand $root)))
  $r=(& (Join-Path $owned.generation 'Restart.ps1') @arguments|Out-String)|ConvertFrom-Json
  Assert ($r.state -ceq 'starting' -and (& $readyCommand (& $configCommand $root)))
 }
 Case 'installed_doctor_listener_generation_ownership' {
  $owned=& $ownedCommand $root $adapter
  Import-Module (Join-Path $owned.generation 'DoctorSupport.psm1') -Force -DisableNameChecking
  $snapshot=Get-DoctorListenerOwnershipSnapshot -InstallDirectory $root -Config (& $configCommand $root) -DisposableTaskName $taskName
  Assert ($null -ne $snapshot -and $snapshot.hostPid -gt 0 -and $snapshot.wrapperPid -gt 0)
 }
 Case 'fresh_process_doctor_establishes_real_config_owner_and_readiness' {
  $owned=& $ownedCommand $root $adapter
  $raw=& $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $owned.generation 'Doctor.ps1') -InstallDirectory $root -DisposableTaskName $taskName -Json
  $exit=$LASTEXITCODE
  $doctor=($raw|Out-String)|ConvertFrom-Json
  # This isolated Browser has no production connection. Check real package,
  # Scheduler owner, listener and release readiness; do not manufacture PASS.
  foreach($name in @('settings','release','node','task','owner','listener-ownership','codexless-readiness')){
   $check=@($doctor.checks|Where-Object {$_.name -ceq $name})
   Assert ($check.Count -eq 1 -and $check[0].state -ceq 'PASS')
  }
  $browser=@($doctor.checks|Where-Object {$_.name -ceq 'browser-backend'})
  Assert ($browser.Count -eq 1 -and $browser[0].state -ceq 'FAIL' -and !$doctor.ok -and $exit -ne 0)
 }
 Case 'duplicate_start'  {$r=Lifecycle Start;Assert ($r.state -ceq 'already-running')}
 Case 'status_and_readiness' {$s=Lifecycle Status;Assert ($s.ownerVerified -and $s.piecesVerified -and $s.listenerPresent -and !$s.cleanupRequired);Assert (& $readyCommand (& $configCommand $root))}
 Case 'stop' {$r=Lifecycle Stop;Assert ($r.state -ceq 'stopped');Assert (!(& $nativeCommand8 $port))}
 if($QualifiedTunnelExe){
  # Profiles are disabled throughout native acceptance. Synthetic local keys are
  # never used for remote connect; official status uses only isolated local state.
  Case 'advanced_add_three_disabled_profiles_through_installed_cli' {
   foreach($id in @('alpha','beta','gamma')){$r=Profiles Add $id;Assert ($r.state -ceq 'configured')}
   $profiles=@(Profiles List '');Assert ($profiles.Count -eq 3 -and @($profiles|Where-Object enabled).Count -eq 0)
   foreach($profile in $profiles){Assert ($profile.PSObject.Properties.Name -notcontains 'keyPath')}
  }
  Case 'advanced_independent_readonly_status_projection' {
   $profiles=@(Profiles Status '');Assert ($profiles.Count -eq 3)
   Assert (@($profiles|Where-Object {$_.alive -or $_.owned -or $_.ready}).Count -eq 0)
   Assert (($profiles|ConvertTo-Json) -notmatch 'fixture-native-profile|ciphertext|keyFile|keyPath')
  }
  Case 'advanced_rotation_and_local_remove_preserve_sibling_binding' {
   $before=(& $configCommand $root).tunnels;$alpha=($before|Where-Object profileId -eq alpha)
   $null=Profiles RotateKey beta;$null=Profiles Remove gamma
   $profiles=(& $configCommand $root).tunnels;Assert ($profiles.Count -eq 2)
   Assert (($profiles|Where-Object profileId -eq alpha).keyPath -ceq $alpha.keyPath)
   $key=& $nativeCommand10 ($profiles|Where-Object profileId -eq beta)
   try{Assert ($key -ceq 'fixture-native-profile-beta-RotateKey')}finally{$key=$null}
  }
  Case 'advanced_disabled_collection_clean_start_restart_stop_binding' {
   $before=(& $configCommand $root).tunnels|ConvertTo-Json -Depth 4 -Compress
   $null=Lifecycle Start;$state=Lifecycle Status
   Assert ($state.ownerVerified -and $state.piecesVerified -and $state.listenerPresent -and !$state.cleanupRequired)
   $null=Lifecycle Restart;$null=Lifecycle Stop
   Assert (!(& $nativeCommand9 $root) -and !(& $nativeCommand8 $port))
   Assert (((& $configCommand $root).tunnels|ConvertTo-Json -Depth 4 -Compress) -ceq $before)
  }
  Case 'advanced_remove_remaining_profiles_restores_zero_active_tunnels' {
   $null=Profiles Remove alpha;$null=Profiles Remove beta
   Assert (@((& $configCommand $root).tunnels).Count -eq 0)
  }
 }
 Case 'foreign_listener_refusal' {
  $foreignListener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$port)
  try{$foreignListener.Start();Refuses {Lifecycle Start} 'HOUSEHOLD_MIGRATION_REQUIRED'}finally{$foreignListener.Stop()}
 }
 Case 'stop_then_start' {$r=Lifecycle Start;Assert ($r.state -ceq 'starting');Assert (& $readyCommand (& $configCommand $root))}
 Case 'restart' {$r=Lifecycle Restart;Assert ($r.state -ceq 'starting');Assert (& $readyCommand (& $configCommand $root))}
 Case 'changed_generation_refusal' {
  $owned=& $ownedCommand $root $adapter
  $file=Join-Path $owned.generation 'VERSION';$saved=[IO.File]::ReadAllBytes($file)
  try{[IO.File]::AppendAllText($file,'changed');Refuses {& $nativeCommand4 $root $adapter} 'TRANSACTION_PAYLOAD_CHANGED'}finally{[IO.File]::WriteAllBytes($file,$saved)}
 }
 Case 'malformed_receipt_refusal' {
  $file=Join-Path $root 'install-owner.json';$saved=[IO.File]::ReadAllBytes($file)
  try{[IO.File]::WriteAllText($file,'{');Refuses {& $nativeCommand4 $root $adapter} 'TRANSACTION_RECORD_INVALID'}finally{[IO.File]::WriteAllBytes($file,$saved)}
 }
 Case 'credential_absence_and_error' {
  $key=Join-Path $base 'fixture.dpapi';$t=[pscustomobject]@{keyPath=$key}
  Refuses {& $nativeCommand10 $t} 'TUNNEL_CREDENTIAL_MISSING'
  [IO.File]::WriteAllText($key,'not-dpapi');$bad=$false;try{& $nativeCommand10 $t|Out-Null}catch{$bad=$true};Assert $bad
 }
 Case 'repair' {$r=& $nativeCommand4 $root $adapter;Assert ($r.state -ceq 'repaired')}
 Case 'update' {$r=& $nativeCommand5 $root $candidate $adapter;Assert ($r.state -ceq 'updated')}
 Case 'failed_candidate_start_and_rollback' {
  $fault=$adapter.Clone();$inner=$adapter.Start
  $fault.Start={param($generation,$record) if($record.payloadSha256 -ceq $d1){throw 'DISPOSABLE_CANDIDATE_START_FAILURE'};& $inner $generation $record}.GetNewClosure()
  $r=& $nativeCommand5 $root $payload $fault;Assert ($r.state -ceq 'rolled-back');Assert (& $readyCommand (& $configCommand $root))
 }
 Case 'exact_owned_uninstall_project_preserved' {
  $r=& $nativeCommand6 $root $adapter;Assert ($r.state -ceq 'uninstalled');Assert ((Get-Content -LiteralPath (Join-Path $project 'keep.txt') -Raw) -ceq 'user project sentinel')
  Assert ($null -eq (Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue))
 }
 Case 'reinstall' {$r=& $nativeCommand3 $root $payload $adapter;Assert ($r.state -ceq 'installed')}
 Case 'final_owned_uninstall' {$r=& $nativeCommand6 $root $adapter;Assert ($r.state -ceq 'uninstalled')}
 Case 'incomplete_install_verified_recovery' {
  $interrupted=$adapter.Clone();$interrupted.Start={param($generation,$record) throw 'DISPOSABLE_START_INTERRUPTION'}
  Refuses {& $nativeCommand3 $root $payload $interrupted} 'TRANSACTION_INSTALL_INCOMPLETE'
  $r=& $nativeCommand7 $root $adapter
  Assert ($r.verified -and !(Test-Path -LiteralPath (Join-Path $root 'incomplete-install.json')))
  Assert (& $readyCommand (& $configCommand $root))
 }
 Case 'recovered_install_uninstall' {$r=& $nativeCommand6 $root $adapter;Assert ($r.state -ceq 'uninstalled')}
 Case 'interrupted_native_update_fenced' {
  & $nativeCommand3 $root $payload $adapter|Out-Null
  $fault=$adapter.Clone();$stopNative=$adapter.Stop
  $fault.Stop={param($generation,$record) & $stopNative $generation $record;throw 'DISPOSABLE_AFTER_STOP_INTERRUPTION'}.GetNewClosure()
  $fault.VerifyStopped={param($record) throw 'DISPOSABLE_STOP_PROOF_INTERRUPTION'}
  Refuses {& $nativeCommand5 $root $candidate $fault} 'TRANSACTION_UPDATE_INCOMPLETE'
  Refuses {& $ownedCommand $root $adapter} 'TRANSACTION_INCOMPLETE'
  Assert (!(& $nativeCommand8 $port))
  $def=Definition;& $nativeCommand2 $def
  Assert (Test-Path -LiteralPath (Join-Path $root 'incomplete-install.json'))
 }
 Case 'interrupted_native_rollback_fenced' {
  # Separate root preserves the previous interruption evidence unchanged.
  $script:root=Join-Path $base 'rollback-interruption'
  $script:adapter=New-AcceptanceAdapter $root
  & $nativeCommand3 $root $payload $adapter|Out-Null
  $fault=$adapter.Clone()
  $fault.Start={param($generation,$record) throw 'DISPOSABLE_CANDIDATE_AND_ROLLBACK_START_INTERRUPTION'}
  Refuses {& $nativeCommand5 $root $candidate $fault} 'TRANSACTION_UPDATE_INCOMPLETE'
  Refuses {& $ownedCommand $root $adapter} 'TRANSACTION_INCOMPLETE'
  Assert (!(& $nativeCommand8 $port))
  $def=Definition;& $nativeCommand2 $def
  Assert (Test-Path -LiteralPath (Join-Path $root 'incomplete-install.json'))
  Assert ((Get-Content -LiteralPath (Join-Path $project 'keep.txt') -Raw) -ceq 'user project sentinel')
 }
}catch{$failure=$true}
finally{
 # Cleanup uses only the explicit GUID task and exact generation definition. No
 # forced process stop, production fallback, or deletion of uncertain evidence.
 try{
  $task=Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
  if($task){
   $def=Definition
   $null=& $lifecycleCommand Stop $def (& $windowsAdapterCommand $def) -TimeoutSeconds 100
   & $nativeCommand2 $def
  }
 }catch{
  $failure=$true;$results.Add([pscustomobject]@{name='cleanup';status='FAIL';code='EXACT_CLEANUP_UNPROVEN_EVIDENCE_RETAINED'})
  [IO.File]::WriteAllText((Join-Path $base 'cleanup.error.txt'),($_|Out-String)+$_.ScriptStackTrace)
 }
 $report=[ordered]@{scope='same-machine-native-published-distribution-disposable';fixtureRetained=$true;pass=@($results|Where-Object status -eq PASS).Count;fail=@($results|Where-Object status -eq FAIL).Count;skipExternal=0;blockedUnpublishedArtifact=0;results=$results.ToArray()}
 $json=$report|ConvertTo-Json -Depth 6
 [IO.File]::WriteAllText((Join-Path $base 'result.json'),$json,[Text.UTF8Encoding]::new($false))
 if($ReportPath){[IO.File]::WriteAllText($ReportPath,$json,[Text.UTF8Encoding]::new($false))}
 Write-Output ("RESULT: {0} PASS; {1} FAIL; 0 SKIP_EXTERNAL; 0 BLOCKED_UNPUBLISHED_ARTIFACT" -f $report.pass,$report.fail)
 Write-Output ('LOCAL_EVIDENCE: '+$base)
}
if($failure){exit 1}
