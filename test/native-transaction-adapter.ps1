$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module (Join-Path $repo 'NativeTransactionAdapter.psm1') -Force
Import-Module (Join-Path $repo 'InstallTransaction.psm1') -Force
$nativeModule=Get-Module NativeTransactionAdapter

$fixture=Join-Path $PSScriptRoot ('.fixtures\native-adapter-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force|Out-Null
$project=Join-Path $fixture 'project'
$codexless=Join-Path $fixture 'codexless'
New-Item -ItemType Directory -Path $project,$codexless -Force|Out-Null
$node=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$tunnelExe=Join-Path $fixture 'tunnel-client.exe'
[IO.File]::WriteAllBytes($tunnelExe,[byte[]](1,2,3,4))
$taskName='Codexless-NativeAdapter-Test-'+[Guid]::NewGuid().ToString('N')
$runtimeKeyText='fixture-native-runtime-key'
$runtimeKey=ConvertTo-SecureString $runtimeKeyText -AsPlainText -Force
$passed=0

function Assert([bool]$Value,[string]$Message='assertion failed') { if(!$Value){throw $Message} }
function Refuses([scriptblock]$Body,[string]$Prefix) {
    $caught=$false
    $actual=''
    try { & $Body|Out-Null } catch { $actual=$_.Exception.Message;$caught=$actual -like ($Prefix+'*') }
    Assert $caught ("expected refusal: "+$Prefix+"; got: "+$actual)
}
function New-Payload([string]$Path,[string]$Marker) {
    New-Item -ItemType Directory -Path $Path -Force|Out-Null
    foreach($name in @(
        'Task-Host.ps1','Household-Host.ps1','UserSessionTask.psm1','WindowsTaskAdapter.psm1',
        'CompanionRuntime.psm1','GenerationIdentity.psm1','PrivateConsole.psm1','PriorBootOwnership.psm1',
        'VerifiedTunnel.psm1','ArtifactProvenance.psm1','BoundedNative.psm1','Signal-PrivateConsole.ps1'
    )) {
        [IO.File]::Copy((Join-Path $repo $name),(Join-Path $Path $name),$false)
    }
    [IO.File]::WriteAllText((Join-Path $Path 'generation-marker.txt'),$Marker,[Text.UTF8Encoding]::new($false))
}
function New-TestAdapter([string]$Root,[string[]]$Digests) {
    $parameters=@{
        Root=$Root
        ProjectPath=$project
        CodexlessRoot=$codexless
        NodeExe=$node
        TrustedPayloadSha256=$Digests
        DisposableTaskName=$taskName
        TunnelClientExe=$tunnelExe
        TunnelId='tunnel_fixture'
        TunnelAlias='fixture'
        TunnelRuntimeKey=$runtimeKey
        ReadyTimeoutSeconds=1
    }
    New-NativeTransactionAdapter @parameters
}
function Test([string]$Name,[scriptblock]$Body) {
    & $Body
    $script:passed++
    Write-Output "PASS $Name"
}

& $nativeModule {
    $script:MockTaskXml=$null
    $script:MockTaskState='Ready'
    $script:FailNonInitialGeneration=$false
    $script:InitialGeneration=$null

    function script:Get-ScheduledTask {
        [CmdletBinding()]
        param([string]$TaskName,[string]$TaskPath)
        if ($null -eq $script:MockTaskXml) { return $null }
        [pscustomobject]@{TaskName=$TaskName;State=$script:MockTaskState}
    }
    function script:Export-ScheduledTask {
        [CmdletBinding()]
        param([string]$TaskName,[string]$TaskPath)
        if ($null -eq $script:MockTaskXml) { throw 'mock task missing' }
        $script:MockTaskXml
    }
    function script:Register-ScheduledTask {
        [CmdletBinding()]
        param([string]$TaskName,[string]$TaskPath,[string]$Xml)
        if ($null -ne $script:MockTaskXml) { throw 'mock foreign task collision' }
        $script:MockTaskXml=$Xml
        $script:MockTaskState='Ready'
        [pscustomobject]@{TaskName=$TaskName}
    }
    function script:Unregister-ScheduledTask {
        [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='Low')]
        param([string]$TaskName,[string]$TaskPath)
        if ($null -eq $script:MockTaskXml) { throw 'mock task missing' }
        $script:MockTaskXml=$null
        $script:MockTaskState='Ready'
    }
    function script:New-WindowsTaskAdapter { param($Definition) @{Definition=$Definition} }
    function script:Invoke-HouseholdLifecycle {
        param([string]$Action,$Definition,[hashtable]$Adapter,[int]$TimeoutSeconds)
        if ($Action -ceq 'Start') {
            Remove-Item -LiteralPath (Join-Path $Definition.LauncherDirectory 'stop.flag') -Force -ErrorAction SilentlyContinue
            $script:MockTaskState='Running'
            return [pscustomobject]@{state='starting';changed=$true}
        }
        if ($Action -ceq 'Stop') {
            New-Item -ItemType File -Path (Join-Path $Definition.LauncherDirectory 'stop.flag') -Force|Out-Null
            $script:MockTaskState='Ready'
            return [pscustomobject]@{state='stopped';changed=$true}
        }
        throw 'unexpected lifecycle action'
    }
    function script:Get-HouseholdRuntimeState {
        param($Definition)
        $running=($script:MockTaskState -ceq 'Running')
        $failReady=($running -and $script:FailNonInitialGeneration -and
            $null -ne $script:InitialGeneration -and $Definition.GenerationId -cne $script:InitialGeneration)
        [pscustomobject]@{
            taskState=$script:MockTaskState
            hostPresent=$running
            ownerVerified=$running
            piecesVerified=$running
            listenerPresent=($running -and !$failReady)
            tunnelPresent=$false
            tunnels=@()
            cleanupRequired=$false
            cleanupState=$null
        }
    }
    function script:Test-HouseholdOwnershipEvidence { param([string]$LauncherDirectory) $false }
    function script:Test-CodexlessReady { param($Config,[int]$TimeoutMs) $true }
    function script:Get-CompanionConfig {
        param([string]$CompanionRoot)
        $settings=Get-Content -LiteralPath (Join-Path $CompanionRoot 'settings.json') -Raw|ConvertFrom-Json
        $tunnels=@()
        $tunnelExeValue=$null
        $profile=$null
        if($settings.tunnel.enabled -eq $true) {
            $tunnelExeValue=[IO.Path]::GetFullPath([string]$settings.tunnel.executable)
            if([IO.Path]::IsPathRooted([string]$settings.tunnel.profileDir)){
                $profile=[IO.Path]::GetFullPath([string]$settings.tunnel.profileDir)
            } else {
                $profile=[IO.Path]::GetFullPath((Join-Path $CompanionRoot ([string]$settings.tunnel.profileDir)))
            }
            $keyPath=[IO.Path]::GetFullPath((Join-Path $CompanionRoot ([string]$settings.tunnel.keyFile)))
            $tunnels=@([pscustomobject]@{
                alias=[string]$settings.tunnel.alias
                tunnelId=[string]$settings.tunnel.tunnelId
                keyPath=$keyPath
            })
        }
        [pscustomobject]@{
            companionRoot=[IO.Path]::GetFullPath($CompanionRoot)
            projectPath=[IO.Path]::GetFullPath([string]$settings.project.path)
            codexlessRoot=[IO.Path]::GetFullPath([string]$settings.codexless.root)
            nodeExe=[IO.Path]::GetFullPath([string]$settings.codexless.nodeExe)
            nodeSha256=[string]$settings.codexless.nodeSha256
            port=[int]$settings.codexless.port
            tunnelExe=$tunnelExeValue
            profileDir=$profile
            tunnels=$tunnels
            readyUrl=('http://127.0.0.1:'+([int]$settings.codexless.port)+'/readyz')
        }
    }
}

