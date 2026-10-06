param([string]$InstallDirectory,
    [ValidatePattern('^$|^Codexless-NativeAdapter-Test-[0-9a-f]{32}$')][string]$DisposableTaskName)
$ErrorActionPreference='Stop'
if(!$InstallDirectory){
    $InstallDirectory=$PSScriptRoot
    $parent=Split-Path $PSScriptRoot -Parent
    if((Split-Path $PSScriptRoot -Leaf) -cmatch '^[0-9a-f]{32}$' -and (Split-Path $parent -Leaf) -ceq 'generations'){
        $InstallDirectory=Split-Path $parent -Parent
    }
}
& (Join-Path $PSScriptRoot 'Household-Task.ps1') -Action Restart -LauncherDirectory $InstallDirectory -DisposableTaskName $DisposableTaskName
