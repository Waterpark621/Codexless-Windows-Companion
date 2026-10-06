Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'CompanionRuntime.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'PrivateConsole.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'VerifiedTunnel.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'UserSessionTask.psm1') -Force

function Get-DoctorListenerOwnershipSnapshot {
    param([string]$InstallDirectory,$Config,
        [ValidatePattern('^$|^Codexless-NativeAdapter-Test-[0-9a-f]{32}$')][string]$DisposableTaskName)
    try {
        $settingsPath=Join-Path $InstallDirectory 'settings.json'
        $ownerReceiptPath=Join-Path $InstallDirectory 'task-owner.json'
        $hostPidPath=Join-Path $InstallDirectory 'host.pid'
        $wrapperPidPath=Join-Path $InstallDirectory 'codexless.pid'
        $consoleReceiptPath=Join-Path $InstallDirectory 'codexless-console-owner.json'
        foreach($required in @($settingsPath,$ownerReceiptPath,$hostPidPath,$wrapperPidPath,$consoleReceiptPath)){
            if(!(Test-Path -LiteralPath $required -PathType Leaf)){return $null}
        }

        $currentSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $ownerSid=(Get-Acl -LiteralPath $settingsPath -ErrorAction Stop).GetOwner([Security.Principal.SecurityIdentifier]).Value
        if($ownerSid -cne $currentSid){return $null}

        $definitionParameters=@{UserSid=$ownerSid;LauncherDirectory=$InstallDirectory;HostScript=(Join-Path $PSScriptRoot 'Task-Host.ps1');PowerShellExe=(Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')}
        $nativePath=Join-Path $InstallDirectory 'native-adapter-owner.json'
        if(Test-Path -LiteralPath $nativePath){
            if((Get-Item -LiteralPath $nativePath -Force).Length -gt 32768 -or ((Get-Item -LiteralPath $nativePath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){return $null}
            $native=Get-Content -LiteralPath $nativePath -Raw|ConvertFrom-Json
            if($native.version -notin @(1,2) -or $native.state -cne 'active' -or $native.transactionId -cnotmatch '^[0-9a-f]{32}$' -or $native.generationId -cnotmatch '^[0-9a-f]{32}$'){return $null}
            $definitionParameters.TransactionId=$native.transactionId
            $definitionParameters.GenerationId=$native.generationId
        }
        if($DisposableTaskName){$definitionParameters.TaskName=$DisposableTaskName}
        $definition=New-HouseholdTaskDefinition @definitionParameters

        $ownerReceipt=Get-Content -LiteralPath $ownerReceiptPath -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
        $hostPid=0
        if(![int]::TryParse((Get-Content -LiteralPath $hostPidPath -Raw -ErrorAction Stop).Trim(),[ref]$hostPid) -or $hostPid -lt 1){return $null}
        $host=Get-ConsoleProcessIdentity $hostPid
        if(!(Test-HouseholdOwnerIdentity $ownerReceipt $host $definition)){return $null}

        $wrapperPid=0
        if(![int]::TryParse((Get-Content -LiteralPath $wrapperPidPath -Raw -ErrorAction Stop).Trim(),[ref]$wrapperPid) -or $wrapperPid -lt 1){return $null}
        $wrapper=Get-ConsoleProcessIdentity $wrapperPid
        if($null -eq $wrapper -or
           $wrapper.parentPid -ne $host.pid -or
           $wrapper.userSid -cne $ownerSid -or
           $wrapper.executable -ine $definition.PowerShellExe -or
           [DateTime]::Parse($wrapper.createdAt).ToUniversalTime() -lt [DateTime]::Parse($host.createdAt).ToUniversalTime()){
            return $null
        }

        $consoleReceipt=Get-Content -LiteralPath $consoleReceiptPath -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
        if(!(Test-PrivateConsoleReceipt $consoleReceipt $wrapper $ownerSid)){return $null}
        if(!(Test-PrivateConsoleListener $consoleReceiptPath ([int]$Config.port))){return $null}

        [pscustomobject]@{
            hostPid=[int]$host.pid
            hostCreatedAt=[string]$host.createdAt
            wrapperPid=[int]$wrapper.pid
            wrapperCreatedAt=[string]$wrapper.createdAt
            ownerSid=[string]$ownerSid
        }
    } catch { $null }
}

function Test-DoctorOwnershipSnapshotEqual {
    param($Before,$After)
    if($null -eq $Before -or $null -eq $After){return $false}
    try {
        $Before.hostPid -eq $After.hostPid -and
        $Before.hostCreatedAt -ceq $After.hostCreatedAt -and
        $Before.wrapperPid -eq $After.wrapperPid -and
        $Before.wrapperCreatedAt -ceq $After.wrapperCreatedAt -and
        $Before.ownerSid -ceq $After.ownerSid
    } catch { $false }
}

function Get-DoctorTunnelAcceptance {
    param([string]$InstallDirectory,$Config)
    $configured=@(Get-ConfiguredTunnels $Config)
    if($configured.Count -eq 0){return [pscustomobject]@{state='SKIP';detail='Tunnel support is disabled.';profiles=@()}}
    $results=@()
    foreach($tunnel in $configured){
        $state='FAIL'
        try {
            $status=Get-TunnelStatus $Config $tunnel
            if($null -ne $status -and $status.process_running -eq $true -and $status.ready -eq $true -and $status.healthy -eq $true -and
               (Test-OwnedTunnel $InstallDirectory $Config $tunnel $status)){$state='PASS'}
        } catch {}
        $results += [pscustomobject]@{alias=$tunnel.alias;state=$state}
    }
    [pscustomobject]@{state=if(@($results|Where-Object {$_.state -cne 'PASS'}).Count){'FAIL'}else{'PASS'};detail='Each enabled tunnel requires running, ready, healthy and exact ownership proof.';profiles=$results}
}
function Invoke-BrowserProbeProcess {
    param($Config,[string]$InstallDirectory)
    $probe=Join-Path $PSScriptRoot 'BrowserProbe.mjs'
    if(!(Test-Path -LiteralPath $probe -PathType Leaf)){
        return [pscustomobject]@{exitCode=1;output=''}
    }

    $stdout=Join-Path $env:TEMP ('codexless-doctor-browser-'+[Guid]::NewGuid().ToString('N')+'.out')
    $stderr=Join-Path $env:TEMP ('codexless-doctor-browser-'+[Guid]::NewGuid().ToString('N')+'.err')
    $process=$null
    try {
        $argLine='"'+$probe.Replace('"','')+'" --port '+([string][int]$Config.port)
        $process=Start-Process -FilePath $Config.nodeExe -ArgumentList $argLine -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -ErrorAction Stop
        if(!$process.WaitForExit(15000)){
            try{$process.Kill()}catch{}
            try{[void]$process.WaitForExit(2000)}catch{}
            return [pscustomobject]@{exitCode=1;output=''}
        }

        if(!(Test-Path -LiteralPath $stdout -PathType Leaf)){return [pscustomobject]@{exitCode=1;output=''}}
        $stdoutLength=(Get-Item -LiteralPath $stdout -ErrorAction Stop).Length
        $stderrLength=if(Test-Path -LiteralPath $stderr -PathType Leaf){(Get-Item -LiteralPath $stderr -ErrorAction Stop).Length}else{0}
        if($stdoutLength -gt 16384 -or $stderrLength -gt 0){
            return [pscustomobject]@{exitCode=1;output=''}
        }
        $output=(Get-Content -LiteralPath $stdout -Raw -ErrorAction Stop).Trim()
        [pscustomobject]@{exitCode=[int]$process.ExitCode;output=$output}
    } catch {
        [pscustomobject]@{exitCode=1;output=''}
    } finally {
        if($null -ne $process){$process.Dispose()}
        Remove-Item -LiteralPath $stdout,$stderr -Force -ErrorAction SilentlyContinue
    }
}

function Get-DoctorBrowserAcceptance {
    param([string]$InstallDirectory,$Config)
    $process=Invoke-BrowserProbeProcess $Config $InstallDirectory
    if($process.exitCode -ne 0 -or [string]::IsNullOrWhiteSpace([string]$process.output)){
        return [pscustomobject]@{state='FAIL';detail='Codexless Browser backend connectivity was not established.'}
    }
    try {
        $probe=[string]$process.output|ConvertFrom-Json -ErrorAction Stop
        if($probe.ok -ne $true -or
           $probe.browserStatus -cne 'ok' -or
           $probe.chromeSkill -cne 'ok' -or
           $probe.nodeRepl -cne 'ok' -or
           [int]$probe.supportedBackendCount -lt 1){
            return [pscustomobject]@{state='FAIL';detail='Codexless Browser backend connectivity was not established.'}
        }
        $detail=if($probe.selectionRequired -eq $true){
            "Browser runtime is healthy with $([int]$probe.supportedBackendCount) supported backends; explicit backend selection is required."
        }else{
            "Browser runtime is healthy with $([int]$probe.supportedBackendCount) supported backend."
        }
        [pscustomobject]@{state='PASS';detail=$detail}
    } catch {
        [pscustomobject]@{state='FAIL';detail='Codexless Browser probe returned an invalid result.'}
    }
}

function Get-DoctorVerdict {
    param([object[]]$Checks)
    if($null -eq $Checks -or @($Checks).Count -eq 0){return 'FAIL'}
    $canonical=@('PASS','DEGRADED','FAIL','SKIP')
    foreach($check in @($Checks)){
        if($null -eq $check -or !$check.PSObject.Properties['state']){return 'FAIL'}
        $state=[string]$check.state
        if(@($canonical|Where-Object{$_ -ceq $state}).Count -ne 1){return 'FAIL'}
    }
    if(@($Checks|Where-Object{[string]$_.state -ceq 'FAIL'}).Count -gt 0){return 'FAIL'}
    if(@($Checks|Where-Object{[string]$_.state -ceq 'DEGRADED'}).Count -gt 0){return 'DEGRADED'}
    'PASS'
}

Export-ModuleMember -Function Get-DoctorListenerOwnershipSnapshot,Test-DoctorOwnershipSnapshotEqual,Get-DoctorTunnelAcceptance,Get-DoctorBrowserAcceptance,Get-DoctorVerdict
