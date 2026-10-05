$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\InstallTransaction.psm1') -Force
$root=Join-Path $PSScriptRoot ('.fixtures\transactions-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root|Out-Null
$passed=0
function Assert([bool]$v){if(!$v){throw 'assertion failed'}}
function Refuses([scriptblock]$body,[string]$code){$caught=$false;try{& $body|Out-Null}catch{$caught=$_.Exception.Message -like ($code+'*')};Assert $caught}
function New-Fixture {
 $folder=Join-Path $root ([Guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $folder|Out-Null
 $script:payload=Join-Path $folder 'payload';New-Item -ItemType Directory -Path $payload|Out-Null
 [IO.File]::WriteAllText((Join-Path $payload 'fixture.txt'),'portable synthetic payload')
 $script:destination=Join-Path $folder 'destination';$script:project=Join-Path $folder 'project';New-Item -ItemType Directory -Path $project|Out-Null;[IO.File]::WriteAllText((Join-Path $project 'user-data.txt'),'preserve user project')
 $script:mock=[pscustomobject]@{Task=$null;Running=$false;Fail='';Calls=[Collections.Generic.List[string]]::new();Digest=(Get-TransactionTreeDigest $payload);Foreign=$false;VerifyFail=$false;Stopped=$true}
 $script:adapter=@{
  Validate={param($root,$payload) $mock.Calls.Add('validate');if($mock.Fail -ceq 'validate'){throw 'fixture-private-value'}}
  VerifyStage={param($path) $mock.Calls.Add('verify-stage');if($mock.VerifyFail){return $false};(Get-TransactionTreeDigest $path) -ceq $mock.Digest}
  GetTask={if($mock.Foreign){return 'foreign'};$mock.Task}
  RegisterTask={param($path,$record) $mock.Calls.Add('register');if($mock.Fail -ceq 'register-before'){throw 'fixture-private-value'};$mock.Task=$record.transactionId;if($mock.Fail -ceq 'register-after'){throw 'fixture-private-value'}}
  AssertTask={param($record) $mock.Calls.Add('assert-task');if($mock.Foreign -or $mock.Task -cne $record.transactionId){throw 'foreign task'}}
  Start={param($path,$record) $mock.Calls.Add('start');if($mock.Fail -ceq 'start-before'){throw 'fixture-private-value'};$mock.Running=$true;if($mock.Fail -ceq 'start-after'){throw 'fixture-private-value'}}
  VerifyReady={param($path,$record) $mock.Calls.Add('ready');$mock.Running -and $mock.Fail -cne 'ready'}
  Stop={param($path,$record) $mock.Calls.Add('stop');if($mock.Fail -ceq 'stop'){throw 'fixture-private-value'};$mock.Running=$false}
  VerifyStopped={param($record) !$mock.Running -and $mock.Stopped}
  RemoveTask={param($record) $mock.Calls.Add('remove-task');if($mock.Fail -ceq 'remove-task'){throw 'fixture-private-value'};$mock.Task=$null}
 }
}
function Install-Fixture {Invoke-InstallTransaction $destination $payload $adapter}
function Test([string]$name,[scriptblock]$body){New-Fixture;& $body;$script:passed++;Write-Output "PASS $name"}
Test 'Clean disposable install stages verifies fences starts and finalizes' {$v=Install-Fixture;Assert ($v.state -ceq 'installed' -and $v.verified);Assert (!(Test-Path -LiteralPath (Join-Path $destination 'incomplete-install.json')));$o=Get-OwnedInstall $destination $adapter;Assert ((Get-Content -LiteralPath (Join-Path $o.generation 'fixture.txt') -Raw) -ceq 'portable synthetic payload')}
Test 'Repeated install refuses before any task mutation' {Install-Fixture|Out-Null;$before=$mock.Calls.Count;Refuses {Install-Fixture} 'TRANSACTION_DESTINATION_EXISTS';Assert ($mock.Calls.Count -eq $before)}
Test 'Existing foreign task refuses before destination creation' {$mock.Foreign=$true;Refuses {Install-Fixture} 'TRANSACTION_FOREIGN_TASK';Assert (!(Test-Path -LiteralPath $destination))}
Test 'Unverified package refuses before destination creation' {$mock.VerifyFail=$true;Refuses {Install-Fixture} 'TRANSACTION_PROVENANCE_INVALID';Assert (!(Test-Path -LiteralPath $destination))}
Test 'Validation refusal cannot create destination' {$mock.Fail='validate';$failed=$false;try{Install-Fixture}catch{$failed=$true};Assert $failed;Assert (!(Test-Path -LiteralPath $destination))}
foreach($failure in @('register-before','register-after','start-before','start-after','ready')){Test "Interrupted install at $failure retains sanitized fence" {$mock.Fail=$failure;Refuses {Install-Fixture} 'TRANSACTION_INSTALL_INCOMPLETE';$f=Get-Content -LiteralPath (Join-Path $destination 'incomplete-install.json') -Raw;Assert ($f -notmatch 'fixture-private-value|userSid|project|key|password');Refuses {Install-Fixture} 'TRANSACTION_DESTINATION_EXISTS';Refuses {Get-OwnedInstall $destination $adapter} 'TRANSACTION_INCOMPLETE'}}
Test 'Intact verified repair stops and restarts exact generation' {Install-Fixture|Out-Null;$v=Invoke-OwnedRepair $destination $adapter;Assert ($v.state -ceq 'repaired' -and $mock.Running)}
Test 'Changed generation repair refuses before stopping' {Install-Fixture|Out-Null;$o=Get-OwnedInstall $destination $adapter;[IO.File]::AppendAllText((Join-Path $o.generation 'fixture.txt'),'changed');$before=$mock.Calls.Count;Refuses {Invoke-OwnedRepair $destination $adapter} 'TRANSACTION_PAYLOAD_CHANGED';Assert ($mock.Calls.Count -eq $before)}
Test 'Changed task repair refuses without process mutation' {Install-Fixture|Out-Null;$mock.Foreign=$true;$before=@($mock.Calls|Where-Object {$_ -eq 'stop'}).Count;$failed=$false;try{Invoke-OwnedRepair $destination $adapter}catch{$failed=$true};Assert $failed;Assert (@($mock.Calls|Where-Object {$_ -eq 'stop'}).Count -eq $before)}
Test 'Uninstall removes only proven payload and task; user project survives' {Install-Fixture|Out-Null;$v=Invoke-OwnedUninstall $destination $adapter;Assert ($v.state -ceq 'uninstalled' -and !$mock.Running -and $null -eq $mock.Task);Assert ((Get-Content -LiteralPath (Join-Path $project 'user-data.txt') -Raw) -ceq 'preserve user project');Assert (!(Test-Path -LiteralPath (Join-Path $destination 'install-owner.json')))}
foreach($failure in @('stop','remove-task')){Test "Uninstall $failure retains evidence and source payload" {Install-Fixture|Out-Null;$o=Get-OwnedInstall $destination $adapter;$mock.Fail=$failure;Refuses {Invoke-OwnedUninstall $destination $adapter} 'TRANSACTION_UNINSTALL_INCOMPLETE';Assert (Test-Path -LiteralPath (Join-Path $o.generation 'fixture.txt'));Assert (Test-Path -LiteralPath (Join-Path $destination 'incomplete-install.json'))}}
Test 'Unproven exit never removes task or files' {Install-Fixture|Out-Null;$mock.Stopped=$false;Refuses {Invoke-OwnedUninstall $destination $adapter} 'TRANSACTION_UNINSTALL_INCOMPLETE';Assert ($null -ne $mock.Task)}
Test 'Unknown generation file prevents uninstall instead of deleting user data' {Install-Fixture|Out-Null;$o=Get-OwnedInstall $destination $adapter;$p=Join-Path $o.generation 'foreign.txt';[IO.File]::WriteAllText($p,'foreign');Refuses {Invoke-OwnedUninstall $destination $adapter} 'TRANSACTION_PAYLOAD_CHANGED';Assert (Test-Path -LiteralPath $p)}
Test 'Malformed owner record cannot authorize uninstall' {Install-Fixture|Out-Null;[IO.File]::WriteAllText((Join-Path $destination 'install-owner.json'),'{');Refuses {Invoke-OwnedUninstall $destination $adapter} 'TRANSACTION_RECORD_INVALID';Assert $mock.Running}
Test 'Wrong destination owner digest cannot authorize repair' {Install-Fixture|Out-Null;$p=Join-Path $destination 'install-owner.json';$v=Get-Content -LiteralPath $p -Raw|ConvertFrom-Json;$v.ownerDigest='0'*64;$v|ConvertTo-Json|Set-Content -LiteralPath $p;Refuses {Invoke-OwnedRepair $destination $adapter} 'TRANSACTION_OWNER_INVALID';Assert $mock.Running}
Test 'Unknown root state survives successful uninstall' {Install-Fixture|Out-Null;$p=Join-Path $destination 'user-note.txt';[IO.File]::WriteAllText($p,'preserve');Invoke-OwnedUninstall $destination $adapter|Out-Null;Assert ((Get-Content -LiteralPath $p -Raw) -ceq 'preserve')}
Test 'Reinstall after valid verified uninstall creates fresh generation' {Install-Fixture|Out-Null;$old=(Get-OwnedInstall $destination $adapter).record.generationId;Invoke-OwnedUninstall $destination $adapter|Out-Null;Install-Fixture|Out-Null;Assert ((Get-OwnedInstall $destination $adapter).record.generationId -cne $old);Assert $mock.Running}
Test 'Interrupted repair leaves an explicit sanitized fence' {Install-Fixture|Out-Null;$mock.Fail='ready';Refuses {Invoke-OwnedRepair $destination $adapter} 'TRANSACTION_REPAIR_INCOMPLETE';Refuses {Get-OwnedInstall $destination $adapter} 'TRANSACTION_INCOMPLETE'}
Test 'Copied ownership record cannot authorize another destination root' {Install-Fixture|Out-Null;$p=Join-Path $destination 'install-owner.json';$v=Get-Content -LiteralPath $p -Raw|ConvertFrom-Json;$v.rootDigest='0'*64;$v|ConvertTo-Json|Set-Content -LiteralPath $p;Refuses {Get-OwnedInstall $destination $adapter} 'TRANSACTION_OWNER_INVALID'}
Test 'Foreign reinstall tombstone does not permit root adoption' {New-Item -ItemType Directory -Path $destination|Out-Null;[IO.File]::WriteAllText((Join-Path $destination 'uninstalled-owner.json'),'{"version":1,"state":"uninstalled","ownerDigest":"fixture"}');Refuses {Install-Fixture} 'TRANSACTION_DESTINATION_EXISTS'}
Write-Output ("RESULT: {0}/{0} PASS; real disposable staging/fence/file I/O; task/runtime/provenance acceptance adapters mocked" -f $passed)
