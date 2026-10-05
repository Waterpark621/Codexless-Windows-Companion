param(
    [Parameter(Mandatory=$true)] [ValidateSet('Register','Start','Stop','Restart','Status','Definition')] [string]$Action,
    [string]$LauncherDirectory=(Join-Path $env:LOCALAPPDATA 'CodexlessCompanion')
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'UserSessionTask.psm1') -Force
$currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$ownerSid = (Get-Acl -LiteralPath (Join-Path $LauncherDirectory 'settings.json') -ErrorAction Stop).GetOwner([Security.Principal.SecurityIdentifier]).Value
$definition = New-HouseholdTaskDefinition -UserSid $ownerSid -LauncherDirectory $LauncherDirectory -HostScript (Join-Path $PSScriptRoot 'Task-Host.ps1') -PowerShellExe (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
if ($Action -eq 'Definition') { $definition.Xml; exit 0 }
Assert-HouseholdPrincipal $currentSid $ownerSid
Import-Module (Join-Path $PSScriptRoot 'WindowsTaskAdapter.psm1') -Force
$adapter = New-WindowsTaskAdapter $definition
Invoke-HouseholdLifecycle -Action $Action -Definition $definition -Adapter $adapter | ConvertTo-Json -Depth 5
