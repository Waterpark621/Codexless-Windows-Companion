param([string]$FixtureRoot,[ValidateSet('install','update','mutex')][string]$Operation,[string]$Stage)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\InstallTransaction.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\MutationLock.psm1') -Force
if($Operation -ceq 'mutex'){
 $root=[IO.Path]::GetFullPath((Join-Path $FixtureRoot 'destination')).TrimEnd('\')
 Invoke-CompanionMutationLocked $root {
  [IO.File]::WriteAllText((Join-Path $FixtureRoot 'mutex-ready.flag'),'ready')
  $deadline=[DateTime]::UtcNow.AddSeconds(15)
  while(!(Test-Path -LiteralPath (Join-Path $FixtureRoot 'mutex-stop.flag'))){if([DateTime]::UtcNow -ge $deadline){throw 'fixture lock timeout'};Start-Sleep -Milliseconds 25}
 }
 exit 0
}
$payload=Join-Path $FixtureRoot 'payload';$candidate=Join-Path $FixtureRoot 'candidate';$destination=Join-Path $FixtureRoot 'destination'
foreach($p in @($payload,$candidate)){New-Item -ItemType Directory -Path $p -Force|Out-Null}
[IO.File]::WriteAllText((Join-Path $payload 'fixture.txt'),'previous synthetic generation')
[IO.File]::WriteAllText((Join-Path $candidate 'fixture.txt'),'candidate synthetic generation')
$digests=@((Get-TransactionTreeDigest $payload),(Get-TransactionTreeDigest $candidate))
$script:task=$null;$script:running=$false
$adapter=@{
 Validate={param($root,$payload)}
 VerifyStage={param($path) (Get-TransactionTreeDigest $path) -cin $digests}
 GetTask={$script:task}
 RegisterTask={param($path,$record) $script:task=$record.transactionId}
 AssertTask={param($record) if($script:task -cne $record.transactionId){throw 'foreign task'}}
 Start={param($path,$record) $script:running=$true}
 VerifyReady={param($path,$record) $script:running}
 Stop={param($path,$record) $script:running=$false}
 VerifyStopped={param($record) !$script:running}
 RemoveTask={param($record) $script:task=$null}
 Promote={param($path,$record) $script:task=$record.transactionId}
}
$module=Get-Module InstallTransaction
function Set-Interruption {
 & $module {param($stage)
  $script:OriginalStageWriter=${function:Set-TransactionStage};$script:InterruptStage=$stage
  function script:Set-TransactionStage {param($Fence,$Path,$Stage)
   & $script:OriginalStageWriter $Fence $Path $Stage
   if($Stage -ceq $script:InterruptStage){exit 73}
  }
 } $Stage
}
if($Operation -ceq 'install'){Set-Interruption;Invoke-InstallTransaction $destination $payload $adapter|Out-Null}
else{Invoke-InstallTransaction $destination $payload $adapter|Out-Null;Set-Interruption;Invoke-OwnedUpdate $destination $candidate $adapter|Out-Null}
exit 76
