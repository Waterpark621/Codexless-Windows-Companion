$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module (Join-Path $repo 'MutationLock.psm1') -Force
$fixture=Join-Path $PSScriptRoot ('.fixtures\mutation-lock-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force|Out-Null
$root=Join-Path $fixture 'root'
New-Item -ItemType Directory -Path $root -Force|Out-Null
$ready=Join-Path $fixture 'ready'
$release=Join-Path $fixture 'release'
$holder=Join-Path $fixture 'holder.ps1'
$abandon=Join-Path $fixture 'abandon.ps1'
$module=(Join-Path $repo 'MutationLock.psm1')
$passed=0
function Assert([bool]$v,[string]$m='assertion failed'){if(!$v){throw $m}}
function Test([string]$n,[scriptblock]$b){& $b;$script:passed++;Write-Output "PASS $n"}
try {
$holderText=@'
param([string]$Module,[string]$Root,[string]$Ready,[string]$Release)
$ErrorActionPreference='Stop'
Import-Module $Module -Force
Invoke-CompanionMutationLocked $Root {
 Set-Content -LiteralPath $Ready -Value ready -Encoding ascii
 while(!(Test-Path -LiteralPath $Release)){Start-Sleep -Milliseconds 50}
}
'@
$holderText | Set-Content -LiteralPath $holder -Encoding utf8
$abandonText=@'
param([string]$Module,[string]$Root,[string]$Ready)
$ErrorActionPreference='Stop'
Import-Module $Module -Force
Invoke-CompanionMutationLocked $Root {
 Set-Content -LiteralPath $Ready -Value held -Encoding ascii
 while($true){Start-Sleep -Seconds 1}
}
'@
$abandonText | Set-Content -LiteralPath $abandon -Encoding utf8
Test 'Global mutation mutex excludes a second process for the same root' {
 $p=Start-Process powershell.exe -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$holder,'-Module',$module,'-Root',$root,'-Ready',$ready,'-Release',$release) -PassThru -WindowStyle Hidden
 try {
  $deadline=[DateTime]::UtcNow.AddSeconds(10)
  while(!(Test-Path $ready) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 50}
  Assert (Test-Path $ready) 'holder did not acquire mutation lock'
  $blocked=$false
  try{Invoke-CompanionMutationLocked $root { throw 'second process entered critical section' }}catch{$blocked=$_.Exception.Message -like 'MUTATION_CONCURRENT_OPERATION*'}
  Assert $blocked 'second process was not excluded'
 } finally {
  Set-Content -LiteralPath $release -Value release -Encoding ascii
  $p.WaitForExit(10000)|Out-Null
  if(!$p.HasExited){$p.Kill();$p.WaitForExit()}
  $p.Dispose()
 }
}
Test 'Mutation mutex is reusable after normal release' {
 $value=Invoke-CompanionMutationLocked $root { 'entered' }
 Assert ($value -ceq 'entered') 'lock did not admit after release'
}
Test 'Abandoned mutation mutex fails closed for verified recovery' {
 Remove-Item -LiteralPath $ready -Force -ErrorAction SilentlyContinue
 $p=Start-Process powershell.exe -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$abandon,'-Module',$module,'-Root',$root,'-Ready',$ready) -PassThru -WindowStyle Hidden
 $deadline=[DateTime]::UtcNow.AddSeconds(10)
 while(!(Test-Path $ready) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 50}
 Assert (Test-Path $ready) 'abandon holder did not acquire'
 $p.Kill();$p.WaitForExit();$p.Dispose()
 $failed=$false
 try{Invoke-CompanionMutationLocked $root { throw 'abandoned lock entered' }}catch{$failed=$_.Exception.Message -like 'MUTATION_LOCK_ABANDONED*'}
 Assert $failed 'abandoned lock did not fail closed'
}
Write-Output "RESULT: $passed/3 PASS; real two-process Global mutex coverage; no cross-session execution claimed"
} finally {
 Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}
