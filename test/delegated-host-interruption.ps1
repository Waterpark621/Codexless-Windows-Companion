param([switch]$Controller,[string]$Fixture,[string]$Repo)
$ErrorActionPreference='Stop'
if(!$Repo){$Repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))}
Import-Module (Join-Path $Repo 'MutationLock.psm1') -Force
Import-Module (Join-Path $Repo 'UserSessionTask.psm1') -Force
Import-Module (Join-Path $Repo 'WindowsTaskAdapter.psm1') -Force
function Load-Definition([string]$folder){
 $record=Get-Content -LiteralPath (Join-Path $folder 'definition.json') -Raw|ConvertFrom-Json
 New-HouseholdTaskDefinition $record.UserSid $folder (Join-Path $Repo 'test/host-lease-probe.ps1') $record.PowerShellExe $record.Name $record.TransactionId $record.GenerationId
}
function Wait-Admitted([string]$folder){
 $deadline=[DateTime]::UtcNow.AddSeconds(30)
 while(!(Test-Path -LiteralPath (Join-Path $folder 'admitted.flag'))){
  if(Test-Path -LiteralPath (Join-Path $folder 'error.txt')){throw 'HOST_PROBE_REFUSED'}
  if([DateTime]::UtcNow -ge $deadline){throw 'HOST_PROBE_TIMEOUT'}
  Start-Sleep -Milliseconds 100
 }
}
if($Controller){
 $definition=Load-Definition $Fixture
 Invoke-CompanionMutationLocked $Fixture {
  Invoke-CompanionHostDelegation $definition Startup {
   Start-HouseholdTaskPinned $definition
   Wait-Admitted $Fixture
   # Deliberate self-exit, never external termination. The host is still admitted.
   [Environment]::Exit(73)
  }
 }
 exit 1
}
$passed=0
foreach($mode in @('host','controller')){
 $fixture=Join-Path $PSScriptRoot ('.fixtures\delegate-interruption-'+[Guid]::NewGuid().ToString('N'))
 New-Item -ItemType Directory -Path $fixture -Force|Out-Null
 $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
 $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
 $definition=New-HouseholdTaskDefinition $sid $fixture (Join-Path $Repo 'test/host-lease-probe.ps1') $exe ('Codexless-NativeAdapter-Test-'+[Guid]::NewGuid().ToString('N')) ([Guid]::NewGuid().ToString('N')) ([Guid]::NewGuid().ToString('N'))
 $definition|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $fixture 'definition.json') -Encoding UTF8
 $digest=Get-CompanionMutationRootDigest $fixture
 $marker=Join-Path (Split-Path $fixture -Parent) ('.codexless-mutation-'+$digest+'.lock')
 $registered=$false;$process=$null
 try{
  Register-HouseholdTaskCreateOnly $definition;$registered=$true
  if($mode -eq 'host'){
   [IO.File]::WriteAllText((Join-Path $fixture 'interrupt.flag'),'self-exit')
   $refused=$false
   try{
    Invoke-CompanionMutationLocked $fixture {
     Invoke-CompanionHostDelegation $definition Startup {
      Start-HouseholdTaskPinned $definition
      Wait-Admitted $fixture
      [IO.File]::WriteAllText((Join-Path $fixture 'release.flag'),'release')
     }
    }
   }catch{if($_.Exception.ToString().Contains('MUTATION_DELEGATE_INTERRUPTED')){$refused=$true}else{throw}}
   if(!$refused){throw 'HOST_INTERRUPTION_NOT_DETECTED'}
  }else{
   $args='-NoProfile -File "'+$PSCommandPath+'" -Controller -Fixture "'+$fixture+'" -Repo "'+$Repo+'"'
   $process=Start-Process -FilePath $exe -ArgumentList $args -PassThru -WindowStyle Hidden
   if(!$process.WaitForExit(35000) -or $process.ExitCode -ne 73){throw 'CONTROLLER_SELF_EXIT_UNPROVEN'}
  }
  if(!(Test-Path -LiteralPath $marker)){throw 'INTERRUPTION_MARKER_MISSING'}
  $blocked=$false
  try{Invoke-CompanionMutationLocked $fixture {throw 'MUTATION_WAS_ADMITTED'}}catch{if($_.Exception.Message -eq 'MUTATION_LOCK_ABANDONED'){$blocked=$true}else{throw}}
  if(!$blocked){throw 'INTERRUPTED_ROOT_REUSED'}
  $passed++;Write-Output ('PASS '+$mode+' self-exit retains fence and refuses subsequent mutation')
 }finally{
  [IO.File]::WriteAllText((Join-Path $fixture 'release.flag'),'release')
  if($registered){
   $deadline=[DateTime]::UtcNow.AddSeconds(35)
   while((Get-ScheduledTask -TaskName $definition.Name -TaskPath '\').State -eq 'Running'){
    if([DateTime]::UtcNow -ge $deadline){throw 'DISPOSABLE_PEER_STILL_RUNNING_EVIDENCE_RETAINED'}
    Start-Sleep -Milliseconds 100
   }
   if($process -and !$process.HasExited){throw 'DISPOSABLE_CONTROLLER_STILL_RUNNING_EVIDENCE_RETAINED'}
   # Test-only retirement after both known fixture participants have exited.
   # Ordinary product code cannot clear an abandoned marker this way.
   foreach($record in @($marker,($marker+'.delegate'))){if(Test-Path -LiteralPath $record){[IO.File]::Delete($record)}}
   Unregister-HouseholdTaskPinned $definition
  }
  if($process){$process.Dispose()}
 }
}
Write-Output ("RESULT: {0}/{0} PASS; actual host/controller self-exits, no force termination, same session" -f $passed)
