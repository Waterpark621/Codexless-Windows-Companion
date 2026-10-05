$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\InstallTransaction.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\BoundedNative.psm1') -Force
$root=Join-Path $PSScriptRoot ('.fixtures\transaction-chaos-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root|Out-Null
$powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$hash=(Get-FileHash -LiteralPath $powershell -Algorithm SHA256).Hash.ToLowerInvariant()
$worker=Join-Path $PSScriptRoot 'transaction-interrupt-worker.ps1';$passed=0
function Assert([bool]$v){if(!$v){throw 'assertion failed'}}
foreach($operation in @('install','update')){
 $stages=if($operation -ceq 'install'){@('promoting','registering','starting','verifying','finalizing')}else{@('stopping-current','promoting-candidate','starting-candidate','verifying-candidate','finalizing')}
 foreach($stage in $stages){
  $folder=Join-Path $root ([Guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $folder|Out-Null
  $result=Invoke-BoundedNative $powershell $hash @('-NoProfile','-ExecutionPolicy','Bypass','-File',$worker,'-FixtureRoot',$folder,'-Operation',$operation,'-Stage',$stage) $folder -TimeoutMs 30000
  Assert (!$result.Ok -and $result.ExitCode -eq 73 -and !$result.LifetimeMayRemain)
  $destination=Join-Path $folder 'destination';$path=Join-Path $destination 'incomplete-install.json'
  Assert (Test-Path -LiteralPath $path)
  $f=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
  Assert ($f.operation -ceq $operation -and $f.stage -ceq $stage -and $f.requiresVerifiedRecovery -and (Get-Content -LiteralPath $path -Raw) -notmatch 'userSid|commandLine|password|C:\\')
  $caught=$false;try{Get-OwnedInstall $destination @{}|Out-Null}catch{$caught=$_.Exception.Message -like 'TRANSACTION_INCOMPLETE*'};Assert $caught
  $passed++;Write-Output "PASS actual process exit at $operation/$stage retains fence and refuses ordinary operation"
 }
}
$folder=Join-Path $root ([Guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $folder|Out-Null
$argv=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$worker+'"'),'-FixtureRoot',('"'+$folder+'"'),'-Operation','mutex')
$child=Start-Process -FilePath $powershell -ArgumentList $argv -WindowStyle Hidden -PassThru
try{
 $deadline=[DateTime]::UtcNow.AddSeconds(5)
 while(!(Test-Path -LiteralPath (Join-Path $folder 'mutex-ready.flag'))){if([DateTime]::UtcNow -gt $deadline){throw 'fixture lock timeout'};Start-Sleep -Milliseconds 25}
 $destination=Join-Path $folder 'destination';$caught=$false
 try{Invoke-InstallTransaction $destination $folder @{}|Out-Null}catch{$caught=$_.Exception.Message -ceq 'TRANSACTION_CONCURRENT_OPERATION'}
 Assert $caught;Assert (!(Test-Path -LiteralPath $destination));$passed++;Write-Output 'PASS concurrent real Windows process mutex refuses before destination mutation'
}finally{
 [IO.File]::WriteAllText((Join-Path $folder 'mutex-stop.flag'),'stop')
 if(!$child.WaitForExit(10000)){throw 'fixture lock worker did not cooperatively exit'}
 $child.Dispose()
}
Write-Output ("RESULT: {0}/{0} PASS; actual disposable process exits, Windows mutex and local journal I/O; no Scheduler or live processes operated" -f $passed)
