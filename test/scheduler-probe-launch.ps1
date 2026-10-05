param([Parameter(Mandatory=$true)][string]$EvidenceFile,[Parameter(Mandatory=$true)][string]$StopFile)
$ErrorActionPreference='Stop'
try{
 & (Join-Path $PSScriptRoot 'scheduler-owner-probe.ps1') -EvidenceFile $EvidenceFile -StopFile $StopFile *> ($EvidenceFile+'.log')
}catch{
 [ordered]@{at=[DateTime]::UtcNow.ToString('o');status='probe-failed';error=$_.Exception.Message;line=$_.InvocationInfo.ScriptLineNumber} | ConvertTo-Json | Set-Content -LiteralPath ($EvidenceFile+'.error.json') -Encoding utf8
 exit 1
}
