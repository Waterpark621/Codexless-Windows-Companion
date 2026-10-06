$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module (Join-Path $repo 'NativeTransactionAdapter.psm1') -Force
Import-Module (Join-Path $repo 'InstallTransaction.psm1') -Force
$nativeModule=Get-Module NativeTransactionAdapter

$fixture=Join-Path $PSScriptRoot ('.fixtures\public-install-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force|Out-Null
$project=Join-Path $fixture 'project'
$codexless=Join-Path $fixture 'codexless'
New-Item -ItemType Directory -Path $project,$codexless -Force|Out-Null
$node=(Get-Command node.exe).Source
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
        'VerifiedTunnel.psm1','ArtifactProvenance.psm1','BoundedNative.psm1','Signal-PrivateConsole.ps1','MutationLock.psm1','ARTIFACT-POLICY.json'
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
    function script:Open-HouseholdTaskAuthority {
        param($Definition,[switch]$AllowDelete)
        if ($null -eq $script:MockTaskXml) { throw 'mock task missing' }
        $authority=[pscustomobject]@{Disposed=$false;AllowDelete=[bool]$AllowDelete}
        $authority|Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.Disposed=$true }
        $authority
    }
    function script:Register-HouseholdTaskCreateOnly {
        param($Definition)
        $null=Register-ScheduledTask -TaskName $Definition.Name -TaskPath '\' -Xml $Definition.Xml -ErrorAction Stop
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
    function script:Get-ArtifactPolicy {param([string]$Artifact)
        if($Artifact -ceq 'tunnel') {return [pscustomobject]@{executableSha256=$script:FixtureTunnelSha}}
        [pscustomobject]@{executableSha256='2ffe3acc0458fdde999f50d11809bbe7c9b7ef204dcf17094e325d26ace101d8'}
    }
    function script:Test-TcpPort {param([int]$Port) $false}
    function script:Get-CompanionConfig {
        param([string]$CompanionRoot)
        $settings=Get-Content -LiteralPath (Join-Path $CompanionRoot 'settings.json') -Raw|ConvertFrom-Json
        $tunnels=@()
        $tunnelExeValue=$null
        $profile=$null
        $collection=ConvertTo-CompanionTunnelConfiguration $settings $CompanionRoot
        $tunnelExeValue=$collection.tunnelExe;$profile=$collection.profileDir;$tunnels=@($collection.tunnels)
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

& $nativeModule {param($hash) $script:FixtureTunnelSha=$hash} (Get-FileHash -LiteralPath $tunnelExe -Algorithm SHA256).Hash.ToLowerInvariant()

Import-Module (Join-Path $repo 'PublicInstall.psm1') -Force -DisableNameChecking
$public=Get-Module PublicInstall
$payload=Join-Path $fixture 'public-payload';New-Payload $payload 'public entrypoint fixture'
Copy-Item -LiteralPath (Join-Path $repo 'Doctor.ps1') -Destination (Join-Path $payload 'Doctor.ps1')
$digest=Get-TransactionTreeDigest $payload
$archive=Join-Path $fixture 'archive.zip';[IO.File]::WriteAllBytes($archive,[byte[]](1,2,3))
$state=[pscustomobject]@{Unpublished=$false;BadHash=$false;WrongRelease=$false;FailStart=$false;Doctor=$true;ReplaceTask=$false;StageCalls=0;ProvisionCalls=0;DoctorCalls=0;LastAdapter=$null}
$factory={
 param($Root,$ProjectPath,$CodexlessRoot,$NodeExe,$Port,$TrustedPayloadSha256,$TunnelClientExe,$TunnelId,$TunnelAlias,$TunnelRuntimeKey)
 $args=@{Root=$Root;ProjectPath=$ProjectPath;CodexlessRoot=$CodexlessRoot;NodeExe=$NodeExe;Port=$Port;TrustedPayloadSha256=$TrustedPayloadSha256;DisposableTaskName=$taskName;ReadyTimeoutSeconds=1}
 if($TunnelId){$args.TunnelClientExe=$TunnelClientExe;$args.TunnelId=$TunnelId;$args.TunnelAlias=$TunnelAlias;$args.TunnelRuntimeKey=$TunnelRuntimeKey}
 $result=New-NativeTransactionAdapter @args
 if($state.FailStart){$result.Start={param($g,$r) throw 'FIXTURE_INTERRUPTION'}}
 if($state.ReplaceTask){
  $register=$result.RegisterTask
  $result.RegisterTask={param($g,$r) & $register $g $r;& $nativeModule {$script:MockTaskXml=$script:MockTaskXml.Replace('LeastPrivilege','HighestAvailable')}}.GetNewClosure()
 }
 $state.LastAdapter=$result
 $result
}.GetNewClosure()
$services=@{
 Prerequisites={}
 Policy={param($role)
  if($role -ceq 'codexless'){
   if($state.Unpublished){throw 'PROVENANCE_POLICY_UNBOUND'}
   return [pscustomobject]@{state='published';buildId=('b'*64)}
  }
  $path=if($role -ceq 'node'){$node}else{$tunnelExe}
  [pscustomobject]@{executableSha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
 }.GetNewClosure()
 StageArchive={param($path,$destination)
  $state.StageCalls++
  if($state.BadHash){throw 'PROVENANCE_HASH_MISMATCH'}
  if($state.WrongRelease){throw 'CODEXLESS_DISTRIBUTION_INVALID'}
  [pscustomobject]@{stagedRoot=$codexless}
 }.GetNewClosure()
 Stage={param($destination) $state.StageCalls++;[pscustomobject]@{stagedRoot=$codexless}}.GetNewClosure()
 Binary={param($role,$directory) if($role -ceq 'node'){$node}else{$tunnelExe}}.GetNewClosure()
 Provision={param($root,$exe) $state.ProvisionCalls++}.GetNewClosure()
 Adapter=$factory
 Doctor={param($generation,$root) $state.DoctorCalls++;$state.Doctor}.GetNewClosure()
 Config={param($root) & $nativeModule {param($root) Get-CompanionConfig $root} $root}.GetNewClosure()
}
& $public {param($s) $script:PublicFixtureServices=$s;function script:New-PublicInstallServices {$script:PublicFixtureServices}} $services
function Install([string]$root,[switch]$Tunnel,[switch]$Recover,[string]$Expected=$digest) {
 $args=@{PayloadRoot=$payload;TrustedPayloadSha256=$Expected;InstallDirectory=$root;ProjectPath=$project;NodeExe=$node;CodexlessArchivePath=$archive;Recover=$Recover}
 if($Tunnel){$args.TunnelId='tunnel_fixture';$args.TunnelAlias='fixture';$args.TunnelClientExe=$tunnelExe;$args.TunnelRuntimeKey=$runtimeKey}else{$args.NoTunnel=$true}
 Invoke-PublicCompanionInstall @args
}
function Reset {& $nativeModule {$script:MockTaskXml=$null;$script:MockTaskState='Ready'};$state.FailStart=$false;$state.Doctor=$true;$state.ReplaceTask=$false}
Test 'Unpublished refuses before staging or destination mutation' {
 $state.Unpublished=$true;$before=$state.StageCalls
 Refuses {Install (Join-Path $fixture 'unpublished')} 'PROVENANCE_POLICY_UNBOUND'
 Assert ($before -eq $state.StageCalls);Assert (!(Test-Path -LiteralPath (Join-Path $fixture 'unpublished')))
 $state.Unpublished=$false
}
Test 'Externally supplied payload digest is required and never self-authorized' {
 $before=$state.StageCalls
 Refuses {Install (Join-Path $fixture 'untrusted') -Expected ''} 'INSTALL_TRUSTED_PAYLOAD_REQUIRED'
 Refuses {Install (Join-Path $fixture 'changed') -Expected ('0'*64)} 'INSTALL_PAYLOAD_PROVENANCE_INVALID'
 Assert ($before -eq $state.StageCalls)
}
Test 'Bad archive hash fails before transaction' {$state.BadHash=$true;Refuses {Install (Join-Path $fixture 'hash')} 'PROVENANCE_HASH_MISMATCH';$state.BadHash=$false}
Test 'Wrong release identity fails before transaction' {$state.WrongRelease=$true;Refuses {Install (Join-Path $fixture 'identity')} 'CODEXLESS_DISTRIBUTION_INVALID';$state.WrongRelease=$false}
Test 'Fresh zero-tunnel install uses real transaction and Native adapter with Doctor success' {
 $script:destination=Join-Path $fixture 'zero';$r=Install $destination
 Assert ($r.state -ceq 'installed' -and $r.verified -and $r.doctorVerdict -ceq 'PASS')
 Assert ($state.DoctorCalls -ge 1 -and $state.ProvisionCalls -ge 1)
 Assert (!(Test-Path -LiteralPath (Join-Path $destination 'keys')))
 Assert ((Get-Content -LiteralPath (Join-Path $destination 'settings.json') -Raw|ConvertFrom-Json).tunnel.enabled -eq $false)
}
Test 'Duplicate install refuses without additional staging' { $before=$state.StageCalls;Refuses {Install $destination} 'TRANSACTION_DESTINATION_EXISTS';Assert ($before -eq $state.StageCalls) }
Test 'Owned uninstall and reinstall use existing retirement contract' {
 $r=Invoke-OwnedUninstall $destination $state.LastAdapter;Assert ($r.state -ceq 'uninstalled')
 $r=Install $destination;Assert ($r.state -ceq 'installed')
 Invoke-OwnedUninstall $destination $state.LastAdapter|Out-Null
}
Test 'Foreign task is never adopted or overwritten' {
 & $nativeModule {$script:MockTaskXml='<foreign/>'}
 Refuses {Install (Join-Path $fixture 'foreign')} 'TRANSACTION_FOREIGN_TASK'
 Assert (!(Test-Path -LiteralPath (Join-Path $fixture 'foreign')));Reset
}
Test 'Scheduled Task replacement prevents owner finalization' {
 $state.ReplaceTask=$true;$root=Join-Path $fixture 'replacement'
 Refuses {Install $root} 'TRANSACTION_INSTALL_INCOMPLETE'
 Assert (!(Test-Path -LiteralPath (Join-Path $root 'install-owner.json')))
 Assert (Test-Path -LiteralPath (Join-Path $root 'incomplete-install.json'));Reset
}
Test 'Mid-install interruption retains the fence and verified recovery resumes same binding' {
 $root=Join-Path $fixture 'interrupted';$state.FailStart=$true
 Refuses {Install $root} 'TRANSACTION_INSTALL_INCOMPLETE'
 Assert (Test-Path -LiteralPath (Join-Path $root 'incomplete-install.json'))
 Refuses {Install $root} 'TRANSACTION_DESTINATION_EXISTS'
 $state.FailStart=$false;$r=Install $root -Recover
 Assert ($r.state -ceq 'recovered-installed' -and $r.verified -and $r.doctorVerdict -ceq 'PASS')
 Assert (!(Test-Path -LiteralPath (Join-Path $root 'incomplete-install.json')))
 Invoke-OwnedUninstall $root $state.LastAdapter|Out-Null
}
Test 'Doctor failure cannot publish installed success; exact recovery remains required' {
 $root=Join-Path $fixture 'doctor-failure';$state.Doctor=$false
 Refuses {Install $root} 'TRANSACTION_INSTALL_INCOMPLETE'
 Assert (!(Test-Path -LiteralPath (Join-Path $root 'install-owner.json')))
 $state.Doctor=$true;$r=Install $root -Recover;Assert ($r.verified)
 Invoke-OwnedUninstall $root $state.LastAdapter|Out-Null
}
Test 'One tunnel uses existing destination-local current-user DPAPI; output never contains key' {
 $root=Join-Path $fixture 'one';$r=Install $root -Tunnel
 Assert ($r.verified -and $r.doctorVerdict -ceq 'PASS')
 $cipher=Get-Content -LiteralPath (Join-Path $root 'keys\runtime-key.dpapi') -Raw
 Assert ($cipher -notmatch [regex]::Escape($runtimeKeyText));$decoded=ConvertTo-SecureString $cipher
 Assert ($decoded.Length -eq $runtimeKey.Length)
 Assert (($r|ConvertTo-Json -Depth 5) -notmatch [regex]::Escape($runtimeKeyText))
 Invoke-OwnedUninstall $root $state.LastAdapter|Out-Null
}
Test 'Root/project overlap refuses before staging' {Refuses {Install $project} 'INSTALL_ROOT_OVERLAP'}
Test 'Public CLI exposes no policy, task-name or adapter override and no disabled throw' {
 $text=Get-Content -LiteralPath (Join-Path $repo 'Install.ps1') -Raw
 Assert ($text -match 'Invoke-PublicCompanionInstall')
 Assert ($text -notmatch 'INSTALL_DISABLED_PUBLIC_PREVIEW|\$DisposableTaskName|\[hashtable\]\$Adapter')
}
Test 'Real Windows prerequisite check validates platform and Scheduler commands without querying tasks' {
 & $public {Assert-PublicInstallPrerequisites}
}
Test 'Recovery cannot silently replace a destination credential' {
 $root=Join-Path $fixture 'rekey-recovery'
 Refuses {Invoke-PublicCompanionInstall -PayloadRoot $payload -TrustedPayloadSha256 $digest -InstallDirectory $root -ProjectPath $project -TunnelId 'tunnel_fixture' -TunnelRuntimeKey $runtimeKey -Recover} 'INSTALL_RECOVERY_SETTINGS_MISMATCH'
 Assert (!(Test-Path -LiteralPath $root))
}
Test 'Actual public CLI dispatches a published-policy request with the external digest and destination settings' {
 $cli=Join-Path $fixture 'cli';New-Item -ItemType Directory -Path $cli|Out-Null
 Copy-Item -LiteralPath (Join-Path $repo 'Install.ps1') -Destination (Join-Path $cli 'Install.ps1')
 [IO.File]::WriteAllText((Join-Path $cli 'ArtifactProvenance.psm1'),"function Get-ArtifactPolicy {param(`$Role)[pscustomobject]@{state='published'}};Export-ModuleMember -Function Get-ArtifactPolicy")
 $stub=@'
function Invoke-PublicCompanionInstall {
 param($PayloadRoot,$TrustedPayloadSha256,$InstallDirectory,$ProjectPath,$NodeExe,$Port,$CodexlessArchivePath,$TunnelClientExe,$TunnelId,$TunnelAlias,$TunnelRuntimeKey,[switch]$NoTunnel,[switch]$Recover)
 [pscustomobject]@{forwarded=$true;payload=$PayloadRoot;trusted=$TrustedPayloadSha256;destination=$InstallDirectory;project=$ProjectPath;noTunnel=$NoTunnel.IsPresent;port=$Port}
}
Export-ModuleMember -Function Invoke-PublicCompanionInstall
'@
 [IO.File]::WriteAllText((Join-Path $cli 'PublicInstall.psm1'),$stub)
 $target=Join-Path $fixture 'cli-destination'
 $raw=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $cli 'Install.ps1') -ProjectPath $project -InstallDirectory $target -TrustedPayloadSha256 $digest -Port 18991 -NoTunnel
 Assert ($LASTEXITCODE -eq 0);$result=($raw|Out-String)|ConvertFrom-Json
 Assert ($result.forwarded -and $result.trusted -ceq $digest -and $result.destination -ceq $target -and $result.project -ceq $project -and $result.noTunnel -and $result.port -eq 18991)
 Assert (!(Test-Path -LiteralPath $target))
}
Test 'Actual Doctor aggregation and default child runner return PASS for a healthy generation fixture' {
 $generation=Join-Path $fixture 'doctor-generation';New-Item -ItemType Directory -Path $generation|Out-Null
 $source=Get-Content -LiteralPath (Join-Path $repo 'Doctor.ps1') -Raw
 $target='$task=Get-ScheduledTask -TaskName $taskName -TaskPath ([string][char]92) -ErrorAction SilentlyContinue'
 Assert ($source.Contains($target));$source=$source.Replace($target,"`$task=[pscustomobject]@{State='Running'}")
 [IO.File]::WriteAllText((Join-Path $generation 'Doctor.ps1'),$source)
 [IO.File]::WriteAllText((Join-Path $generation 'Household-Task.ps1'),"'{`"taskState`":`"Running`",`"ownerVerified`":true,`"piecesVerified`":true,`"cleanupRequired`":false}'")
 $runtime=@'
function Get-CompanionConfig {param($Root)[pscustomobject]@{port=18992;tunnels=@()}}
function Test-CodexlessReady {param($Config)$true}
Export-ModuleMember -Function Get-CompanionConfig,Test-CodexlessReady
'@
 [IO.File]::WriteAllText((Join-Path $generation 'CompanionRuntime.psm1'),$runtime)
 $support=@'
function Get-DoctorListenerOwnershipSnapshot {param($InstallDirectory,$Config,$DisposableTaskName)[pscustomobject]@{stable=$true}}
function Test-DoctorOwnershipSnapshotEqual {param($Before,$After)$null -ne $Before -and $null -ne $After}
function Get-DoctorBrowserAcceptance {param($InstallDirectory,$Config)[pscustomobject]@{state='PASS';detail='Healthy fixture backend'}}
function Get-DoctorTunnelAcceptance {param($InstallDirectory,$Config)[pscustomobject]@{state='SKIP';detail='Zero tunnels'}}
Export-ModuleMember -Function *
'@
 [IO.File]::WriteAllText((Join-Path $generation 'DoctorSupport.psm1'),$support)
 Assert (& $public {param($g,$r)Invoke-PublicInstallDoctor $g $r} $generation $fixture)
 $raw=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $generation 'Doctor.ps1') -InstallDirectory $fixture -Json
 Assert ($LASTEXITCODE -eq 0);$result=($raw|Out-String)|ConvertFrom-Json
 Assert ($result.ok -and $result.verdict -ceq 'PASS')
 Assert (($result|ConvertTo-Json -Depth 8) -notmatch [regex]::Escape($runtimeKeyText))
}
Test 'Payload change during staging is still refused by Native verifier' {
 $mutate={param($root,$exe) [IO.File]::AppendAllText((Join-Path $payload 'generation-marker.txt'),'changed')}.GetNewClosure()
 $original=$services.Provision;$services.Provision=$mutate
 Refuses {Install (Join-Path $fixture 'raced-payload')} 'NATIVE_ADAPTER_PAYLOAD_INVALID'
 $services.Provision=$original
}
Write-Output ("RESULT: {0}/{0} PASS; public wiring + real transaction/DPAPI; only Scheduler/lifecycle and dependency transport fixture boundaries mocked" -f $passed)
