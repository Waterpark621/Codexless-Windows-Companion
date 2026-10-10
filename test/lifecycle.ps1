$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\UserSessionTask.psm1') -Force
# Virtual path/identity unit fixtures; real exclusion is tested separately.
& (Get-Module UserSessionTask) { function script:Invoke-CompanionMutationLocked {param($Root,$Body) & $Body} }
$definition = New-HouseholdTaskDefinition -UserSid 'S-1-5-21-111-222-333-1001' -LauncherDirectory 'C:\Fixture launcher & user\Household' -HostScript 'C:\Fixture supervisor\Task-Host.ps1' -PowerShellExe 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$results = [Collections.Generic.List[object]]::new()
function Assert-True([bool]$Value,[string]$Message='assertion failed') { if (!$Value) { throw $Message } }
function Assert-Throws([scriptblock]$Body,[string]$Code) { try { & $Body | Out-Null } catch { if ($_.Exception.Message.Contains($Code)) { return }; throw }; throw "Expected $Code" }
function Test([string]$Name,[scriptblock]$Body) { & $Body; $results.Add([pscustomobject]@{name=$Name;passed=$true}); Write-Output "PASS $Name" }
function New-Fixture {
    $mock = [pscustomobject]@{ task=$null; starts=0; stops=0; registrations=0; now=[DateTime]'2026-10-03T00:00:00Z'; stopRequested=$false; refuseStop=$false; stopAfterSeconds=0; stopRequestedAt=$null; failDuringStop=$false; state=[pscustomobject]@{taskState='Ready';hostPresent=$false;ownerVerified=$false;piecesVerified=$false;listenerPresent=$false;tunnelPresent=$false;cleanupRequired=$false}; events=[Collections.Generic.List[string]]::new() }
    $adapter = @{
        GetTask = { $mock.task }.GetNewClosure()
        RegisterTask = { param($d) $mock.registrations++;$mock.task=[pscustomobject]@{xml=$d.Xml};$mock.events.Add('register') }.GetNewClosure()
        GetStatus = { $mock.state }.GetNewClosure()
        StartTask = { $mock.starts++;$mock.events.Add('start');$mock.state.taskState='Running';$mock.state.hostPresent=$true;$mock.state.ownerVerified=$true;$mock.state.piecesVerified=$true;$mock.state.listenerPresent=$true;$mock.state.tunnelPresent=$true }.GetNewClosure()
        RequestGracefulStop = { $mock.stops++;$mock.stopRequested=$true;$mock.stopRequestedAt=$mock.now;$mock.events.Add('stop-request') }.GetNewClosure()
        Now = { $mock.now }.GetNewClosure()
        Sleep = { $mock.now=$mock.now.AddSeconds(1); if ($mock.stopRequested -and $mock.failDuringStop) { $mock.state.cleanupRequired=$true;$mock.state.taskState='Ready';$mock.state.hostPresent=$false;$mock.state.listenerPresent=$false;$mock.state.tunnelPresent=$false }; if ($mock.stopRequested -and !$mock.refuseStop -and !$mock.failDuringStop -and ($mock.now-$mock.stopRequestedAt).TotalSeconds -ge $mock.stopAfterSeconds) { $mock.events.Add('children-stopped');$mock.state.taskState='Ready';$mock.state.hostPresent=$false;$mock.state.listenerPresent=$false;$mock.state.tunnelPresent=$false;$mock.state.ownerVerified=$false;$mock.state.piecesVerified=$false;$mock.stopRequested=$false } }.GetNewClosure()
    }
    [pscustomobject]@{ mock=$mock; adapter=$adapter }
}
function Register-Fixture($Fixture) { Invoke-HouseholdLifecycle Register $definition $Fixture.adapter | Out-Null }
function Start-Fixture($Fixture) { Register-Fixture $Fixture; Invoke-HouseholdLifecycle Start $definition $Fixture.adapter | Out-Null }

