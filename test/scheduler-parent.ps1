$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\WindowsTaskAdapter.psm1') -Force
$module=Get-Module WindowsTaskAdapter
& $module {
    function script:Get-CimInstance {
        param($ClassName,$Filter,$ErrorAction)
        if($script:CimDenied){throw 'CIM_DENIED'}
        if($ClassName -ceq 'Win32_Service') {
            $script:ServiceQueries++
            $result=$script:ServiceFixture.PSObject.Copy()
            if($script:ServiceChanges -and $script:ServiceQueries -gt 1){$result.ProcessId=99}
        } else {
            $script:ProcessQueries++
            $result=$script:ParentFixture.PSObject.Copy()
            if($script:ProcessChanges -and $script:ProcessQueries -gt 1){$result.CreationDate=$result.CreationDate.AddSeconds(1)}
        }
        $result
    }
    function script:Invoke-CimMethod { param($InputObject,$MethodName,$ErrorAction) $script:OwnerQueries++; [pscustomobject]@{ReturnValue=2;Sid=$null} }
    function script:Get-AuthenticodeSignature { param($LiteralPath,$ErrorAction) $script:SignatureQueries++;$script:SignatureFixture }
}
$passed=0
function Reset-Fixture {
    & $module {
        $image=Join-Path $env:SystemRoot 'System32\svchost.exe'
        $script:ParentFixture=[pscustomobject]@{ProcessId=10;Name='svchost.exe';ParentProcessId=1;ExecutablePath=$null;CommandLine='fixture';CreationDate=[DateTime]'2026-10-03T00:00:00Z'}
        $script:ServiceFixture=[pscustomobject]@{Name='Schedule';ProcessId=10;State='Running';StartName='LocalSystem';PathName=($image+' -k netsvcs -p')}
        $script:SignatureFixture=[pscustomobject]@{Status='Valid';SignerCertificate=[pscustomobject]@{Subject='CN=Microsoft Windows, O=Microsoft Corporation, C=US'}}
        $script:OwnerQueries=0;$script:ServiceQueries=0;$script:SignatureQueries=0;$script:ProcessQueries=0
        $script:CimDenied=$false;$script:ServiceChanges=$false;$script:ProcessChanges=$false
    }
}
function Test([string]$Name,[scriptblock]$Body) { Reset-Fixture;& $Body;$script:passed++;Write-Output "PASS $Name" }
function Assert([bool]$Value) { if(!$Value){throw 'Assertion failed'} }
function Assert-Rejected {
    $failed=$false
    try {$null=Get-TaskSchedulerParentIdentity 10}catch {$failed=$_.Exception.Message -like 'TASK_SCHEDULER_PARENT_UNVERIFIED:*'}
    Assert $failed
}
Test 'Direct parent image query does not request SYSTEM owner SID' {
    & $module {$script:ParentFixture.ExecutablePath=Join-Path $env:SystemRoot 'System32\svchost.exe'}
    $parent=Get-TaskSchedulerParentIdentity 10
    Assert ($parent.pid -eq 10 -and $parent.identitySource -ceq 'cim')
    Assert ((& $module {$script:OwnerQueries}) -eq 0 -and (& $module {$script:ServiceQueries}) -eq 0)
}
Test 'Protected parent uses exact repeated SCM binding and signed image' {
    $parent=Get-TaskSchedulerParentIdentity 10
    Assert ($parent.identitySource -ceq 'scm' -and $parent.serviceRechecked -eq $true -and $parent.createdAt -ceq '2026-10-03T00:00:00.0000000Z')
    Assert ((& $module {$script:OwnerQueries}) -eq 0 -and (& $module {$script:ServiceQueries}) -eq 2 -and (& $module {$script:SignatureQueries}) -eq 1)
}
Test 'Quoted SCM binary path is accepted without command execution' {
    & $module {$script:ServiceFixture.PathName='"'+(Join-Path $env:SystemRoot 'System32\svchost.exe')+'" -k netsvcs -p'}
    Assert ((Get-TaskSchedulerParentIdentity 10).identitySource -ceq 'scm')
}
Test 'Different Schedule PID rejects the parent' { & $module {$script:ServiceFixture.ProcessId=11};Assert-Rejected }
Test 'Service outside LocalSystem rejects the parent' { & $module {$script:ServiceFixture.StartName='fixture-user'};Assert-Rejected }
Test 'Stopped service rejects the parent' { & $module {$script:ServiceFixture.State='Stopped'};Assert-Rejected }
Test 'Different process image name rejects the parent' { & $module {$script:ParentFixture.Name='fixture.exe'};Assert-Rejected }
Test 'Different service binary rejects the parent' { & $module {$script:ServiceFixture.PathName='C:\untrusted\svchost.exe'};Assert-Rejected }
Test 'Unsigned service binary rejects the parent' { & $module {$script:SignatureFixture.Status='NotSigned'};Assert-Rejected }
Test 'Non-Microsoft signer rejects the parent' { & $module {$script:SignatureFixture.SignerCertificate.Subject='O=Fixture'};Assert-Rejected }
Test 'Changed service PID during verification rejects the parent' { & $module {$script:ServiceChanges=$true};Assert-Rejected }
Test 'Reused parent PID creation time rejects the parent' { & $module {$script:ProcessChanges=$true};Assert-Rejected }
Test 'Unavailable process creation time rejects the parent' { & $module {$script:ParentFixture.CreationDate=$null};Assert-Rejected }
Test 'Unavailable process metadata rejects bare service PID proof' { & $module {$script:CimDenied=$true};Assert-Rejected }
Test 'Invalid parent PID does not query processes' {
    Assert ($null -eq (Get-TaskSchedulerParentIdentity 0))
    Assert ((& $module {$script:ProcessQueries}) -eq 0)
}
Test 'Owned process identity still requires its actual SID' {
    $failed=$false
    try {$null=Get-ProcessIdentity 10}catch {$failed=$_.Exception.Message -ceq 'PROCESS_OWNER_UNAVAILABLE'}
    Assert $failed
    Assert ((& $module {$script:OwnerQueries}) -eq 1)
}
Write-Output ("RESULT: {0}/{0} PASS; process/service/signature queries mocked, no native task/process/network APIs called" -f $passed)
