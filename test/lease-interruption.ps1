$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module (Join-Path $repo 'MutationLock.psm1') -Force
$base=Join-Path $PSScriptRoot ('.fixtures\lease-interruption-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $base|Out-Null
$root=Join-Path $base 'root';New-Item -ItemType Directory -Path $root|Out-Null
$passed=0
function Pass([string]$n){$script:passed++;"PASS $n"}
function Assert([bool]$v){if(!$v){throw 'lease interruption assertion failed'}}
try{
 Invoke-CompanionMutationLocked $root {
  Assert-CompanionMutationHeld $root
  $v=Invoke-CompanionMutationLocked $root {'nested'}
  Assert ($v -ceq 'nested');Pass 'nested controller calls borrow exact thread-held lease'
  $digest=Get-CompanionMutationRootDigest $root
  $lease=[Codexless.MutationAdmission]::Controller($digest)
  $replaced=$false
  try{[IO.File]::Delete($lease.MarkerPath);$replaced=$true}catch{}
  Assert (!$replaced);Pass 'held durable marker denies same-path object replacement'
  $rewritten=$false
  try{[IO.File]::WriteAllText($lease.MarkerPath,'{}');$rewritten=$true}catch{}
  Assert (!$rewritten);Pass 'held durable marker denies write substitution'
 }
 $digest=Get-CompanionMutationRootDigest $root
 $marker=Join-Path $base ('.codexless-mutation-'+$digest+'.lock')
 try{Invoke-CompanionMutationLocked $root {throw 'fixture failure'}}catch{if($_.Exception.Message -cne 'fixture failure'){throw}}
 Assert (!(Test-Path -LiteralPath $marker));Pass 'ordinary scoped failure releases exact lock and marker'
 Invoke-CompanionMutationLocked $root {([Codexless.MutationAdmission]::Controller($digest)).Poisoned=$true}
 Assert (Test-Path -LiteralPath $marker)
 $blocked=$false;try{Invoke-CompanionMutationLocked $root {throw 'unsafe entry'}}catch{$blocked=$_.Exception.Message -like 'MUTATION_LOCK_ABANDONED*'}
 Assert $blocked;Pass 'uncertain delegated drain preserves durable fence and denies all subsequent mutation'
 # Fixture-only retirement after proof that this test owns its exact static marker.
 Remove-Item -LiteralPath $marker -Force
 $v=Invoke-CompanionMutationLocked $root {'released'};Assert ($v -ceq 'released')
 Pass 'poisoned scope still releases OS mutex without bypassing retained marker'
 "RESULT: $passed/$passed PASS; exact marker and fail-closed interruption contract"
}finally{
 $resolved=[IO.Path]::GetFullPath($base);$allowed=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '.fixtures')).TrimEnd('\')+'\'
 if(!$resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'cleanup escaped fixture root'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
