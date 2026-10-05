param(
    [Parameter(Mandatory=$true)][string]$LauncherDirectory,
    [Parameter(Mandatory=$true)][string]$UserSid,
    [Parameter(Mandatory=$true)][string]$TaskName,
    [Parameter(Mandatory=$true)][string]$TransactionId,
    [Parameter(Mandatory=$true)][string]$GenerationId
)
$ErrorActionPreference='Stop'
if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -cne $UserSid) { throw 'probe owner mismatch' }
if ($TaskName -cnotmatch '^Codexless-NativeAdapter-Test-[0-9a-f]{32}$') { throw 'probe task name mismatch' }
if ($TransactionId -cnotmatch '^[0-9a-f]{32}$' -or $GenerationId -cnotmatch '^[0-9a-f]{32}$') { throw 'probe transaction mismatch' }
$binding=[ordered]@{
    taskName=$TaskName
    transactionId=$TransactionId
    generationId=$GenerationId
}
$binding | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $LauncherDirectory 'binding.json') -Encoding utf8
& (Join-Path $PSScriptRoot 'scheduler-owner-probe.ps1') -EvidenceFile (Join-Path $LauncherDirectory 'owner.json') -StopFile (Join-Path $LauncherDirectory 'stop.flag')
