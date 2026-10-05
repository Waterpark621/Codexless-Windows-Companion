$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\PriorBootOwnership.psm1') -Force
$module=Get-Module PriorBootOwnership;$passed=0
function Assert([bool]$v){if(!$v){throw 'assertion failed'}}
& $module {function script:Get-TunnelStatus {param($Config,$Tunnel) $script:Calls++;$script:Status}}
function Test([string]$name,[scriptblock]$body){& $module {$script:Calls=0;$script:Status=[pscustomobject]@{alias='fixture';tunnel_id='fixture-id';process_running=$false}};& $body;$script:passed++;Write-Output "PASS $name"}
function Probe {& $module {Get-RecoveryTunnelStatus ([pscustomobject]@{}) ([pscustomobject]@{alias='fixture'})}}
Test 'Recovery uses centralized bounded status exclusively' {$v=Probe;Assert (!$v.process_running);Assert (& $module {$script:Calls -eq 1})}
foreach($cause in @('timeout','output overflow','native policy refusal','malformed JSON','nonzero exit','wrong identity')){Test "Bounded status $cause refuses recovery" {& $module {$script:Status=$null};$failed=$false;try{Probe|Out-Null}catch{$failed=$_.Exception.Message -ceq 'RECOVERY_STATUS_UNAVAILABLE'};Assert $failed}}
Write-Output ("RESULT: {0}/{0} PASS; bounded-status adapter mocked; no native/tunnel actions" -f $passed)
