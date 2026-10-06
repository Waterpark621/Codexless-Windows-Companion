param([string]$LauncherDirectory,[string]$UserSid,[string]$TaskName,[string]$TransactionId,[string]$GenerationId)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\MutationLock.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\UserSessionTask.psm1') -Force
$definition=New-HouseholdTaskDefinition $UserSid $LauncherDirectory $PSCommandPath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') $TaskName $TransactionId $GenerationId
try{
 $phaseRefused=$false
 try{$bad=Enter-CompanionHostLease $definition Shutdown;$bad.Dispose()}catch{$phaseRefused=$true}
 if(!$phaseRefused){throw 'wrong phase admitted'}
 $wrong=$definition.PSObject.Copy();$wrong.GenerationId=[Guid]::NewGuid().ToString('N')
 $generationRefused=$false
 try{$bad=Enter-CompanionHostLease $wrong Startup;$bad.Dispose()}catch{$generationRefused=$true}
 if(!$generationRefused){throw 'wrong generation admitted'}
 $lease=Enter-CompanionHostLease $definition Startup
 try{
  [IO.File]::WriteAllText((Join-Path $LauncherDirectory 'admitted.flag'),'phase-and-generation-refused;exact-startup-admitted')
  $deadline=[DateTime]::UtcNow.AddSeconds(25)
  while(!(Test-Path -LiteralPath (Join-Path $LauncherDirectory 'release.flag'))){if([DateTime]::UtcNow -ge $deadline){throw 'probe timeout'};Start-Sleep -Milliseconds 50}
  if(Test-Path -LiteralPath (Join-Path $LauncherDirectory 'interrupt.flag')){[Environment]::Exit(73)}
  Start-Sleep -Milliseconds 1000
  [IO.File]::WriteAllText((Join-Path $LauncherDirectory 'completed.flag'),'completed')
 }finally{$lease.Dispose()}
}catch{
 [IO.File]::WriteAllText((Join-Path $LauncherDirectory 'error.txt'),$_.Exception.ToString())
 exit 1
}
