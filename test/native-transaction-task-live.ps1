$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\UserSessionTask.psm1') -Force
Import-Module ScheduledTasks -ErrorAction Stop

$fixture=Join-Path $PSScriptRoot ('.fixtures\native-transaction-task-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force|Out-Null
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$taskName='Codexless-NativeAdapter-Test-'+[Guid]::NewGuid().ToString('N')
$transactionId=[Guid]::NewGuid().ToString('N')
$generationId=[Guid]::NewGuid().ToString('N')
$probe=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'native-transaction-task-probe.ps1'))
$exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$definition=New-HouseholdTaskDefinition -UserSid $sid -LauncherDirectory $fixture -HostScript $probe -PowerShellExe $exe -TaskName $taskName -TransactionId $transactionId -GenerationId $generationId
$registered=$false

function Assert([bool]$Value,[string]$Message='assertion failed') { if(!$Value){throw $Message} }

try {
    if (Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue) { throw 'disposable task collision' }
    $null=Register-ScheduledTask -TaskName $taskName -TaskPath '\' -Xml $definition.Xml -ErrorAction Stop
    $registered=$true

    $exported=Export-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction Stop
    Assert-HouseholdTaskIdentity $exported $definition
    [xml]$taskXml=$exported
    $ns=New-Object Xml.XmlNamespaceManager($taskXml.NameTable)
    $ns.AddNamespace('t','http://schemas.microsoft.com/windows/2004/02/mit/task')
    $description=$taskXml.SelectSingleNode('/t:Task/t:RegistrationInfo/t:Description',$ns)
    $expectedDescription="Codexless household user-session owner; launcher-only v1; transaction=$transactionId; generation=$generationId"
    Assert ($null -ne $description -and $description.InnerText -ceq $expectedDescription) 'transaction task description mismatch'

    Start-ScheduledTask -TaskName $taskName -TaskPath '\'
    $deadline=[DateTime]::UtcNow.AddSeconds(25)
    $bindingPath=Join-Path $fixture 'binding.json'
    $ownerPath=Join-Path $fixture 'owner.json'
    while (!(Test-Path -LiteralPath $bindingPath -PathType Leaf) -or !(Test-Path -LiteralPath $ownerPath -PathType Leaf)) {
        if (Test-Path -LiteralPath ($ownerPath+'.error.json') -PathType Leaf) { throw (Get-Content -LiteralPath ($ownerPath+'.error.json') -Raw) }
        if ([DateTime]::UtcNow -gt $deadline) { throw 'transaction task probe did not produce evidence' }
        Start-Sleep -Milliseconds 200
    }

    $binding=Get-Content -LiteralPath $bindingPath -Raw|ConvertFrom-Json
    Assert ($binding.taskName -ceq $taskName -and $binding.transactionId -ceq $transactionId -and $binding.generationId -ceq $generationId) 'transaction arguments changed in Scheduler'
    $owner=Get-Content -LiteralPath $ownerPath -Raw|ConvertFrom-Json
    Assert ($owner.schedulerAncestryVerified -eq $true) 'Scheduler ancestry not verified'
    Assert ($owner.userSid -ceq $sid) 'Scheduled Task did not run as exact owner'
    Assert ($owner.sessionId -eq (Get-Process -Id $PID).SessionId) 'Scheduled Task did not use owner interactive session'

    New-Item -ItemType File -Path (Join-Path $fixture 'stop.flag') -Force|Out-Null
    $deadline=[DateTime]::UtcNow.AddSeconds(35)
    while ((Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction Stop).State -eq 'Running') {
        if ([DateTime]::UtcNow -gt $deadline) { throw 'probe still running; task retained, no force termination' }
        Start-Sleep -Milliseconds 200
    }

    $exported=Export-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction Stop
    Assert-HouseholdTaskIdentity $exported $definition
    Unregister-ScheduledTask -TaskName $taskName -TaskPath '\' -Confirm:$false -ErrorAction Stop
    $registered=$false
    Assert ($null -eq (Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue)) 'disposable task removal unproven'
    Write-Output 'RESULT: 1/1 PASS; real per-user least-privilege transaction-bound Scheduled Task registered, started, verified, cooperatively stopped, and removed'
} finally {
    New-Item -ItemType File -Path (Join-Path $fixture 'stop.flag') -Force -ErrorAction SilentlyContinue|Out-Null
    if ($registered) {
        $task=Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
        if ($null -ne $task) {
            $deadline=[DateTime]::UtcNow.AddSeconds(35)
            while ($task.State -eq 'Running' -and [DateTime]::UtcNow -le $deadline) {
                Start-Sleep -Milliseconds 200
                $task=Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
                if ($null -eq $task) { break }
            }
            if ($null -ne $task -and $task.State -eq 'Running') {
                throw 'probe still running; task retained, no force termination'
            }
            if ($null -ne $task) {
                $exported=Export-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction Stop
                Assert-HouseholdTaskIdentity $exported $definition
                Unregister-ScheduledTask -TaskName $taskName -TaskPath '\' -Confirm:$false -ErrorAction Stop
                $registered=$false
            }
        }
    }
    if (!$registered) { Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue }
}
