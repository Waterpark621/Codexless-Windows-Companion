param(
    [Parameter(Mandatory=$true)][ValidateSet('Install','Start','Stop','Restart','Status','Doctor','Tunnels')][string]$Action,
    [string]$InstallDirectory=(Join-Path $env:LOCALAPPDATA 'CodexlessCompanion'),
    [switch]$NoPause
)
$ErrorActionPreference='Stop'
$code=0
try {
    Import-Module (Join-Path $PSScriptRoot 'LauncherUi.psm1') -Force -DisableNameChecking
    Invoke-SimpleLauncher -Action $Action -PayloadRoot $PSScriptRoot -Root $InstallDirectory
} catch {
    Write-Host ('Companion: '+$_.Exception.Message) -ForegroundColor Red
    $code=1
    if($_.Exception.Data.Contains('LauncherExitCode')){$code=[int]$_.Exception.Data['LauncherExitCode']}
} finally {
    if(!$NoPause){$null=Read-Host 'Press Enter to close'}
}
exit $code
