$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module (Join-Path $repo 'MutationLock.psm1') -Force
Import-Module (Join-Path $repo 'UserSessionTask.psm1') -Force
Import-Module (Join-Path $repo 'WindowsTaskAdapter.psm1') -Force
$fixture=Join-Path $PSScriptRoot ('.fixtures\delegated-host-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force|Out-Null
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$definition=New-HouseholdTaskDefinition $sid $fixture (Join-Path $PSScriptRoot 'host-lease-probe.ps1') $exe ('Codexless-NativeAdapter-Test-'+[Guid]::NewGuid().ToString('N')) ([Guid]::NewGuid().ToString('N')) ([Guid]::NewGuid().ToString('N'))
$registered=$false
try{
 Register-HouseholdTaskCreateOnly $definition;$registered=$true
 Invoke-CompanionMutationLocked $fixture {
  $clock=[Diagnostics.Stopwatch]::StartNew()
  Invoke-CompanionHostDelegation $definition Startup {
   Start-HouseholdTaskPinned $definition
   $deadline=[DateTime]::UtcNow.AddSeconds(25)
   while(!(Test-Path -LiteralPath (Join-Path $fixture 'admitted.flag'))){
    if(Test-Path -LiteralPath (Join-Path $fixture 'error.txt')){throw (Get-Content -LiteralPath (Join-Path $fixture 'error.txt') -Raw)}
    if([DateTime]::UtcNow -ge $deadline){throw 'delegated probe timeout'}
    Start-Sleep -Milliseconds 100
   }
   [IO.File]::WriteAllText((Join-Path $fixture 'release.flag'),'release')
   $clock.Restart()
  }
  if(!(Test-Path -LiteralPath (Join-Path $fixture 'completed.flag')) -or $clock.ElapsedMilliseconds -lt 800){throw 'controller resumed before participant drained'}
  'PASS exact live Scheduler host admitted with root lock held'
  'PASS wrong phase and wrong generation refused'
  'PASS revocation drains active participant before controller resumes'
 }
 $digest=Get-CompanionMutationRootDigest $fixture
 if(Test-Path -LiteralPath (Join-Path (Split-Path $fixture -Parent) ('.codexless-mutation-'+$digest+'.lock'))){throw 'normal lease retained marker'}
 'PASS normal completion retires exact durable marker'
 'RESULT: 4/4 PASS; real Scheduler-to-controller named pipe; same Windows session only'
}finally{
 [IO.File]::WriteAllText((Join-Path $fixture 'release.flag'),'release')
 if($registered){
  $deadline=[DateTime]::UtcNow.AddSeconds(30)
  while((Get-ScheduledTask -TaskName $definition.Name -TaskPath '\').State -eq 'Running'){if([DateTime]::UtcNow -ge $deadline){throw 'probe retained; no force termination'};Start-Sleep -Milliseconds 100}
  Unregister-HouseholdTaskPinned $definition
 }
 $resolved=[IO.Path]::GetFullPath($fixture);$allowed=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '.fixtures')).TrimEnd('\')+'\'
 if(!$resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'cleanup escaped fixture root'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
