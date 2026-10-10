$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$fixtureBase=Join-Path $PSScriptRoot '.fixtures'
$fixtureDirectory=Join-Path $fixtureBase ('doctor binding '+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $fixtureDirectory
$childPath=Join-Path $fixtureDirectory 'check.ps1'
$doctorText=@'
param([string]$InstallDirectory,[switch]$Json)
$expected=Split-Path $PSCommandPath -Parent
$accepted=($InstallDirectory -ceq $expected -and !(Test-Path -LiteralPath (Join-Path $expected 'doctor-fail')))
[pscustomobject]@{ok=$accepted;verdict=$(if($accepted){'PASS'}else{'FAIL'})}|ConvertTo-Json
if(!$accepted){exit 1}
exit 0
'@
[IO.File]::WriteAllText((Join-Path $fixtureDirectory 'Doctor.ps1'),$doctorText)
$childText=@'
param([string]$Repo,[string]$Destination,[string]$Scenario)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if($Scenario -ceq 'decoy'){$global:root=Join-Path $Destination 'unrelated-parent'}
$module=Import-Module (Join-Path $Repo 'PublicInstall.psm1') -PassThru -DisableNameChecking
$answer=&$module {
 param($target,$scenario)
 function Invoke-ExactDoctor([string]$selected,[string]$mode) {
  $root=$selected
  $services=New-PublicInstallServices
  $nativeReady={param($g,$r) $true}
  if($mode -ceq 'native-fail'){$nativeReady={param($g,$r) $false}}
  Invoke-CompanionMutationLocked $root {
   $callback=New-PublicInstallReadinessVerifier $nativeReady $services.Doctor $root
   &$callback $selected $null
  }
 }
 Invoke-ExactDoctor $target $scenario
} $Destination $Scenario
$expected=($Scenario -ceq 'normal' -or $Scenario -ceq 'decoy')
if($answer -ne $expected){throw 'DOCTOR_DESTINATION_CAPTURE_FAILED'}
'@
[IO.File]::WriteAllText($childPath,$childText)
$passed=0
try {
 foreach($scenario in @('normal','decoy','doctor-fail','native-fail')){
  if($scenario -ceq 'doctor-fail'){[IO.File]::WriteAllText((Join-Path $fixtureDirectory 'doctor-fail'),'fixture')}
  if($scenario -ceq 'native-fail'){
   # A failed native check must return before launching even this invalid Doctor.
   [IO.File]::WriteAllText((Join-Path $fixtureDirectory 'Doctor.ps1'),"throw 'DOCTOR_MUST_NOT_RUN'")
  }
  &$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File $childPath -Repo $repo -Destination $fixtureDirectory -Scenario $scenario
  if($LASTEXITCODE -ne 0){throw ('FRESH_DOCTOR_BOUNDARY_FAILED_'+$scenario)}
  $passed++
  Write-Output ('PASS fresh default Doctor callback '+$scenario)
 }
}finally{
 $resolved=[IO.Path]::GetFullPath($fixtureDirectory)
 if(!$resolved.StartsWith([IO.Path]::GetFullPath($fixtureBase)+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'FIXTURE_CLEANUP_PATH_INVALID'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Output ('RESULT: '+$passed+'/'+$passed+' PASS')
