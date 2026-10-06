$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\PriorBootOwnership.psm1') -Force
$module=Get-Module PriorBootOwnership
$passed=0
function Assert([bool]$Value){if(!$Value){throw 'assertion failed'}}
function Test([string]$Name,[scriptblock]$Body){& $Body;$script:passed++;Write-Output "PASS $Name"}
function Reset([int]$Timeouts=0,[string]$OtherError='') {
 & $module {
  param($timeouts,$other)
  $script:queryCalls=0;$script:delays=@();$script:timeouts=$timeouts;$script:other=$other;$script:partial=$false
  $script:typedBoot=[DateTime]::SpecifyKind([DateTime]'2026-10-01T01:00:00.5',[DateTimeKind]::Utc)
  $script:observations=@([pscustomobject]@{LastBootUpTime=$script:typedBoot})
  function script:Start-Sleep {param($Milliseconds) $script:delays+= $Milliseconds}
  function script:Get-CimInstance {
   param($ClassName,$OperationTimeoutSec,$ErrorAction)
   if($ClassName -cne 'Win32_OperatingSystem' -or $OperationTimeoutSec -ne 10 -or $ErrorAction -cne 'Stop'){throw 'QUERY_BINDING_CHANGED'}
   $script:queryCalls++
   if($script:queryCalls -le $script:timeouts) {
    if($script:partial){[pscustomobject]@{LastBootUpTime=$script:typedBoot.AddDays(-1)}}
    throw [Management.Automation.ErrorRecord]::new([TimeoutException]::new('localized provider timeout'),'HRESULT 0x40004,Microsoft.Management.Infrastructure.CimCmdlets.GetCimInstanceCommand',[Management.Automation.ErrorCategory]::OperationTimeout,$null)
   }
   if($script:other) {
    throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('Timed out'),$script:other,[Management.Automation.ErrorCategory]::NotSpecified,$null)
   }
   $script:observations
  }
 } $Timeouts $OtherError
}
function Query {& $module {Get-WindowsBootUtc}}
function Throws([string]$Code) {$caught=$false;try{Query|Out-Null}catch{Assert ($_.Exception.Message.Contains($Code));$caught=$true};Assert $caught}
function Counts([int]$Calls,[int]$Delays) {Assert (& $module {param($c,$d) $script:queryCalls -eq $c -and $script:delays.Count -eq $d -and @($script:delays|Where-Object {$_ -ne 500}).Count -eq 0} $Calls $Delays)}
Test 'Valid typed boot returns unchanged with one exact native query and no pause' {Reset;$b=Query;Assert ($b -eq (& $module {$script:typedBoot}) -and $b.Kind -eq [DateTimeKind]::Utc);Counts 1 0}
Test 'Actual logon HRESULT timeout then readiness succeeds on the second query' {Reset 1;Query|Out-Null;Counts 2 1}
Test 'Two exact native timeouts can recover on the final permitted query' {Reset 2;Query|Out-Null;Counts 3 2}
Test 'Permanent native timeout fails explicitly after exactly three attempts' {Reset 99;Throws 'RECOVERY_BOOT_QUERY_TIMEOUT';Counts 3 2}
Test 'Localized timeout message without exact native ID never retries' {Reset 0 'unrelated error';Throws 'Timed out';Counts 1 0}
Test 'Same HRESULT from another command never retries' {Reset 0 'HRESULT 0x40004,Microsoft.Management.Infrastructure.CimCmdlets.InvokeCimMethodCommand';Throws 'Timed out';Counts 1 0}
Test 'Access-denied boot query never retries or infers boot' {Reset 0 'HRESULT 0x80070005,Microsoft.Management.Infrastructure.CimCmdlets.GetCimInstanceCommand';Throws 'Timed out';Counts 1 0}
Test 'Successful but empty boot observation remains fail closed' {Reset;& $module {$script:observations=@()};Throws 'RECOVERY_BOOT_UNKNOWN';Counts 1 0}
Test 'Multiple boot records remain ambiguous without retry' {Reset;& $module {$script:observations+= $script:observations[0]};Throws 'RECOVERY_BOOT_UNKNOWN';Counts 1 0}
Test 'Untyped boot timestamp remains fail closed after provider readiness' {Reset 1;& $module {$script:observations=@([pscustomobject]@{LastBootUpTime='2026-10-01T01:00:00Z'})};Throws 'RECOVERY_BOOT_UNKNOWN';Counts 2 1}
Test 'Unspecified boot kind remains fail closed' {Reset;& $module {$script:observations[0].LastBootUpTime=[DateTime]::SpecifyKind($script:typedBoot,[DateTimeKind]::Unspecified)};Throws 'RECOVERY_BOOT_UNKNOWN';Counts 1 0}
Test 'Future boot date remains invalid' {Reset;& $module {$script:observations[0].LastBootUpTime=[DateTime]::UtcNow.AddDays(1)};Throws 'RECOVERY_BOOT_INVALID';Counts 1 0}
Test 'Implausible boot year remains invalid' {Reset;& $module {$script:observations[0].LastBootUpTime=[DateTime]::SpecifyKind([DateTime]'1999-01-01',[DateTimeKind]::Utc)};Throws 'RECOVERY_BOOT_INVALID';Counts 1 0}
Test 'Partial data from a timed-out attempt is discarded before accepting readiness' {Reset 1;& $module {$script:partial=$true};$b=Query;Assert ($b -eq (& $module {$script:typedBoot}));Counts 2 1}
Write-Output ("RESULT: {0}/{0} PASS; native boot observations mocked; no task/process/receipt/credential mutations" -f $passed)
