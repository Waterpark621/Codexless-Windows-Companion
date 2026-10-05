param(
    [Parameter(Mandatory=$true)] [ValidateSet('Register','Start','Stop','Restart','Status','Definition')] [string]$Action,
    [string]$LauncherDirectory=(Join-Path $env:LOCALAPPDATA 'CodexlessCompanion')
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'UserSessionTask.psm1') -Force
$currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$ownerSid = (Get-Acl -LiteralPath (Join-Path $LauncherDirectory 'settings.json') -ErrorAction Stop).GetOwner([Security.Principal.SecurityIdentifier]).Value
$definitionParameters=@{
    UserSid=$ownerSid
    LauncherDirectory=$LauncherDirectory
    HostScript=(Join-Path $PSScriptRoot 'Task-Host.ps1')
    PowerShellExe=(Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
}
$nativeOwnerPath=Join-Path $LauncherDirectory 'native-adapter-owner.json'
if (Test-Path -LiteralPath $nativeOwnerPath -PathType Leaf) {
    if ((Get-Item -LiteralPath $nativeOwnerPath -Force).Length -gt 32768) { throw 'TASK_TRANSACTION_OWNER_INVALID' }
    try { $nativeOwner=Get-Content -LiteralPath $nativeOwnerPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch { throw 'TASK_TRANSACTION_OWNER_INVALID' }
    if ($nativeOwner.version -ne 1 -or $nativeOwner.state -cne 'active' -or $nativeOwner.transactionId -cnotmatch '^[0-9a-f]{32}$' -or
        $nativeOwner.generationId -cnotmatch '^[0-9a-f]{32}$' -or $nativeOwner.payloadSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'TASK_TRANSACTION_OWNER_INVALID' }
    $definitionParameters.TransactionId=[string]$nativeOwner.transactionId
    $definitionParameters.GenerationId=[string]$nativeOwner.generationId
}
$definition = New-HouseholdTaskDefinition @definitionParameters
if ($Action -eq 'Definition') { $definition.Xml; exit 0 }
Assert-HouseholdPrincipal $currentSid $ownerSid
Import-Module (Join-Path $PSScriptRoot 'WindowsTaskAdapter.psm1') -Force
$adapter = New-WindowsTaskAdapter $definition
Invoke-HouseholdLifecycle -Action $Action -Definition $definition -Adapter $adapter | ConvertTo-Json -Depth 5
