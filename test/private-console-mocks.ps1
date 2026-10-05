$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\PrivateConsole.psm1') -Force
$module=Get-Module PrivateConsole
$fixture=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot ('.fixtures\private-console-mocks-'+[Guid]::NewGuid().ToString('N'))))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
$executable=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$command='"'+$executable+'" fixture'
$root=[pscustomobject]@{pid=101;parentPid=50;createdAt='2026-10-03T00:00:00.0000000Z';userSid=$sid;executable=$executable;commandLine=$command}
& $module {
    param($root)
    $script:FixtureRoot=$root
    $script:OriginalReceiptWriter=${function:Write-PrivateConsoleReceipt}
    function script:Write-PrivateConsoleReceipt {
        param([string]$Path,$Receipt,[switch]$Replace)
        $script:WriteCalls++
        if ($script:WriteCalls -eq $script:FailWriteCall) { throw 'FIXTURE_WRITE_FAILED' }
        & $script:OriginalReceiptWriter $Path $Receipt -Replace:$Replace
    }
    function script:Start-PrivateConsoleNativeProcess {
        param($Executable,$Command,$WorkingDirectory)
        $pending=Get-Content -LiteralPath $script:FixtureReceipt -Raw | ConvertFrom-Json
        if ($pending.version -ne 0 -or $pending.state -cne 'launch-pending') { throw 'FIXTURE_FENCE_NOT_DURABLE_BEFORE_SPAWN' }
        $script:NativeStarts++
        if ($script:NativeFailure) { throw 'FIXTURE_CREATE_FAILED' }
        101
    }
    function script:Get-ConsoleProcessIdentity {
        param([int]$ProcessId)
        if ($script:IdentityFailure) { throw 'FIXTURE_IDENTITY_FAILED' }
        $script:FixtureIdentities[$ProcessId]
    }
    function script:Get-NetTCPConnection {
        param($LocalPort,$State,$ErrorAction)
        $script:ListenerReads++
        if ($script:ListenerFailure) { throw 'FIXTURE_LISTENER_UNAVAILABLE' }
        if ($script:ListenerReads -gt 1 -and $null -ne $script:ChangedListeners) { return $script:ChangedListeners }
        $script:FixtureListeners
    }
} $root
$results=[Collections.Generic.List[string]]::new()
function Assert-True([bool]$Value) { if (!$Value) { throw 'assertion failed' } }
function Assert-Throws([scriptblock]$Body,[string]$Code) { try { & $Body | Out-Null } catch { if ($_.Exception.Message.Contains($Code)) { return }; throw }; throw "Expected $Code" }
function Test([string]$Name,[scriptblock]$Body) { & $Body; $results.Add($Name); Write-Output "PASS $Name" }
function Reset-Fixture {
    $script:receiptPath=Join-Path $fixture ([Guid]::NewGuid().ToString('N')+'.json')
    & $module {
        param($path)
        $script:FixtureReceipt=$path;$script:WriteCalls=0;$script:FailWriteCall=0;$script:NativeStarts=0;$script:NativeFailure=$false;$script:IdentityFailure=$false
        $script:FixtureIdentities=@{101=$script:FixtureRoot.PSObject.Copy()}
        $script:ListenerReads=0;$script:ListenerFailure=$false;$script:ChangedListeners=$null
        $script:FixtureListeners=@([pscustomobject]@{LocalAddress='127.0.0.1';LocalPort=12345;OwningProcess=102})
    } $script:receiptPath
}
function Assert-Fenced {
    Assert-True (Test-Path -LiteralPath $receiptPath)
    $before=& $module { $script:NativeStarts }
    Assert-Throws { Start-PrivateConsoleProcess $executable 'fixture' $fixture $receiptPath } 'PRIVATE_CONSOLE_RECEIPT_EXISTS'
    Assert-True ((& $module { $script:NativeStarts }) -eq $before)
}
Test 'Durable pending fence precedes spawn and atomically becomes exact identity receipt' {
    Reset-Fixture
    $receipt=Start-PrivateConsoleProcess $executable 'fixture' $fixture $receiptPath
    Assert-True ($receipt.version -eq 1)
    Assert-True ((Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json).version -eq 1)
    Assert-Fenced
}
Test 'Missing post-spawn identity preserves fence and blocks another child' {
    Reset-Fixture
    & $module { $script:FixtureIdentities=@{} }
    Assert-Throws { Start-PrivateConsoleProcess $executable 'fixture' $fixture $receiptPath } 'PRIVATE_CONSOLE_START_IDENTITY_INVALID'
    Assert-Fenced
}
Test 'CIM failure after spawn preserves fence and blocks another child' {
    Reset-Fixture
    & $module { $script:IdentityFailure=$true }
    Assert-Throws { Start-PrivateConsoleProcess $executable 'fixture' $fixture $receiptPath } 'FIXTURE_IDENTITY_FAILED'
    Assert-Fenced
}
Test 'PID fence update failure after spawn preserves initial fence' {
    Reset-Fixture
    & $module { $script:FailWriteCall=2 }
    Assert-Throws { Start-PrivateConsoleProcess $executable 'fixture' $fixture $receiptPath } 'FIXTURE_WRITE_FAILED'
    Assert-Fenced
    Assert-True ((Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json).version -eq 0)
}
Test 'Final receipt replacement failure preserves pending PID fence' {
    Reset-Fixture
    & $module { $script:FailWriteCall=3 }
    Assert-Throws { Start-PrivateConsoleProcess $executable 'fixture' $fixture $receiptPath } 'FIXTURE_WRITE_FAILED'
    Assert-Fenced
    $pending=Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    Assert-True ($pending.version -eq 0 -and $pending.pid -eq 101)
}
Test 'Native launch failure retains the reservation for explicit review' {
    Reset-Fixture
    & $module { $script:NativeFailure=$true }
    Assert-Throws { Start-PrivateConsoleProcess $executable 'fixture' $fixture $receiptPath } 'FIXTURE_CREATE_FAILED'
    Assert-Fenced
}
Test 'Pre-launch fence failure starts no child' {
    Reset-Fixture
    & $module { $script:FailWriteCall=1 }
    Assert-Throws { Start-PrivateConsoleProcess $executable 'fixture' $fixture $receiptPath } 'FIXTURE_WRITE_FAILED'
    Assert-True ((& $module { $script:NativeStarts }) -eq 0)
}
function Set-ListenerFixture {
    Reset-Fixture
    [ordered]@{version=1;pid=101;createdAt=$root.createdAt;userSid=$sid;executable=$executable;commandLine=$command} | ConvertTo-Json | Set-Content -LiteralPath $receiptPath -Encoding utf8
    & $module {
        $script:FixtureIdentities[102]=[pscustomobject]@{pid=102;parentPid=101;createdAt='2026-10-03T00:00:01.0000000Z';userSid=$script:FixtureRoot.userSid;executable='C:\fixture\node.exe';commandLine='owned MCP fixture'}
    }
}
Test 'Listener readiness requires exact root receipt and same-owner child ancestry' {
    Set-ListenerFixture
    Assert-True (Test-PrivateConsoleListener $receiptPath 12345)
}
Test 'Foreign listener with otherwise valid wrapper receipt is rejected' {
    Set-ListenerFixture
    & $module { $script:FixtureIdentities[102].parentPid=999 }
    Assert-True (!(Test-PrivateConsoleListener $receiptPath 12345))
}
Test 'Foreign listener SID is rejected' {
    Set-ListenerFixture
    & $module { $script:FixtureIdentities[102].userSid='S-1-5-21-1-2-3-999' }
    Assert-True (!(Test-PrivateConsoleListener $receiptPath 12345))
}
Test 'Listener or parent PID predating the root invalidates ancestry' {
    Set-ListenerFixture
    & $module { $script:FixtureIdentities[102].createdAt='2026-10-02T00:00:00.0000000Z' }
    Assert-True (!(Test-PrivateConsoleListener $receiptPath 12345))
}
Test 'Reused root PID does not validate an old console receipt' {
    Set-ListenerFixture
    & $module { $script:FixtureIdentities[101].createdAt='2026-10-03T02:00:00.0000000Z' }
    Assert-True (!(Test-PrivateConsoleListener $receiptPath 12345))
}
Test 'Every listener on the configured port must belong to the owned root' {
    Set-ListenerFixture
    & $module { $script:FixtureListeners+= [pscustomobject]@{LocalAddress='::1';LocalPort=12345;OwningProcess=999} }
    Assert-True (!(Test-PrivateConsoleListener $receiptPath 12345))
}
Test 'Changed listener snapshot is rejected before readiness' {
    Set-ListenerFixture
    & $module { $script:ChangedListeners=@([pscustomobject]@{LocalAddress='127.0.0.1';LocalPort=12345;OwningProcess=999}) }
    Assert-True (!(Test-PrivateConsoleListener $receiptPath 12345))
}
Test 'Unavailable listener query fails closed' {
    Set-ListenerFixture
    & $module { $script:ListenerFailure=$true }
    Assert-True (!(Test-PrivateConsoleListener $receiptPath 12345))
}
Test 'No listeners cannot establish readiness' {
    Set-ListenerFixture
    & $module { $script:FixtureListeners=@() }
    Assert-True (!(Test-PrivateConsoleListener $receiptPath 12345))
}
Write-Output ("RESULT: {0}/{0} PASS; native creation/CIM/TCP mocked; evidence={1}" -f $results.Count,$fixture)
