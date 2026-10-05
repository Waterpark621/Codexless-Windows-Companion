$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\UserSessionTask.psm1') -Force
Import-Module ScheduledTasks -ErrorAction Stop
$fixture=Join-Path $PSScriptRoot ('.fixtures\scheduler-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$evidenceFile=Join-Path $fixture 'owner.json';$stopFile=Join-Path $fixture 'stop.flag'
$probe=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'scheduler-probe-launch.ps1'))
$exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$definition=New-HouseholdTaskDefinition $sid $fixture $probe $exe
$name='Codexless-B-OwnershipProbe-'+[Guid]::NewGuid().ToString('N')
[xml]$xml=$definition.Xml
$ns=New-Object Xml.XmlNamespaceManager($xml.NameTable);$ns.AddNamespace('t','http://schemas.microsoft.com/windows/2004/02/mit/task')
$xml.SelectSingleNode('/t:Task/t:Triggers',$ns).RemoveAll() # Manual ephemeral probe only; never auto-run on logon.
$xml.SelectSingleNode('/t:Task/t:Actions/t:Exec/t:Arguments',$ns).InnerText='-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$probe+'" -EvidenceFile "'+$evidenceFile+'" -StopFile "'+$stopFile+'"'
$registered=$false
try{
 if(Get-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction SilentlyContinue){throw 'Probe task collision'}
 $null=Register-ScheduledTask -TaskName $name -TaskPath '\' -Xml $xml.OuterXml -ErrorAction Stop
 $registered=$true
 Start-ScheduledTask -TaskName $name -TaskPath '\'
 $deadline=[DateTime]::UtcNow.AddSeconds(20)
 while(!(Test-Path -LiteralPath $evidenceFile)){
  if(Test-Path -LiteralPath ($evidenceFile+'.error.json')){throw (Get-Content -LiteralPath ($evidenceFile+'.error.json') -Raw)}
  if([DateTime]::UtcNow -gt $deadline){throw 'Scheduler probe did not produce evidence'};Start-Sleep -Milliseconds 200
 }
 $evidence=Get-Content -LiteralPath $evidenceFile -Raw | ConvertFrom-Json
 if($evidence.userSid -cne $sid -or $evidence.sessionId -ne (Get-Process -Id $PID).SessionId){throw 'Scheduler did not use the interactive owner/session'}
 $pidBefore=$evidence.pid
 Start-ScheduledTask -TaskName $name -TaskPath '\'
 Start-Sleep -Milliseconds 500
 $after=Get-Content -LiteralPath $evidenceFile -Raw | ConvertFrom-Json
 if($after.pid -ne $pidBefore){throw 'IgnoreNew created a duplicate probe'}
 $evidence | Add-Member -NotePropertyName duplicateStartSingular -NotePropertyValue $true
 $evidence | ConvertTo-Json
 if(!$evidence.schedulerAncestryVerified){throw 'Proposed scheduler ancestry does not match actual Windows ownership'}
}finally{
 New-Item -ItemType File -Path $stopFile -Force | Out-Null
 if($registered){
  $deadline=[DateTime]::UtcNow.AddSeconds(35)
  while((Get-ScheduledTask -TaskName $name -TaskPath '\').State -eq 'Running'){
   if([DateTime]::UtcNow -gt $deadline){throw 'Probe still running; task retained, no force termination'};Start-Sleep -Milliseconds 200
  }
  Get-ScheduledTaskInfo -TaskName $name -TaskPath '\' | Select-Object LastTaskResult,LastRunTime | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $fixture 'task-result.json') -Encoding utf8
  [xml]$current=Export-ScheduledTask -TaskName $name -TaskPath '\'
  $currentNs=New-Object Xml.XmlNamespaceManager($current.NameTable);$currentNs.AddNamespace('t','http://schemas.microsoft.com/windows/2004/02/mit/task')
  if($current.SelectSingleNode('/t:Task/t:Actions/t:Exec/t:Arguments',$currentNs).InnerText -cne $xml.SelectSingleNode('/t:Task/t:Actions/t:Exec/t:Arguments',$ns).InnerText){throw 'Changed probe task identity; not removed'}
  Unregister-ScheduledTask -TaskName $name -TaskPath '\' -Confirm:$false
 }
}
