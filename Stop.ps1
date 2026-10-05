$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'Household-Task.ps1') -Action Stop -LauncherDirectory $PSScriptRoot