Test 'Interactive owner, least privilege, singleton, unlimited duration, bounded retry' {
    [xml]$xml=$definition.Xml
    Assert-True ($xml.Task.Principals.Principal.LogonType -eq 'InteractiveToken')
    Assert-True ($xml.Task.Principals.Principal.RunLevel -eq 'LeastPrivilege')
    Assert-True ($xml.Task.Settings.MultipleInstancesPolicy -eq 'IgnoreNew')
    Assert-True ($xml.Task.Settings.ExecutionTimeLimit -eq 'PT0S')
    Assert-True ($xml.Task.Settings.Priority -eq '4')
    Assert-True ($xml.Task.Settings.RestartOnFailure.Count -eq '3')
    Assert-True ($definition.Arguments.Contains('-ExecutionPolicy Bypass'))
    Assert-HouseholdTaskIdentity $definition.Xml $definition
}
Test 'Scheduler export may omit only the four equivalent defaults' {
    [xml]$xml=$definition.Xml
    $ns=New-Object Xml.XmlNamespaceManager($xml.NameTable);$ns.AddNamespace('t','http://schemas.microsoft.com/windows/2004/02/mit/task')
    foreach($xpath in @('/t:Task/t:Principals/t:Principal/t:RunLevel','/t:Task/t:Settings/t:Enabled','/t:Task/t:Settings/t:RunOnlyIfNetworkAvailable','/t:Task/t:Triggers/t:LogonTrigger/t:Enabled')) {
        $node=$xml.SelectSingleNode($xpath,$ns);$null=$node.ParentNode.RemoveChild($node)
        Assert-HouseholdTaskIdentity $xml.OuterXml $definition
    }
}
Test 'Explicit elevated disabled network-only or disabled-trigger values still reject' {
    foreach($case in @(
        @{path='/t:Task/t:Principals/t:Principal/t:RunLevel';value='HighestAvailable'},
        @{path='/t:Task/t:Settings/t:Enabled';value='false'},
        @{path='/t:Task/t:Settings/t:RunOnlyIfNetworkAvailable';value='true'},
        @{path='/t:Task/t:Triggers/t:LogonTrigger/t:Enabled';value='false'})) {
        [xml]$xml=$definition.Xml
        $ns=New-Object Xml.XmlNamespaceManager($xml.NameTable);$ns.AddNamespace('t','http://schemas.microsoft.com/windows/2004/02/mit/task')
        $xml.SelectSingleNode($case.path,$ns).InnerText=$case.value
        Assert-Throws {Assert-HouseholdTaskIdentity $xml.OuterXml $definition} 'TASK_IDENTITY_MISMATCH'
    }
}
Test 'Omission of other safety fields is never accepted as an equivalent default' {
    foreach($xpath in @('/t:Task/t:Settings/t:AllowHardTerminate','/t:Task/t:Settings/t:ExecutionTimeLimit','/t:Task/t:Principals/t:Principal/t:LogonType','/t:Task/t:Actions/t:Exec/t:Arguments')) {
        [xml]$xml=$definition.Xml
        $ns=New-Object Xml.XmlNamespaceManager($xml.NameTable);$ns.AddNamespace('t','http://schemas.microsoft.com/windows/2004/02/mit/task')
        $node=$xml.SelectSingleNode($xpath,$ns);$null=$node.ParentNode.RemoveChild($node)
        Assert-Throws {Assert-HouseholdTaskIdentity $xml.OuterXml $definition} 'TASK_IDENTITY_MISMATCH'
    }
}
Test 'Scheduler account-name export must resolve to the exact owner SID' {
    $current=[Security.Principal.WindowsIdentity]::GetCurrent()
    $ownerDefinition=New-HouseholdTaskDefinition $current.User.Value $definition.LauncherDirectory $definition.HostScript $definition.PowerShellExe
    [xml]$xml=$ownerDefinition.Xml
    $ns=New-Object Xml.XmlNamespaceManager($xml.NameTable);$ns.AddNamespace('t','http://schemas.microsoft.com/windows/2004/02/mit/task')
    foreach($xpath in @('/t:Task/t:Principals/t:Principal/t:UserId','/t:Task/t:Triggers/t:LogonTrigger/t:UserId')) {$xml.SelectSingleNode($xpath,$ns).InnerText=$current.Name}
    Assert-HouseholdTaskIdentity $xml.OuterXml $ownerDefinition
    $xml.SelectSingleNode('/t:Task/t:Triggers/t:LogonTrigger/t:UserId',$ns).InnerText='NT AUTHORITY\SYSTEM'
    Assert-Throws {Assert-HouseholdTaskIdentity $xml.OuterXml $ownerDefinition} 'TASK_IDENTITY_MISMATCH'
}
Test 'Escaping preserves exact paths with spaces and ampersand' {
    [xml]$xml=$definition.Xml
    Assert-True ($xml.Task.Actions.Exec.WorkingDirectory -ceq 'C:\Fixture launcher & user\Household')
    Assert-True ($xml.Task.Actions.Exec.Arguments.Contains('"C:\Fixture supervisor\Task-Host.ps1"'))
}
Test 'Invalid network/relative paths and nonuser SID fail closed' {
    Assert-Throws { New-HouseholdTaskDefinition 'S-1-5-18' 'C:\x' 'C:\host' 'C:\ps' } 'TASK_OWNER_INVALID'
    Assert-Throws { New-HouseholdTaskDefinition $definition.UserSid 'relative' 'C:\host' 'C:\ps' } 'TASK_PATH_INVALID'
    Assert-Throws { New-HouseholdTaskDefinition $definition.UserSid '\\server\share' 'C:\host' 'C:\ps' } 'TASK_PATH_INVALID'
}
Test 'Inherited user profile cannot register a task under the sandbox identity' {
    Assert-HouseholdPrincipal $definition.UserSid $definition.UserSid
    Assert-Throws { Assert-HouseholdPrincipal 'S-1-5-21-111-222-333-1004' $definition.UserSid } 'TASK_OWNER_INVALID'
}
Test 'Repeated registration does not replace an existing task' {
    $f=New-Fixture; Register-Fixture $f; Register-Fixture $f
    Assert-True ($f.mock.registrations -eq 1 -and $f.mock.starts -eq 0)
}
Test 'Same task name with wrong owner or action is never modified' {
    foreach ($bad in @($definition.Xml.Replace('InteractiveToken','ServiceAccount'),$definition.Xml.Replace('Task-Host.ps1','Other.ps1'),$definition.Xml.Replace('IgnoreNew','Parallel'),$definition.Xml.Replace('<Enabled>true</Enabled>','<Enabled>false</Enabled>'))) {
        $f=New-Fixture;$f.mock.task=[pscustomobject]@{xml=$bad}
        Assert-Throws { Invoke-HouseholdLifecycle Register $definition $f.adapter } 'TASK_IDENTITY_MISMATCH'
        Assert-True ($f.mock.registrations -eq 0 -and $f.mock.starts -eq 0 -and $f.mock.stops -eq 0)
    }
}
Test 'Concurrent/repeated start preserves one household and tunnel set' {
    $f=New-Fixture; Start-Fixture $f; Invoke-HouseholdLifecycle Start $definition $f.adapter | Out-Null
    Assert-True ($f.mock.starts -eq 1 -and $f.mock.stops -eq 0)
}
Test 'Legacy household blocks startup instead of being adopted' {
    $f=New-Fixture; Register-Fixture $f;$f.mock.state.hostPresent=$true
    Assert-Throws { Invoke-HouseholdLifecycle Start $definition $f.adapter } 'HOUSEHOLD_MIGRATION_REQUIRED'
    Assert-True ($f.mock.starts -eq 0)
}
Test 'Foreign localhost listener blocks duplicate household' {
    $f=New-Fixture;Register-Fixture $f;$f.mock.state.listenerPresent=$true
    Assert-Throws { Invoke-HouseholdLifecycle Start $definition $f.adapter } 'HOUSEHOLD_MIGRATION_REQUIRED'
}
Test 'Existing tunnel prevents competing alias clients' {
    $f=New-Fixture;Register-Fixture $f;$f.mock.state.tunnelPresent=$true
    Assert-Throws { Invoke-HouseholdLifecycle Start $definition $f.adapter } 'HOUSEHOLD_MIGRATION_REQUIRED'
    Assert-True ($f.mock.starts -eq 0 -and $f.mock.stops -eq 0)
}
Test 'Graceful stop waits for all owned processes without force kill' {
    $f=New-Fixture;Start-Fixture $f;Invoke-HouseholdLifecycle Stop $definition $f.adapter | Out-Null
    Assert-True ($f.mock.stops -eq 1 -and !$f.mock.state.hostPresent -and !$f.mock.state.tunnelPresent)
    Assert-True ($f.mock.events.Contains('children-stopped'))
}
Test 'Restart starts only after household and tunnels finish stopping' {
    $f=New-Fixture;Start-Fixture $f;Invoke-HouseholdLifecycle Restart $definition $f.adapter | Out-Null
    Assert-True ($f.mock.starts -eq 2 -and $f.mock.stops -eq 1)
    Assert-True (($f.mock.events -join ',') -eq 'register,start,stop-request,children-stopped,start')
}
Test 'Stop timeout fails visibly without restarting or killing anything' {
    $f=New-Fixture;Start-Fixture $f;$f.mock.refuseStop=$true
    Assert-Throws { Invoke-HouseholdLifecycle Restart $definition $f.adapter -TimeoutSeconds 2 } 'HOUSEHOLD_STOP_TIMEOUT'
    Assert-True ($f.mock.starts -eq 1 -and $f.mock.stops -eq 1 -and $f.mock.state.hostPresent)
}
Test 'Default controller observation budget allows cooperative stop beyond 60 seconds' {
    $f=New-Fixture;Start-Fixture $f;$f.mock.stopAfterSeconds=105
    $before=$f.mock.now
    $result=Invoke-HouseholdLifecycle Stop $definition $f.adapter
    Assert-True ($result.state -eq 'stopped' -and ($f.mock.now-$before).TotalSeconds -eq 105)
}
Test 'Degraded cleanup blocks startup before the already-running result' {
    $f=New-Fixture;Start-Fixture $f;$f.mock.state.cleanupRequired=$true
    Assert-Throws { Invoke-HouseholdLifecycle Start $definition $f.adapter } 'HOUSEHOLD_CLEANUP_DEGRADED'
    Assert-True ($f.mock.starts -eq 1)
}
Test 'Retained cleanup evidence prevents Stop or Restart reporting stopped while pieces appear absent' {
    $f=New-Fixture;Register-Fixture $f;$f.mock.state.cleanupRequired=$true
    foreach ($action in @('Stop','Restart')) { Assert-Throws { Invoke-HouseholdLifecycle $action $definition $f.adapter } 'HOUSEHOLD_CLEANUP_DEGRADED' }
    Assert-True ($f.mock.starts -eq 0 -and $f.mock.stops -eq 0)
}
Test 'Cleanup failure appearing during observation blocks restart before the stopped-success branch' {
    $f=New-Fixture;Start-Fixture $f;$f.mock.failDuringStop=$true
    Assert-Throws { Invoke-HouseholdLifecycle Restart $definition $f.adapter } 'HOUSEHOLD_CLEANUP_DEGRADED'
    Assert-True ($f.mock.starts -eq 1 -and $f.mock.stops -eq 1)
}
Test 'Foreign/reused host ownership prevents shutdown' {
    $f=New-Fixture;Start-Fixture $f;$f.mock.state.ownerVerified=$false
    Assert-Throws { Invoke-HouseholdLifecycle Stop $definition $f.adapter } 'HOUSEHOLD_FOREIGN_OWNER'
    Assert-True ($f.mock.stops -eq 0)
}
Test 'Foreign wrapper or tunnel identity prevents shutdown' {
    $f=New-Fixture;Start-Fixture $f;$f.mock.state.piecesVerified=$false
    Assert-Throws { Invoke-HouseholdLifecycle Stop $definition $f.adapter } 'HOUSEHOLD_FOREIGN_OWNER'
    Assert-True ($f.mock.stops -eq 0)
}
Test 'PID receipt validates creation time, SID, script, task, and executable' {
    $receipt=[pscustomobject]@{version=1;pid=123;createdAt='2026-10-03T00:00:00.0000000Z';userSid=$definition.UserSid;taskName=$definition.Name;hostScript=$definition.HostScript;launcherDirectory=$definition.LauncherDirectory}
    $process=[pscustomobject]@{pid=123;createdAt=$receipt.createdAt;userSid=$receipt.userSid;executable=$definition.PowerShellExe;commandLine=('powershell -File "'+$definition.HostScript+'"')}
    Assert-True (Test-HouseholdOwnerIdentity $receipt $process $definition)
    foreach ($field in @('createdAt','userSid','executable','commandLine')) { $clone=$process.PSObject.Copy();$clone.$field='unrelated';Assert-True (!(Test-HouseholdOwnerIdentity $receipt $clone $definition)) }
}
Test 'Status is read-only and keeps degraded state visible' {
    $f=New-Fixture;Register-Fixture $f;Start-Fixture $f;$f.mock.state.listenerPresent=$false
    $state=Invoke-HouseholdLifecycle Status $definition $f.adapter
    Assert-True (!$state.listenerPresent -and $f.mock.starts -eq 1 -and $f.mock.stops -eq 0)
}
Test 'Direct Desktop tool launch cannot masquerade as scheduler-owned host' {
    $child=[pscustomobject]@{pid=101;parentPid=100;createdAt='2026-10-03T00:00:01.0000000Z'}
    $parent=[pscustomobject]@{pid=100;createdAt='2026-10-03T00:00:00.0000000Z';executable='C:\Desktop\codex.exe';microsoftSigned=$true}
    $service=[pscustomobject]@{State='Running';ProcessId=50}
    Assert-True (!(Test-TaskSchedulerAncestry $child $parent $service 'C:\Windows\System32'))
    $parent.executable='C:\untrusted\taskeng.exe'
    Assert-True (!(Test-TaskSchedulerAncestry $child $parent $service 'C:\Windows\System32'))
    $parent.executable='C:\Windows\System32\svchost.exe'
    Assert-True (!(Test-TaskSchedulerAncestry $child $parent $service 'C:\Windows\System32'))
    $service.ProcessId=100
    Assert-True (Test-TaskSchedulerAncestry $child $parent $service 'C:\Windows\System32')
    $parent.executable='C:\Windows\System32\taskeng.exe'
    Assert-True (Test-TaskSchedulerAncestry $child $parent $service 'C:\Windows\System32')
    $parent.executable='C:\Windows\System32\taskhostw.exe'
    Assert-True (Test-TaskSchedulerAncestry $child $parent $service 'C:\Windows\System32')
    $parent.microsoftSigned=$false
    Assert-True (!(Test-TaskSchedulerAncestry $child $parent $service 'C:\Windows\System32'))
    $parent.microsoftSigned=$true
    $parent.createdAt='2026-10-03T00:00:02.0000000Z'
    Assert-True (!(Test-TaskSchedulerAncestry $child $parent $service 'C:\Windows\System32'))
}
Test 'No task API is required or called by unit-test adapters' {
    $f=New-Fixture;Start-Fixture $f
    Assert-True ($f.mock.events.Count -eq 2)
}
Test 'Verified prior-boot preflight permits only scheduling, leaving retirement to task owner' {
    $fixture=New-Fixture;Register-Fixture $fixture
    $fixture.mock.state.cleanupRequired=$true
    $fixture.adapter.CanRecoverPriorBoot={ $true }
    $result=Invoke-HouseholdLifecycle Start $definition $fixture.adapter
    Assert-True ($result.state -ceq 'starting' -and $fixture.mock.starts -eq 1 -and $fixture.mock.stops -eq 0 -and $fixture.mock.state.cleanupRequired)
}
Test 'Same-boot or incomplete preflight cannot schedule a replacement' {
    $fixture=New-Fixture;Register-Fixture $fixture
    $fixture.mock.state.cleanupRequired=$true
    $fixture.adapter.CanRecoverPriorBoot={ $false }
    Assert-Throws {Invoke-HouseholdLifecycle Start $definition $fixture.adapter} 'HOUSEHOLD_CLEANUP_DEGRADED'
    Assert-True ($fixture.mock.starts -eq 0 -and $fixture.mock.stops -eq 0)
}
Test 'Running degraded owner never invokes prior-boot preflight' {
    $fixture=New-Fixture;Start-Fixture $fixture
    $fixture.mock.state.cleanupRequired=$true
    $fixture.adapter.CanRecoverPriorBoot={ throw 'must not call' }
    Assert-Throws {Invoke-HouseholdLifecycle Start $definition $fixture.adapter} 'HOUSEHOLD_CLEANUP_DEGRADED'
    Assert-True ($fixture.mock.starts -eq 1)
}
Test 'Logon trigger and availability behavior remain unchanged' {
    [xml]$xml=$definition.Xml
    Assert-True ($xml.Task.Triggers.LogonTrigger.UserId -ceq $definition.UserSid -and $xml.Task.Triggers.LogonTrigger.Enabled -ceq 'true' -and $xml.Task.Settings.StartWhenAvailable -ceq 'true')
}
Test 'Start displays the sanitized recovery reason without scheduling a replacement' {
    $fixture=New-Fixture;Register-Fixture $fixture
    $fixture.mock.state.cleanupRequired=$true
    $fixture.mock.state|Add-Member NoteProperty priorBootRecoveryReason 'RECOVERY_SAME_BOOT'
    $fixture.adapter.CanRecoverPriorBoot={$false}
    $caught=$false
    try{Invoke-HouseholdLifecycle Start $definition $fixture.adapter}catch{Assert-True ($_.Exception.Message -clike '*Reason: RECOVERY_SAME_BOOT');$caught=$true}
    Assert-True ($caught -and $fixture.mock.starts -eq 0)
}
Test 'Start never prints malformed recovery diagnostic text' {
    $fixture=New-Fixture;Register-Fixture $fixture
    $fixture.mock.state.cleanupRequired=$true
    $fixture.mock.state|Add-Member NoteProperty priorBootRecoveryReason "RECOVERY_SAME_BOOT`nprivate-provider-data"
    $fixture.adapter.CanRecoverPriorBoot={$false}
    $caught=$false
    try{Invoke-HouseholdLifecycle Start $definition $fixture.adapter}catch{Assert-True ($_.Exception.Message -cnotlike '*private-provider-data*');$caught=$true}
    Assert-True ($caught -and $fixture.mock.starts -eq 0)
}
Test 'Start uses the final preflight reason when observations change after Status' {
    $fixture=New-Fixture;Register-Fixture $fixture
    $fixture.mock.state.cleanupRequired=$true
    $fixture.mock.state|Add-Member NoteProperty priorBootRecoveryReason 'RECOVERY_SAME_BOOT'
    $fixture.adapter.CanRecoverPriorBoot={$false}
    $fixture.adapter.RecoveryFailureReason={'RECOVERY_LISTENER_PRESENT'}
    $caught=$false
    try{Invoke-HouseholdLifecycle Start $definition $fixture.adapter}catch{Assert-True ($_.Exception.Message -clike '*Reason: RECOVERY_LISTENER_PRESENT');$caught=$true}
    Assert-True ($caught -and $fixture.mock.starts -eq 0)
}
Write-Output ("RESULT: {0}/{0} PASS; all task/process operations mocked" -f $results.Count)
