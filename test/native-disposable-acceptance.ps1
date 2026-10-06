param([Parameter(Mandatory=$true)][string]$CandidateRoot,[string]$ReportPath,[string]$FixtureBase)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module (Join-Path $repo 'NativeTransactionAdapter.psm1') -Force
Import-Module (Join-Path $repo 'InstallTransaction.psm1') -Force
Import-Module (Join-Path $repo 'UserSessionTask.psm1') -Force
Import-Module (Join-Path $repo 'WindowsTaskAdapter.psm1') -Force
Import-Module (Join-Path $repo 'CompanionRuntime.psm1') -Force
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
$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop()
foreach($file in Get-ChildItem -LiteralPath $repo -File|Where-Object {$_.Extension -in @('.ps1','.psm1','.mjs','.json') -or $_.Name -eq 'VERSION'}){
 Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $payload $file.Name)
 Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $candidate $file.Name)
}
# Non-code marker makes a distinct qualified Companion generation.
[IO.File]::WriteAllText((Join-Path $candidate 'candidate-marker.txt'),'candidate two')
$d1=Get-TransactionTreeDigest $payload;$d2=Get-TransactionTreeDigest $candidate
function New-AcceptanceAdapter([string]$root){
$result=New-NativeTransactionAdapter -Root $root -ProjectPath $project -CodexlessRoot $CandidateRoot -NodeExe $node -Port $port -TrustedPayloadSha256 @($d1,$d2) -DisposableTaskName $taskName -ReadyTimeoutSeconds 60
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
 New-HouseholdTaskDefinition -UserSid $sid -LauncherDirectory $root -HostScript (Join-Path (Join-Path (Join-Path $root 'generations') $owner.generationId) 'Task-Host.ps1') -PowerShellExe $exe -TaskName $taskName -TransactionId $owner.transactionId -GenerationId $owner.generationId
}
function Lifecycle([string]$Action){$def=Definition;Invoke-HouseholdLifecycle $Action $def (New-WindowsTaskAdapter $def) -TimeoutSeconds 100}
$failure=$false
try{
 Case 'qualified_local_candidate_identity' {$identity=Get-CodexlessReleaseIdentity $CandidateRoot;Assert ($identity.manifestSha256 -ceq '14583de39b1218ff44477b62519f7cc6351ec7c33259cf24c334ef0ed5cccb9d')}
 Case 'foreign_task_refusal' {
  $foreign=New-HouseholdTaskDefinition $sid $root (Join-Path $payload 'Task-Host.ps1') $exe $taskName ([Guid]::NewGuid().ToString('N')) ([Guid]::NewGuid().ToString('N'))
  Register-HouseholdTaskCreateOnly $foreign
  try{Refuses {Invoke-InstallTransaction $root $payload $adapter} 'TRANSACTION_FOREIGN_TASK'}finally{Unregister-HouseholdTaskPinned $foreign}
 }
 Case 'fresh_install' {$r=Invoke-InstallTransaction $root $payload $adapter;Assert ($r.state -ceq 'installed' -and $r.verified)}
 Case 'duplicate_install_refusal' {Refuses {Invoke-InstallTransaction $root $payload $adapter} 'TRANSACTION_DESTINATION_EXISTS'}
 Case 'duplicate_start' {$r=Lifecycle Start;Assert ($r.state -ceq 'already-running')}
 Case 'status_and_readiness' {$s=Lifecycle Status;Assert ($s.ownerVerified -and $s.piecesVerified -and $s.listenerPresent -and !$s.cleanupRequired);Assert (Test-CodexlessReady (Get-CompanionConfig $root))}
 Case 'stop' {$r=Lifecycle Stop;Assert ($r.state -ceq 'stopped');Assert (!(Test-TcpPort $port))}
 Case 'foreign_listener_refusal' {
  $foreignListener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$port)
  try{$foreignListener.Start();Refuses {Lifecycle Start} 'HOUSEHOLD_MIGRATION_REQUIRED'}finally{$foreignListener.Stop()}
 }
 Case 'stop_then_start' {$r=Lifecycle Start;Assert ($r.state -ceq 'starting');Assert (Test-CodexlessReady (Get-CompanionConfig $root))}
 Case 'restart' {$r=Lifecycle Restart;Assert ($r.state -ceq 'starting');Assert (Test-CodexlessReady (Get-CompanionConfig $root))}
 Case 'changed_generation_refusal' {
  $owned=Get-OwnedInstall $root $adapter
  $file=Join-Path $owned.generation 'VERSION';$saved=[IO.File]::ReadAllBytes($file)
  try{[IO.File]::AppendAllText($file,'changed');Refuses {Invoke-OwnedRepair $root $adapter} 'TRANSACTION_PAYLOAD_CHANGED'}finally{[IO.File]::WriteAllBytes($file,$saved)}
 }
 Case 'malformed_receipt_refusal' {
  $file=Join-Path $root 'install-owner.json';$saved=[IO.File]::ReadAllBytes($file)
  try{[IO.File]::WriteAllText($file,'{');Refuses {Invoke-OwnedRepair $root $adapter} 'TRANSACTION_RECORD_INVALID'}finally{[IO.File]::WriteAllBytes($file,$saved)}
 }
 Case 'credential_absence_and_error' {
  $key=Join-Path $base 'fixture.dpapi';$t=[pscustomobject]@{keyPath=$key}
  Refuses {Get-PlainRuntimeKey $t} 'TUNNEL_CREDENTIAL_MISSING'
  [IO.File]::WriteAllText($key,'not-dpapi');$bad=$false;try{Get-PlainRuntimeKey $t|Out-Null}catch{$bad=$true};Assert $bad
 }
 Case 'repair' {$r=Invoke-OwnedRepair $root $adapter;Assert ($r.state -ceq 'repaired')}
 Case 'update' {$r=Invoke-OwnedUpdate $root $candidate $adapter;Assert ($r.state -ceq 'updated')}
 Case 'failed_candidate_start_and_rollback' {
  $fault=$adapter.Clone();$inner=$adapter.Start
  $fault.Start={param($generation,$record) if($record.payloadSha256 -ceq $d1){throw 'DISPOSABLE_CANDIDATE_START_FAILURE'};& $inner $generation $record}.GetNewClosure()
  $r=Invoke-OwnedUpdate $root $payload $fault;Assert ($r.state -ceq 'rolled-back');Assert (Test-CodexlessReady (Get-CompanionConfig $root))
 }
 Case 'exact_owned_uninstall_project_preserved' {
  $r=Invoke-OwnedUninstall $root $adapter;Assert ($r.state -ceq 'uninstalled');Assert ((Get-Content -LiteralPath (Join-Path $project 'keep.txt') -Raw) -ceq 'user project sentinel')
  Assert ($null -eq (Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue))
 }
 Case 'reinstall' {$r=Invoke-InstallTransaction $root $payload $adapter;Assert ($r.state -ceq 'installed')}
 Case 'final_owned_uninstall' {$r=Invoke-OwnedUninstall $root $adapter;Assert ($r.state -ceq 'uninstalled')}
 Case 'incomplete_install_verified_recovery' {
  $interrupted=$adapter.Clone();$interrupted.Start={param($generation,$record) throw 'DISPOSABLE_START_INTERRUPTION'}
  Refuses {Invoke-InstallTransaction $root $payload $interrupted} 'TRANSACTION_INSTALL_INCOMPLETE'
  $r=Invoke-VerifiedIncompleteInstallRecovery $root $adapter
  Assert ($r.verified -and !(Test-Path -LiteralPath (Join-Path $root 'incomplete-install.json')))
  Assert (Test-CodexlessReady (Get-CompanionConfig $root))
 }
 Case 'recovered_install_uninstall' {$r=Invoke-OwnedUninstall $root $adapter;Assert ($r.state -ceq 'uninstalled')}
 Case 'interrupted_native_update_fenced' {
  Invoke-InstallTransaction $root $payload $adapter|Out-Null
  $fault=$adapter.Clone();$stopNative=$adapter.Stop
  $fault.Stop={param($generation,$record) & $stopNative $generation $record;throw 'DISPOSABLE_AFTER_STOP_INTERRUPTION'}.GetNewClosure()
  $fault.VerifyStopped={param($record) throw 'DISPOSABLE_STOP_PROOF_INTERRUPTION'}
  Refuses {Invoke-OwnedUpdate $root $candidate $fault} 'TRANSACTION_UPDATE_INCOMPLETE'
  Refuses {Get-OwnedInstall $root $adapter} 'TRANSACTION_INCOMPLETE'
  Assert (!(Test-TcpPort $port))
  $def=Definition;Unregister-HouseholdTaskPinned $def
  Assert (Test-Path -LiteralPath (Join-Path $root 'incomplete-install.json'))
 }
 Case 'interrupted_native_rollback_fenced' {
  # Separate root preserves the previous interruption evidence unchanged.
  $script:root=Join-Path $base 'rollback-interruption'
  $script:adapter=New-AcceptanceAdapter $root
  Invoke-InstallTransaction $root $payload $adapter|Out-Null
  $fault=$adapter.Clone()
  $fault.Start={param($generation,$record) throw 'DISPOSABLE_CANDIDATE_AND_ROLLBACK_START_INTERRUPTION'}
  Refuses {Invoke-OwnedUpdate $root $candidate $fault} 'TRANSACTION_UPDATE_INCOMPLETE'
  Refuses {Get-OwnedInstall $root $adapter} 'TRANSACTION_INCOMPLETE'
  Assert (!(Test-TcpPort $port))
  $def=Definition;Unregister-HouseholdTaskPinned $def
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
   $null=Invoke-HouseholdLifecycle Stop $def (New-WindowsTaskAdapter $def) -TimeoutSeconds 100
   Unregister-HouseholdTaskPinned $def
  }
 }catch{
  $failure=$true;$results.Add([pscustomobject]@{name='cleanup';status='FAIL';code='EXACT_CLEANUP_UNPROVEN_EVIDENCE_RETAINED'})
  [IO.File]::WriteAllText((Join-Path $base 'cleanup.error.txt'),($_|Out-String)+$_.ScriptStackTrace)
 }
 $report=[ordered]@{scope='same-machine-native-local-unpublished-candidate';fixtureRetained=$true;pass=@($results|Where-Object status -eq PASS).Count;fail=@($results|Where-Object status -eq FAIL).Count;skipExternal=0;blockedUnpublishedArtifact=1;results=$results.ToArray()}
 $json=$report|ConvertTo-Json -Depth 6
 [IO.File]::WriteAllText((Join-Path $base 'result.json'),$json,[Text.UTF8Encoding]::new($false))
 if($ReportPath){[IO.File]::WriteAllText($ReportPath,$json,[Text.UTF8Encoding]::new($false))}
 Write-Output ("RESULT: {0} PASS; {1} FAIL; 0 SKIP_EXTERNAL; 1 BLOCKED_UNPUBLISHED_ARTIFACT" -f $report.pass,$report.fail)
 Write-Output ('LOCAL_EVIDENCE: '+$base)
}
if($failure){exit 1}
