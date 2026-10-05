$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$modulePath=Join-Path $PSScriptRoot '..\InstallTransaction.psm1'
$root=Join-Path $PSScriptRoot ('.fixtures\transaction-adversarial-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force|Out-Null
$passed=0

function Assert([bool]$Value,[string]$Message='assertion failed'){if(!$Value){throw $Message}}
function Refuses([scriptblock]$Body,[string]$Code){
    $caught=$false
    try{& $Body|Out-Null}catch{$caught=$_.Exception.Message -like ($Code+'*')}
    Assert $caught ("expected refusal "+$Code)
}
function Test([string]$Name,[scriptblock]$Body){
    New-Fixture
    & $Body
    $script:passed++
    Write-Output "PASS $Name"
}
function Fence {
    Get-Content -LiteralPath (Join-Path $script:destination 'incomplete-install.json') -Raw|ConvertFrom-Json
}
function New-Fixture {
    Import-Module $modulePath -Force
    $script:module=Get-Module InstallTransaction
    $folder=Join-Path $root ([Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $folder|Out-Null
    $script:payload=Join-Path $folder 'payload'
    New-Item -ItemType Directory -Path $payload|Out-Null
    [IO.File]::WriteAllText((Join-Path $payload 'fixture.txt'),'portable synthetic payload')
    $script:destination=Join-Path $folder 'destination'
    $script:project=Join-Path $folder 'project'
    New-Item -ItemType Directory -Path $project|Out-Null
    [IO.File]::WriteAllText((Join-Path $project 'user-data.txt'),'preserve user project')
    $script:mock=[pscustomobject]@{
        Task=$null;Running=$false;Stopped=$true;Fail='';Calls=[Collections.Generic.List[string]]::new()
        Digest=(Get-TransactionTreeDigest $payload);VerifyCount=0;FailVerifyAt=0;GetTaskCount=0;ForeignAtGet=0
        RemoveTaskNoOp=$false
    }
    $script:adapter=@{
        Validate={param($r,$p) $mock.Calls.Add('validate');if($mock.Fail -ceq 'validate'){throw 'fixture-fail'}}
        VerifyStage={param($path)
            $mock.VerifyCount++
            $mock.Calls.Add(('verify-stage-'+$mock.VerifyCount))
            if($mock.FailVerifyAt -eq $mock.VerifyCount){return $false}
            (Get-TransactionTreeDigest $path) -ceq $mock.Digest
        }
        GetTask={
            $mock.GetTaskCount++
            if($mock.ForeignAtGet -eq $mock.GetTaskCount){return [pscustomobject]@{foreign=$true}}
            $mock.Task
        }
        RegisterTask={param($path,$record)
            $mock.Calls.Add('register')
            if($mock.Fail -ceq 'register-before'){throw 'fixture-fail'}
            $mock.Task=$record.transactionId
            if($mock.Fail -ceq 'register-after'){throw 'fixture-fail'}
        }
        AssertTask={param($record)
            $mock.Calls.Add('assert-task')
            if($mock.Task -cne $record.transactionId){throw 'foreign task'}
        }
        Start={param($path,$record)
            $mock.Calls.Add('start')
            if($mock.Fail -ceq 'start-before'){throw 'fixture-fail'}
            $mock.Running=$true
            if($mock.Fail -ceq 'start-after'){throw 'fixture-fail'}
        }
        VerifyReady={param($path,$record)
            $mock.Calls.Add('ready')
            $mock.Running -and $mock.Fail -cne 'ready'
        }
        Stop={param($path,$record)
            $mock.Calls.Add('stop')
            if($mock.Fail -ceq 'stop'){throw 'fixture-fail'}
            $mock.Running=$false
        }
        VerifyStopped={param($record) !$mock.Running -and $mock.Stopped}
        RemoveTask={param($record)
            $mock.Calls.Add('remove-task')
            if($mock.Fail -ceq 'remove-task'){throw 'fixture-fail'}
            if(!$mock.RemoveTaskNoOp){$mock.Task=$null}
        }
    }
}
function Install-Fixture {Invoke-InstallTransaction $destination $payload $adapter}

Test 'Failure before fence leaves destination absent' {
    $mock.Fail='validate'
    Refuses {Install-Fixture} 'fixture-fail'
    Assert (!(Test-Path -LiteralPath $destination))
    Assert ($null -eq $mock.Task)
}

Test 'Initial provenance failure leaves destination absent' {
    $mock.FailVerifyAt=1
    Refuses {Install-Fixture} 'TRANSACTION_PROVENANCE_INVALID'
    Assert (!(Test-Path -LiteralPath $destination))
    Assert ($null -eq $mock.Task)
}

Test 'Failure after staging verification leaves destination absent' {
    $mock.FailVerifyAt=2
    Refuses {Install-Fixture} 'TRANSACTION_STAGE_INVALID'
    Assert (!(Test-Path -LiteralPath $destination))
    Assert ($null -eq $mock.Task)
}

Test 'Fenced-stage verified recovery resumes exact staged payload' {
    & $module {
        $script:RecoveryOriginalStageWriter=${function:Set-TransactionStage}
        $script:InterruptBeforePromoting=$true
        function script:Set-TransactionStage {param($Fence,[string]$Path,[string]$Stage)
            if($script:InterruptBeforePromoting -and $Stage -ceq 'promoting'){$script:InterruptBeforePromoting=$false;throw 'fixture-fenced-interrupt'}
            & $script:RecoveryOriginalStageWriter $Fence $Path $Stage
        }
    }
    Refuses {Install-Fixture} 'TRANSACTION_INSTALL_INCOMPLETE'
    Assert ((Fence).stage -ceq 'fenced')
    $result=Invoke-OwnedRepair $destination $adapter
    Assert ($result.state -ceq 'recovered-installed' -and $result.verified -and $mock.Running)
    Assert (!(Test-Path -LiteralPath (Join-Path $destination 'incomplete-install.json')))
}

Test 'Promoting-stage verified recovery retains and adopts exact generation evidence' {
    $mock.FailVerifyAt=3
    Refuses {Install-Fixture} 'TRANSACTION_INSTALL_INCOMPLETE'
    $f=Fence
    Assert ($f.stage -ceq 'promoting')
    Assert (Test-Path -LiteralPath (Join-Path (Join-Path $destination 'generations') $f.generationId))
    Assert (!(Test-Path -LiteralPath (Join-Path $destination 'install-owner.json')))
    $result=Invoke-VerifiedIncompleteInstallRecovery $destination $adapter
    Assert ($result.state -ceq 'recovered-installed' -and $result.verified -and $mock.Running)
    Assert (!(Test-Path -LiteralPath (Join-Path $destination 'incomplete-install.json')))
}

Test 'Foreign task appearing before registration is fenced and never overwritten' {
    $mock.ForeignAtGet=3
    Refuses {Install-Fixture} 'TRANSACTION_INSTALL_INCOMPLETE'
    Assert ((Fence).stage -ceq 'registering')
    Assert ($null -eq $mock.Task)
}

foreach($failure in @('register-before','register-after','start-before','start-after','ready')){
    Test "Install $failure failure retains exact incomplete stage" {
        $mock.Fail=$failure
        Refuses {Install-Fixture} 'TRANSACTION_INSTALL_INCOMPLETE'
        $f=Fence
        $expected=if($failure -like 'register-*'){'registering'}elseif($failure -like 'start-*'){'starting'}else{'verifying'}
        Assert ($f.stage -ceq $expected)
        Refuses {Get-OwnedInstall $destination $adapter} 'TRANSACTION_INCOMPLETE'
        $mock.Fail=''
        $result=Invoke-VerifiedIncompleteInstallRecovery $destination $adapter
        Assert ($result.state -ceq 'recovered-installed' -and $result.verified -and $mock.Running)
        Assert (!(Test-Path -LiteralPath (Join-Path $destination 'incomplete-install.json')))
    }
}

Test 'Finalizing-stage verified recovery completes only after exact evidence revalidation' {
    & $module {
        $script:FailFenceRemovalOnce=$true
        function script:Remove-Item {
            param([string]$LiteralPath,$ErrorAction)
            if($script:FailFenceRemovalOnce -and $LiteralPath -like '*incomplete-install.json'){$script:FailFenceRemovalOnce=$false;throw 'fixture-finalize-failure'}
            Microsoft.PowerShell.Management\Remove-Item -LiteralPath $LiteralPath -ErrorAction $ErrorAction
        }
    }
    Refuses {Install-Fixture} 'TRANSACTION_INSTALL_INCOMPLETE'
    Assert ((Fence).stage -ceq 'finalizing')
    Assert (Test-Path -LiteralPath (Join-Path $destination 'install-owner.json'))
    Refuses {Get-OwnedInstall $destination $adapter} 'TRANSACTION_INCOMPLETE'
    $result=Invoke-VerifiedIncompleteInstallRecovery $destination $adapter
    Assert ($result.state -ceq 'recovered-installed' -and $result.verified -and $mock.Running)
    Assert (!(Test-Path -LiteralPath (Join-Path $destination 'incomplete-install.json')))
}

Test 'Exact-owned repair succeeds only from a completed install' {
    Install-Fixture|Out-Null
    $result=Invoke-OwnedRepair $destination $adapter
    Assert ($result.state -ceq 'repaired' -and $result.verified -and $mock.Running)
    Assert (!(Test-Path -LiteralPath (Join-Path $destination 'incomplete-install.json')))
}

Test 'Repair stop failure retains stopping fence' {
    Install-Fixture|Out-Null
    $mock.Fail='stop'
    Refuses {Invoke-OwnedRepair $destination $adapter} 'TRANSACTION_REPAIR_INCOMPLETE'
    Assert ((Fence).operation -ceq 'repair' -and (Fence).stage -ceq 'stopping')
}

Test 'Repair readiness failure retains verifying fence' {
    Install-Fixture|Out-Null
    $mock.Fail='ready'
    Refuses {Invoke-OwnedRepair $destination $adapter} 'TRANSACTION_REPAIR_INCOMPLETE'
    Assert ((Fence).operation -ceq 'repair' -and (Fence).stage -ceq 'verifying')
}

Test 'Exact-owned uninstall preserves project data and removes only owned pieces' {
    Install-Fixture|Out-Null
    $result=Invoke-OwnedUninstall $destination $adapter
    Assert ($result.state -ceq 'uninstalled' -and $result.verified -and $result.userDataPreserved)
    Assert ($null -eq $mock.Task -and !$mock.Running)
    Assert ((Get-Content -LiteralPath (Join-Path $project 'user-data.txt') -Raw) -ceq 'preserve user project')
}

Test 'Foreign task refuses uninstall before stop or file mutation' {
    Install-Fixture|Out-Null
    $owned=Get-OwnedInstall $destination $adapter
    $mock.Task='foreign'
    $beforeStops=@($mock.Calls|Where-Object {$_ -ceq 'stop'}).Count
    $failed=$false;try{Invoke-OwnedUninstall $destination $adapter|Out-Null}catch{$failed=$true}
    Assert $failed
    Assert (@($mock.Calls|Where-Object {$_ -ceq 'stop'}).Count -eq $beforeStops)
    Assert (Test-Path -LiteralPath (Join-Path $owned.generation 'fixture.txt'))
}

Test 'Foreign destination file refuses uninstall and is retained' {
    Install-Fixture|Out-Null
    $owned=Get-OwnedInstall $destination $adapter
    $foreign=Join-Path $owned.generation 'foreign.txt'
    [IO.File]::WriteAllText($foreign,'foreign')
    Refuses {Invoke-OwnedUninstall $destination $adapter} 'TRANSACTION_PAYLOAD_CHANGED'
    Assert (Test-Path -LiteralPath $foreign)
    Assert $mock.Running
}

Test 'Uninstall cannot report success while task remains' {
    Install-Fixture|Out-Null
    $owned=Get-OwnedInstall $destination $adapter
    $mock.RemoveTaskNoOp=$true
    Refuses {Invoke-OwnedUninstall $destination $adapter} 'TRANSACTION_UNINSTALL_INCOMPLETE'
    Assert ($null -ne $mock.Task)
    Assert (Test-Path -LiteralPath (Join-Path $owned.generation 'fixture.txt'))
    Assert (Test-Path -LiteralPath (Join-Path $destination 'incomplete-install.json'))
}

Test 'Malformed owner receipt never authorizes repair or uninstall' {
    Install-Fixture|Out-Null
    [IO.File]::WriteAllText((Join-Path $destination 'install-owner.json'),'{')
    Refuses {Invoke-OwnedRepair $destination $adapter} 'TRANSACTION_RECORD_INVALID'
    Refuses {Invoke-OwnedUninstall $destination $adapter} 'TRANSACTION_RECORD_INVALID'
    Assert $mock.Running
}

Write-Output ("RESULT: {0}/{0} PASS; deterministic transaction adapters plus disposable local file I/O; no live Scheduler/process/network mutation" -f $passed)
