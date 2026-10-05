$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\UserSessionTask.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\WindowsTaskAdapter.psm1') -Force
Import-Module ScheduledTasks -ErrorAction Stop

$fixture=Join-Path $PSScriptRoot ('.fixtures\task-replacement-race-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force|Out-Null
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$taskName='Codexless-NativeAdapter-Test-'+[Guid]::NewGuid().ToString('N')
$ownedScript=Join-Path $fixture 'owned.ps1'
$foreignScript=Join-Path $fixture 'foreign.ps1'
$ownedMarker=Join-Path $fixture 'owned.marker'
$foreignMarker=Join-Path $fixture 'foreign.marker'
@'
param([string]$LauncherDirectory,[string]$UserSid,[string]$TaskName,[string]$TransactionId,[string]$GenerationId)
[IO.File]::WriteAllText((Join-Path $LauncherDirectory 'owned.marker'),$TransactionId+'/'+$GenerationId)
'@|Set-Content -LiteralPath $ownedScript -Encoding UTF8
@'
param([string]$LauncherDirectory,[string]$UserSid,[string]$TaskName,[string]$TransactionId,[string]$GenerationId)
[IO.File]::WriteAllText((Join-Path $LauncherDirectory 'foreign.marker'),$TransactionId+'/'+$GenerationId)
'@|Set-Content -LiteralPath $foreignScript -Encoding UTF8

function New-Definition([string]$HostFile,[string]$Transaction,[string]$Generation) {
    New-HouseholdTaskDefinition -UserSid $sid -LauncherDirectory $fixture -HostScript $HostFile -PowerShellExe $exe -TaskName $taskName -TransactionId $Transaction -GenerationId $Generation
}
function Assert([bool]$Value,[string]$Message='assertion failed'){if(!$Value){throw $Message}}
function Refuses([scriptblock]$Body,[string]$Prefix) {
    $caught=$false;$actual=''
    try { & $Body|Out-Null } catch { $actual=$_.Exception.Message;$caught=$actual -like ($Prefix+'*') }
    Assert $caught ("expected refusal "+$Prefix+"; got "+$actual)
}
function Wait-Marker([string]$Path) {
    $deadline=[DateTime]::UtcNow.AddSeconds(15)
    while(!(Test-Path -LiteralPath $Path -PathType Leaf)) {
        if([DateTime]::UtcNow -ge $deadline){throw 'task marker timeout'}
        Start-Sleep -Milliseconds 100
    }
}
function Remove-AnyTask {
    $task=Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
    if($null -ne $task){Unregister-ScheduledTask -TaskName $taskName -TaskPath '\' -Confirm:$false -ErrorAction SilentlyContinue}
}
function Install-AssertAttackHook($Attack) {
    $module=Get-Module WindowsTaskAdapter
    & $module {
        param($a)
        $script:E5Attack=$a
        $script:E5OriginalAssert=(Get-Command Assert-HouseholdTaskIdentity -CommandType Function).ScriptBlock
        function script:Assert-HouseholdTaskIdentity {
            param([string]$Xml,$Definition)
            & $script:E5OriginalAssert $Xml $Definition
            if(!$script:E5Attack.fired) {
                $script:E5Attack.fired=$true
                try {
                    Register-ScheduledTask -TaskName $Definition.Name -TaskPath '\' -Xml $script:E5Attack.foreign.Xml -Force -ErrorAction Stop|Out-Null
                    $script:E5Attack.succeeded=$true
                } catch {
                    $script:E5Attack.denied=$true
                }
            }
        }
    } $Attack
}
function Remove-AssertAttackHook {
    $module=Get-Module WindowsTaskAdapter
    & $module {
        if($script:E5OriginalAssert){Set-Item Function:Assert-HouseholdTaskIdentity $script:E5OriginalAssert}
        Remove-Variable E5Attack,E5OriginalAssert -Scope Script -ErrorAction SilentlyContinue
    }
}
function Pass([string]$Name){$script:passed++;Write-Output "PASS $Name"}

$passed=0
$tx1=[Guid]::NewGuid().ToString('N');$gen1=[Guid]::NewGuid().ToString('N')
$tx2=[Guid]::NewGuid().ToString('N');$gen2=[Guid]::NewGuid().ToString('N')
$owned=New-Definition $ownedScript $tx1 $gen1
$foreign=New-Definition $foreignScript $tx2 $gen2

try {
    Remove-AnyTask
    Register-HouseholdTaskCreateOnly -Definition $owned
    $attack=[pscustomobject]@{foreign=$foreign;fired=$false;denied=$false;succeeded=$false}
    Install-AssertAttackHook $attack
    try { Start-HouseholdTaskPinned -Definition $owned } finally { Remove-AssertAttackHook }
    Wait-Marker $ownedMarker
    Assert ($attack.fired -and $attack.denied -and !$attack.succeeded) 'replacement after final Start proof was not denied'
    Assert (!(Test-Path -LiteralPath $foreignMarker)) 'foreign replacement ran'
    Unregister-HouseholdTaskPinned -Definition $owned
    Pass 'Replacement after final proof before Start is denied and exact owned task starts'

    Remove-Item -LiteralPath $ownedMarker,$foreignMarker -Force -ErrorAction SilentlyContinue
    Register-HouseholdTaskCreateOnly -Definition $owned
    $attack=[pscustomobject]@{foreign=$foreign;fired=$false;denied=$false;succeeded=$false}
    Install-AssertAttackHook $attack
    try { Unregister-HouseholdTaskPinned -Definition $owned } finally { Remove-AssertAttackHook }
    Assert ($attack.fired -and $attack.denied -and !$attack.succeeded) 'replacement before unregister was not denied'
    Assert ($null -eq (Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue)) 'owned task remained after exact unregister'
    Pass 'Replacement after final proof before Unregister is denied and exact task is removed'

    $null=Register-ScheduledTask -TaskName $taskName -TaskPath '\' -Xml $foreign.Xml -ErrorAction Stop
    Refuses { Register-HouseholdTaskCreateOnly -Definition $owned } 'Cannot create a file'
    $xml=Export-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction Stop
    Assert-HouseholdTaskIdentity $xml $foreign
    Unregister-HouseholdTaskPinned -Definition $foreign
    Pass 'Create-only Register never overwrites a same-name foreign task'

    $null=Register-ScheduledTask -TaskName $taskName -TaskPath '\' -Xml $foreign.Xml -ErrorAction Stop
    Refuses { Start-HouseholdTaskPinned -Definition $owned } 'TASK_IDENTITY_MISMATCH'
    Assert (!(Test-Path -LiteralPath $ownedMarker) -and !(Test-Path -LiteralPath $foreignMarker)) 'wrong-generation task was started'
    Unregister-HouseholdTaskPinned -Definition $foreign
    Pass 'Same name with wrong action and generation is never started'

    $null=Register-ScheduledTask -TaskName $taskName -TaskPath '\' -Xml $foreign.Xml -ErrorAction Stop
    Refuses { Unregister-HouseholdTaskPinned -Definition $owned } 'TASK_IDENTITY_MISMATCH'
    $xml=Export-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction Stop
    Assert-HouseholdTaskIdentity $xml $foreign
    Unregister-HouseholdTaskPinned -Definition $foreign
    Pass 'Same name with wrong action and generation is never removed'

    Register-HouseholdTaskCreateOnly -Definition $owned
    Unregister-HouseholdTaskPinned -Definition $owned
    # An adversary can still win the post-retirement/pre-create scheduling gap in
    # promotion. Create-only candidate registration must then fail closed.
    $null=Register-ScheduledTask -TaskName $taskName -TaskPath '\' -Xml $foreign.Xml -ErrorAction Stop
    Refuses { Register-HouseholdTaskCreateOnly -Definition $owned } 'Cannot create a file'
    $xml=Export-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction Stop
    Assert-HouseholdTaskIdentity $xml $foreign
    Unregister-HouseholdTaskPinned -Definition $foreign
    Pass 'Foreign task winning promote gap blocks candidate or rollback registration instead of being overwritten'

    Write-Output ("RESULT: {0}/{0} PASS; real disposable Scheduler task-file authority closes Start/Unregister/Register/promote replacement races" -f $passed)
} finally {
    try{Remove-AssertAttackHook}catch{}
    Remove-AnyTask
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}