try {
    $payload=Join-Path $fixture 'payload-v1'
    $candidate=Join-Path $fixture 'payload-v2'
    $badCandidate=Join-Path $fixture 'payload-v3'
    New-Payload $payload 'v1'
    New-Payload $candidate 'v2'
    New-Payload $badCandidate 'v3'
    $d1=Get-TransactionTreeDigest $payload
    $d2=Get-TransactionTreeDigest $candidate
    $d3=Get-TransactionTreeDigest $badCandidate

    Test 'Adapter refuses mutation without transaction fence' {
        $root=Join-Path $fixture 'no-fence-destination'
        $adapter=New-TestAdapter $root @($d1)
        $record=[pscustomobject]@{
            version=1
            state='installed'
            transactionId=[Guid]::NewGuid().ToString('N')
            generationId=[Guid]::NewGuid().ToString('N')
            payloadSha256=$d1
        }
        Refuses { & $adapter.RegisterTask $payload $record } 'NATIVE_ADAPTER_STATE_MISSING'
        Assert (!(Test-Path -LiteralPath $root)) 'fence-free adapter call mutated destination'
    }

    Test 'Existing foreign Scheduled Task refuses before destination creation' {
        $root=Join-Path $fixture 'foreign-task-destination'
        & $nativeModule { $script:MockTaskXml='<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"></Task>'; $script:MockTaskState='Ready' }
        $adapter=New-TestAdapter $root @($d1)
        Refuses { Invoke-InstallTransaction $root $payload $adapter } 'TRANSACTION_FOREIGN_TASK'
        Assert (!(Test-Path -LiteralPath $root)) 'foreign-task refusal mutated destination'
        & $nativeModule { $script:MockTaskXml=$null; $script:MockTaskState='Ready' }
    }

    $destination=Join-Path $fixture 'destination'
    $adapter=New-TestAdapter $destination @($d1,$d2,$d3)
    $adapterTrace=New-Object System.Collections.ArrayList
    foreach($opName in @('VerifyStage','AssertTask','VerifyStopped')) {
        $inner=$adapter[$opName]
        $name=$opName
        $trace=$adapterTrace
        $adapter[$opName]=& {
            param($captured,$capturedName,$capturedTrace)
            {
                param($a)
                [void]$capturedTrace.Add('BEGIN '+$capturedName)
                try {
                    $value=& $captured $a
                    [void]$capturedTrace.Add('OK '+$capturedName)
                    $value
                } catch {
                    [void]$capturedTrace.Add('ERR '+$capturedName+': '+$_.Exception.Message)
                    throw
                }
            }.GetNewClosure()
        } $inner $name $trace
    }
    foreach($opName in @('Validate','Stop','Promote','Start','VerifyReady')) {
        $inner=$adapter[$opName]
        $name=$opName
        $trace=$adapterTrace
        $adapter[$opName]=& {
            param($captured,$capturedName,$capturedTrace)
            {
                param($a,$b)
                [void]$capturedTrace.Add('BEGIN '+$capturedName)
                try {
                    $value=& $captured $a $b
                    [void]$capturedTrace.Add('OK '+$capturedName)
                    $value
                } catch {
                    [void]$capturedTrace.Add('ERR '+$capturedName+': '+$_.Exception.Message)
                    throw
                }
            }.GetNewClosure()
        } $inner $name $trace
    }

    Test 'Real transaction install creates exact state task binding and current-user DPAPI credential' {
        $result=Invoke-InstallTransaction $destination $payload $adapter
        Assert ($result.state -ceq 'installed' -and $result.verified) 'install did not verify'
        Assert (!(Test-Path -LiteralPath (Join-Path $destination 'incomplete-install.json'))) 'successful install retained fence'
        $owner=Get-Content -LiteralPath (Join-Path $destination 'install-owner.json') -Raw|ConvertFrom-Json
        $native=Get-Content -LiteralPath (Join-Path $destination 'native-adapter-owner.json') -Raw|ConvertFrom-Json
        Assert ($native.transactionId -ceq $owner.transactionId -and $native.generationId -ceq $owner.generationId) 'native receipt not transaction bound'
        Assert ($native.PSObject.Properties.Name -notcontains 'userSid') 'native receipt persisted SID'
        Assert ($native.PSObject.Properties.Name -notcontains 'path') 'native receipt persisted path'

        $xml=& $nativeModule { $script:MockTaskXml }
        $bindingText="transaction=$($owner.transactionId); generation=$($owner.generationId)"
        Assert ($xml -match [regex]::Escape($bindingText)) 'task description not transaction bound'
        Assert ($xml -match [regex]::Escape("-TransactionId $($owner.transactionId) -GenerationId $($owner.generationId)")) 'task action not transaction bound'
        Assert ($xml -match '<LogonType>InteractiveToken</LogonType>') 'task not interactive-token'
        Assert ($xml -match '<RunLevel>LeastPrivilege</RunLevel>') 'task not least privilege'
        Assert ($xml -match '<AllowHardTerminate>false</AllowHardTerminate>') 'task allows hard termination'

        $keyPath=Join-Path $destination 'keys\runtime-key.dpapi'
        $cipher=(Get-Content -LiteralPath $keyPath -Raw).Trim()
        Assert ($cipher -notmatch [regex]::Escape($runtimeKeyText)) 'credential stored in plaintext'
        $secure=ConvertTo-SecureString $cipher
        $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            $plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
            Assert ($plain -ceq $runtimeKeyText) 'DPAPI credential not decryptable by destination user'
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
            $plain=$null
        }
    }

    Test 'Repair uses exact owned task and generation' {
        $result=Invoke-OwnedRepair $destination $adapter
        Assert ($result.state -ceq 'repaired' -and $result.verified) 'repair did not verify'
        Assert ((& $nativeModule { $script:MockTaskState }) -ceq 'Running') 'repair did not restart owned task'
    }

    Test 'Foreign settings mutation refuses before repair stop' {
        $settingsPath=Join-Path $destination 'settings.json'
        $saved=[IO.File]::ReadAllBytes($settingsPath)
        try {
            [IO.File]::AppendAllText($settingsPath,' ')
            $before=& $nativeModule { $script:MockTaskState }
            Refuses { Invoke-OwnedRepair $destination $adapter } 'NATIVE_ADAPTER_FOREIGN_STATE'
            Assert ((& $nativeModule { $script:MockTaskState }) -ceq $before) 'foreign settings caused runtime mutation'
            Assert (!(Test-Path -LiteralPath (Join-Path $destination 'incomplete-install.json'))) 'preflight refusal created repair fence'
        } finally {
            [IO.File]::WriteAllBytes($settingsPath,$saved)
        }
    }

    Test 'Update promotes exact candidate task generation' {
        $prior=(Get-Content -LiteralPath (Join-Path $destination 'install-owner.json') -Raw|ConvertFrom-Json).generationId
        $adapterTrace.Clear()
        try { $result=Invoke-OwnedUpdate $destination $candidate $adapter }
        catch { throw ($_.Exception.Message+' TRACE='+($adapterTrace -join ' | ')) }
        Assert ($result.state -ceq 'updated' -and $result.verified) 'candidate update failed'
        $current=Get-Content -LiteralPath (Join-Path $destination 'install-owner.json') -Raw|ConvertFrom-Json
        Assert ($current.generationId -cne $prior -and $current.payloadSha256 -ceq $d2) 'candidate receipt not promoted'
        $xml=& $nativeModule { $script:MockTaskXml }
        $bindingText="transaction=$($current.transactionId); generation=$($current.generationId)"
        Assert ($xml -match [regex]::Escape($bindingText)) 'candidate task description binding wrong'
        Assert ($xml -match [regex]::Escape("-TransactionId $($current.transactionId) -GenerationId $($current.generationId)")) 'candidate task action binding wrong'
    }

    Test 'Failed candidate readiness restores exact previous task generation' {
        $before=Get-Content -LiteralPath (Join-Path $destination 'install-owner.json') -Raw|ConvertFrom-Json
        & $nativeModule { param($generation) $script:InitialGeneration=$generation;$script:FailNonInitialGeneration=$true } $before.generationId
        try {
            $result=Invoke-OwnedUpdate $destination $badCandidate $adapter
            Assert ($result.state -ceq 'rolled-back' -and !$result.candidateAccepted) 'failed candidate was not rolled back'
            $after=Get-Content -LiteralPath (Join-Path $destination 'install-owner.json') -Raw|ConvertFrom-Json
            Assert ($after.generationId -ceq $before.generationId -and $after.payloadSha256 -ceq $before.payloadSha256) 'rollback did not restore exact prior receipt'
            $native=Get-Content -LiteralPath (Join-Path $destination 'native-adapter-owner.json') -Raw|ConvertFrom-Json
            Assert ($native.generationId -ceq $before.generationId) 'rollback did not restore native task attribution'
            Assert (!(Test-Path -LiteralPath (Join-Path $destination 'incomplete-install.json'))) 'verified rollback retained fence'
        } finally {
            & $nativeModule { $script:FailNonInitialGeneration=$false;$script:InitialGeneration=$null }
        }
    }

    Test 'Uninstall removes only exact owned state and preserves unknown user data' {
        $userNote=Join-Path $destination 'user-note.txt'
        [IO.File]::WriteAllText($userNote,'preserve me',[Text.UTF8Encoding]::new($false))
        $result=Invoke-OwnedUninstall $destination $adapter
        Assert ($result.state -ceq 'uninstalled' -and $result.userDataPreserved) 'uninstall did not verify'
        Assert (Test-Path -LiteralPath $userNote -PathType Leaf) 'unknown user data was deleted'
        Assert (!(Test-Path -LiteralPath (Join-Path $destination 'settings.json'))) 'owned settings survived uninstall'
        Assert (!(Test-Path -LiteralPath (Join-Path $destination 'native-adapter-owner.json'))) 'native owner receipt survived uninstall'
        Assert (!(Test-Path -LiteralPath (Join-Path $destination 'keys\runtime-key.dpapi'))) 'owned credential survived uninstall'
        Assert ($null -eq (& $nativeModule { $script:MockTaskXml })) 'owned task survived uninstall'
        Assert (Test-Path -LiteralPath (Join-Path $destination 'uninstalled-owner.json') -PathType Leaf) 'uninstall tombstone missing'
    }
} finally {
    & $nativeModule {
        $script:MockTaskXml=$null
        $script:MockTaskState='Ready'
        $script:FailNonInitialGeneration=$false
        $script:InitialGeneration=$null
    }
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ("RESULT: {0}/{0} PASS; production adapter exercised with real transaction/file/DPAPI operations and mocked Scheduler/runtime process surface" -f $passed)
