$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
# Shared disposable install setup and its 25 assertions are also rerun here.
. (Join-Path $PSScriptRoot 'install-transaction.ps1')
$passed=0
function New-UpdateFixture {
 New-Fixture
 $script:candidate=Join-Path (Split-Path $payload -Parent) 'candidate'
 New-Item -ItemType Directory -Path $candidate|Out-Null
 [IO.File]::WriteAllText((Join-Path $candidate 'fixture.txt'),'new portable synthetic generation')
 $script:oldDigest=$mock.Digest;$script:newDigest=Get-TransactionTreeDigest $candidate
 $mock|Add-Member CandidateGeneration ''
 $mock|Add-Member FailCandidate ''
 $mock|Add-Member FailRollback ''
 $mock|Add-Member CorruptRollback $false
 $mock|Add-Member UncertainCandidateStop $false
 $mock|Add-Member ForeignPromotion $false
 $adapter.VerifyStage={param($path) $digest=Get-TransactionTreeDigest $path;!$mock.VerifyFail -and $digest -cin @($oldDigest,$newDigest)}
 $adapter.Promote={param($path,$record)
  $mock.Calls.Add('promote')
  if($mock.ForeignPromotion){$mock.Foreign=$true;throw 'foreign task changed'}
  if($record.payloadSha256 -ceq $newDigest){$mock.CandidateGeneration=$path;if($mock.FailCandidate -ceq 'promote-before'){throw 'fixture-private-value'}}
  $mock.Task=$record.transactionId
  if($record.payloadSha256 -ceq $newDigest -and $mock.FailCandidate -ceq 'promote-after'){throw 'fixture-private-value'}
 }
 $adapter.Start={param($path,$record)
  $mock.Calls.Add('start')
  if($record.payloadSha256 -ceq $newDigest -and $mock.FailCandidate -ceq 'start'){throw 'fixture-private-value'}
  if($record.payloadSha256 -ceq $oldDigest -and $mock.FailRollback -ceq 'start'){throw 'fixture-private-value'}
  $mock.Running=$true
 }
 $adapter.VerifyReady={param($path,$record)
  if($mock.CorruptRollback -and $record.payloadSha256 -ceq $newDigest){[IO.File]::AppendAllText((Join-Path $script:priorGeneration 'fixture.txt'),'foreign change')}
  $mock.Running -and !(($record.payloadSha256 -ceq $newDigest -and $mock.FailCandidate -ceq 'ready') -or ($record.payloadSha256 -ceq $oldDigest -and $mock.FailRollback -ceq 'ready'))
 }
 $adapter.Stop={param($path,$record) $mock.Calls.Add('stop');if($mock.Fail -ceq 'stop' -or ($record.payloadSha256 -ceq $newDigest -and $mock.UncertainCandidateStop)){throw 'fixture-private-value'};$mock.Running=$false}
 Install-Fixture|Out-Null
 $script:prior=(Get-OwnedInstall $destination $adapter).record
 $script:priorGeneration=(Get-OwnedInstall $destination $adapter).generation
}
function Update-Fixture {Invoke-OwnedUpdate $destination $candidate $adapter}
function TestUpdate([string]$name,[scriptblock]$body){New-UpdateFixture;& $body;$script:passed++;Write-Output "PASS $name"}
TestUpdate 'Verified candidate promotes starts and retains exact previous rollback generation' {$v=Update-Fixture;Assert ($v.state -ceq 'updated' -and $v.verified);$current=Get-OwnedInstall $destination $adapter;Assert ($current.record.generationId -cne $prior.generationId -and $current.record.payloadSha256 -ceq $newDigest);Assert ((Get-TransactionTreeDigest $priorGeneration) -ceq $oldDigest)}
foreach($failure in @('start','ready','promote-after')){TestUpdate "Candidate $failure failure restores and verifies exact prior generation" {$mock.FailCandidate=$failure;$v=Update-Fixture;Assert ($v.state -ceq 'rolled-back' -and !$v.candidateAccepted);Assert ((Get-OwnedInstall $destination $adapter).record.generationId -ceq $prior.generationId);Assert $mock.Running;Assert (!(Test-Path -LiteralPath (Join-Path $destination 'incomplete-install.json')))}}
TestUpdate 'Unverified candidate refuses before stop or update mutation' {$mock.VerifyFail=$true;$before=@($mock.Calls|Where-Object {$_ -eq 'stop'}).Count;Refuses {Update-Fixture} 'TRANSACTION_PROVENANCE_INVALID';Assert (@($mock.Calls|Where-Object {$_ -eq 'stop'}).Count -eq $before);Assert $mock.Running}
TestUpdate 'Uncertain current stop never starts candidate or rollback' {$mock.Fail='stop';$before=@($mock.Calls|Where-Object {$_ -eq 'start'}).Count;Refuses {Update-Fixture} 'TRANSACTION_UPDATE_INCOMPLETE';Assert (@($mock.Calls|Where-Object {$_ -eq 'start'}).Count -eq $before);Assert (Test-Path -LiteralPath (Join-Path $destination 'incomplete-install.json'))}
TestUpdate 'Uncertain failed candidate stop never starts rollback' {$mock.FailCandidate='ready';$mock.UncertainCandidateStop=$true;Refuses {Update-Fixture} 'TRANSACTION_UPDATE_INCOMPLETE';Assert (Test-Path -LiteralPath (Join-Path $destination 'incomplete-install.json'))}
TestUpdate 'Changed rollback material never restarts previous generation' {$mock.FailCandidate='ready';$mock.CorruptRollback=$true;Refuses {Update-Fixture} 'TRANSACTION_UPDATE_INCOMPLETE';Assert (!$mock.Running);Assert (Test-Path -LiteralPath (Join-Path $destination 'incomplete-install.json'))}
foreach($failure in @('start','ready')){TestUpdate "Rollback $failure failure retains fence and both generations" {$mock.FailCandidate='ready';$mock.FailRollback=$failure;Refuses {Update-Fixture} 'TRANSACTION_UPDATE_INCOMPLETE';Assert (Test-Path -LiteralPath $priorGeneration);Assert (Test-Path -LiteralPath $mock.CandidateGeneration);Assert (Test-Path -LiteralPath (Join-Path $destination 'incomplete-install.json'))}}
TestUpdate 'Foreign task during promotion never receives rollback overwrite' {$mock.ForeignPromotion=$true;Refuses {Update-Fixture} 'TRANSACTION_UPDATE_INCOMPLETE';Assert $mock.Foreign;Assert (Test-Path -LiteralPath (Join-Path $destination 'incomplete-install.json'))}
TestUpdate 'Malformed current generation prevents update before stop' {[IO.File]::WriteAllText((Join-Path $destination 'install-owner.json'),'{');Refuses {Update-Fixture} 'TRANSACTION_RECORD_INVALID';Assert $mock.Running}
TestUpdate 'Successful source identity change requires exact candidate payload verification' {$v=Update-Fixture;Assert ($v.state -ceq 'updated');$o=Get-OwnedInstall $destination $adapter;[IO.File]::AppendAllText((Join-Path $o.generation 'fixture.txt'),'tampered');Refuses {Get-OwnedInstall $destination $adapter} 'TRANSACTION_PAYLOAD_CHANGED'}
TestUpdate 'Update journal contains only sanitized digests and fixed stages' {$mock.Fail='stop';Refuses {Update-Fixture} 'TRANSACTION_UPDATE_INCOMPLETE';$f=Get-Content -LiteralPath (Join-Path $destination 'incomplete-install.json') -Raw;Assert ($f -notmatch 'fixture-private-value|userSid|project|password|commandLine')}
Write-Output ("RESULT: {0}/{0} PASS; staged generation and rollback I/O real; task/runtime/provenance adapters mocked" -f $passed)
