$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\WindowsTaskAdapter.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\UserSessionTask.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\GenerationIdentity.psm1') -Force
$module=Get-Module WindowsTaskAdapter
$fixture=Join-Path $PSScriptRoot ('.fixtures\owner-unavailable-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
$sid='S-1-5-21-111-222-333-1001'
$def=New-HouseholdTaskDefinition $sid $fixture (Join-Path $fixture 'Task-Host.ps1') 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
'{}' | Set-Content -LiteralPath (Join-Path $fixture 'settings.json')
$cfg=[pscustomobject]@{settingsPath=(Join-Path $fixture 'settings.json');projectPath=$fixture;codexlessRoot=$fixture;nodeExe='C:\fixture\node.exe';nodeSha256=('a'*64);launchScript='C:\fixture\launch.mjs';profileDir=$fixture;port=7690;tunnelExe=$null;tunnels=@();release=[pscustomobject]@{version='fixture';buildId=('b'*64);sourceRevision=('c'*40);manifestSha256=('d'*64);hostContractVersion='codexless-public-preview-v1'}}
$receipt=[pscustomobject]@{version=1;pid=101;createdAt='2026-10-03T00:00:00.0000000Z';userSid=$sid;taskName=$def.Name;hostScript=$def.HostScript;launcherDirectory=$fixture;generationContract=(Get-CompanionGenerationContract $cfg)}
$receipt | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $fixture 'task-owner.json')
'101' | Set-Content -LiteralPath (Join-Path $fixture 'host.pid')
& $module {
    param($sid,$def,$cfg)
    $script:cfg=$cfg
    function script:Get-CompanionConfig {param($CompanionRoot) $script:cfg}
    function script:Test-TcpPort {param($Port) $false}
    function script:Get-ConfiguredTunnels {param($Config,[switch]$IncludeDisabled) @()}
    function script:Invoke-PriorBootOwnership {param($Definition,[switch]$CheckOnly) throw 'INCOMPLETE_PROOF'}
    $script:sid=$sid; $script:def=$def; $script:ownerCalls=0
    $script:denyPid=101; $script:providerFailure=$false
    function script:Get-ScheduledTask { param($TaskName,$TaskPath,$ErrorAction) [pscustomobject]@{State='Ready'} }
    function script:Get-CimInstance {
        param($ClassName,$Filter,$ErrorAction)
        if($script:providerFailure){throw 'PROVIDER_FAILURE'}
        $id=[int]($Filter -replace 'ProcessId=','')
        [pscustomobject]@{ProcessId=$id;ParentProcessId=1;ExecutablePath=$script:def.PowerShellExe;CommandLine=('powershell -File "'+$script:def.HostScript+'"');CreationDate=[DateTime]::Parse('2026-10-03T00:00:00Z').ToUniversalTime()}
    }
    function script:Invoke-CimMethod {
        param($InputObject,$MethodName,$ErrorAction)
        if($MethodName -cne 'GetOwnerSid'){throw 'wrong method'}
        $script:ownerCalls++
        if($InputObject.ProcessId -eq $script:denyPid){return [pscustomobject]@{ReturnValue=2;Sid=$null}}
        [pscustomobject]@{ReturnValue=0;Sid=$script:sid}
    }
} $sid $def $cfg
$passed=0
function Assert([bool]$Value){if(!$Value){throw 'assertion failed'}}
function Test([string]$Name,[scriptblock]$Body){& $Body;$script:passed++;Write-Output "PASS $Name"}
Test 'Exact identity verifier still throws PROCESS_OWNER_UNAVAILABLE for GetOwnerSid return 2' {
    $caught=$false
    try{Get-ProcessIdentity 101 | Out-Null}catch{Assert ($_.Exception.Message -ceq 'PROCESS_OWNER_UNAVAILABLE');$caught=$true}
    Assert $caught
}
Test 'Status converts the actual owner-query failure to explicit incomplete degraded JSON' {
    $before=@(Get-ChildItem -LiteralPath $fixture -File | Sort-Object Name | ForEach-Object {[IO.File]::ReadAllText($_.FullName)}) -join "`n"
    $state=Get-HouseholdRuntimeState $def
    Assert (!$state.ownerVerified -and !$state.piecesVerified -and $state.cleanupRequired)
    Assert (!$state.observationComplete -and $state.identityError -ceq 'PROCESS_OWNER_UNAVAILABLE')
    Assert ($null -eq $state.hostPresent -and $null -eq $state.listenerPresent -and $null -eq $state.tunnelPresent)
    Assert (($state | ConvertTo-Json -Depth 5 | ConvertFrom-Json).cleanupState.requiresVerifiedRecovery)
    Assert (& $module {$script:ownerCalls -eq 2})
    Assert ($before -ceq (@(Get-ChildItem -LiteralPath $fixture -File | Sort-Object Name | ForEach-Object {[IO.File]::ReadAllText($_.FullName)}) -join "`n"))
}
foreach($action in @('Start','Stop','Restart')) {
    Test "$action refuses unavailable ownership without any mutation" {
        $adapter=@{
            GetTask={ [pscustomobject]@{xml=$def.Xml} }.GetNewClosure()
            GetStatus={ Get-HouseholdRuntimeState $def }.GetNewClosure()
            CanRecoverPriorBoot={ $false }
            StartTask={throw 'UNEXPECTED_START'}
            RequestGracefulStop={throw 'UNEXPECTED_STOP'}
        }
        $caught=$false
        try{Invoke-HouseholdLifecycle $action $def $adapter | Out-Null}catch{Assert ($_.Exception.Message -like 'HOUSEHOLD_CLEANUP_DEGRADED:*');$caught=$true}
        Assert $caught
    }
}
Test 'Unavailable wrapper owner is also degraded after the host owner verifies' {
    & $module {$script:denyPid=102}
    '102' | Set-Content -LiteralPath (Join-Path $fixture 'codexless.pid')
    $state=Get-HouseholdRuntimeState $def
    Assert ($state.identityError -ceq 'PROCESS_OWNER_UNAVAILABLE' -and $state.cleanupRequired -and !$state.piecesVerified)
}
Test 'Unrelated provider errors remain visible and are not suppressed' {
    & $module {$script:providerFailure=$true}
    $caught=$false
    try{Get-HouseholdRuntimeState $def | Out-Null}catch{Assert ($_.Exception.Message -ceq 'PROVIDER_FAILURE');$caught=$true}
    Assert $caught
}
Test 'Only complete prior-boot preflight can enable controller Start after foreign owner-query failure' {
    & $module {
        $script:providerFailure=$false;$script:denyPid=102
        function script:Invoke-PriorBootOwnership {param($Definition,[switch]$CheckOnly) if(!$CheckOnly){throw 'MUTATION_FORBIDDEN'}}
    }
    $state=Get-HouseholdRuntimeState $def
    Assert ($state.taskState -ceq 'Ready' -and $state.priorBootRecoveryAvailable -and $state.cleanupRequired)
    Assert (!$state.ownerVerified -and !$state.piecesVerified -and !$state.hostPresent -and !$state.listenerPresent -and !$state.tunnelPresent)
    $adapter=@{
        GetTask={ [pscustomobject]@{xml=$def.Xml} }.GetNewClosure()
        GetStatus={Get-HouseholdRuntimeState $def}.GetNewClosure()
        CanRecoverPriorBoot={$true}
        StartTask={}
    }
    $result=Invoke-HouseholdLifecycle Start $def $adapter
    Assert ($result.state -ceq 'starting')
}
Test 'Running task never receives the prior-boot controller absence projection' {
    & $module { function script:Get-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction) [pscustomobject]@{State='Running'}} }
    $state=Get-HouseholdRuntimeState $def
    Assert ($state.taskState -ceq 'Running' -and $null -eq $state.hostPresent -and !$state.ownerVerified -and $state.cleanupRequired)
    Assert (!$state.PSObject.Properties['priorBootRecoveryAvailable'])
}
Test 'Failed read-only recovery publishes only a sanitized reason in Status' {
    & $module {
        function script:Get-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction) [pscustomobject]@{State='Ready'}}
        function script:Invoke-PriorBootOwnership {param($Definition,[switch]$CheckOnly)
            $failure=[InvalidOperationException]::new('private-provider-data')
            $failure.Data['RecoveryReasonCode']='RECOVERY_SAME_BOOT'
            throw $failure
        }
    }
    $state=Get-HouseholdRuntimeState $def
    Assert ($state.priorBootRecoveryReason -ceq 'RECOVERY_SAME_BOOT')
    Assert (($state|ConvertTo-Json -Depth 5) -cnotmatch 'private-provider-data')
    Assert (!$state.PSObject.Properties['priorBootRecoveryAvailable'])
}
Write-Output ("RESULT: {0}/{0} PASS; exact verifier exercised; native observations mocked; no production mutations" -f $passed)
