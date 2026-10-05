param([Parameter(Mandatory=$true)][string]$EvidenceFile,[Parameter(Mandatory=$true)][string]$StopFile)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\WindowsTaskAdapter.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\UserSessionTask.psm1') -Force
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CodexlessOwnerProbe {
 [StructLayout(LayoutKind.Sequential)] public struct BasicLimits {
  public long perProcess, perJob; public uint flags; public UIntPtr min,max;
  public uint active; public UIntPtr affinity; public uint priority,scheduling;
 }
 [DllImport("kernel32.dll",SetLastError=true)] public static extern bool IsProcessInJob(IntPtr process,IntPtr job,out bool result);
 [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
 [DllImport("kernel32.dll",SetLastError=true)] public static extern bool QueryInformationJobObject(IntPtr job,int kind,out BasicLimits limits,uint length,out uint returned);
}
'@
$child=Get-ProcessIdentity $PID
$parentMetadata=Get-CimInstance Win32_Process -Filter "ProcessId=$($child.parentPid)"
$service=Get-CimInstance Win32_Service -Filter "Name='Schedule'"
[ordered]@{pid=$PID;parentPid=$child.parentPid;parentName=$parentMetadata.Name;parentExecutable=$parentMetadata.ExecutablePath;parentCreatedAt=$parentMetadata.CreationDate;schedulePid=$service.ProcessId;scheduleImage=$service.PathName;scheduleState=$service.State;scheduleAccount=$service.StartName} | ConvertTo-Json | Set-Content -LiteralPath ($EvidenceFile+'.parent.json') -Encoding utf8
$parent=Get-TaskSchedulerParentIdentity $child.parentPid
if ($null -eq $parent) { throw 'Scheduler parent is unavailable' }
$signature=Get-AuthenticodeSignature -LiteralPath $parent.executable
$parent | Add-Member -NotePropertyName microsoftSigned -NotePropertyValue ($signature.Status -eq 'Valid' -and $signature.SignerCertificate.Subject -match 'O=Microsoft Corporation(?:,|$)')
$inJob=$false
if(![CodexlessOwnerProbe]::IsProcessInJob([CodexlessOwnerProbe]::GetCurrentProcess(),[IntPtr]::Zero,[ref]$inJob)){throw 'Job query failed'}
$limits=New-Object CodexlessOwnerProbe+BasicLimits
$bytes=0
$limitsAvailable=[CodexlessOwnerProbe]::QueryInformationJobObject([IntPtr]::Zero,2,[ref]$limits,[Runtime.InteropServices.Marshal]::SizeOf($limits),[ref]$bytes)
$report=[ordered]@{at=[DateTime]::UtcNow.ToString('o');pid=$PID;createdAt=$child.createdAt;userSid=$child.userSid;sessionId=(Get-Process -Id $PID).SessionId;parentPid=$parent.pid;parentExecutable=$parent.executable;parentCreatedAt=$parent.createdAt;parentIdentitySource=$parent.identitySource;parentMicrosoftSigned=$parent.microsoftSigned;schedulePid=$service.ProcessId;scheduleState=$service.State;scheduleAccount=$service.StartName;scheduleBindingRechecked=$parent.serviceRechecked;inJob=$inJob;jobLimitsAvailable=$limitsAvailable;jobLimitFlags=if($limitsAvailable){$limits.flags}else{$null};schedulerAncestryVerified=(Test-TaskSchedulerAncestry $child $parent $service (Join-Path $env:SystemRoot 'System32'));expired=$false}
$report | ConvertTo-Json | Set-Content -LiteralPath $EvidenceFile -Encoding utf8
$deadline=[DateTime]::UtcNow.AddSeconds(30)
while(!(Test-Path -LiteralPath $StopFile)){
 if([DateTime]::UtcNow -gt $deadline){$report.expired=$true;break};Start-Sleep -Milliseconds 200
}
$report.completedAt=[DateTime]::UtcNow.ToString('o')
$report | ConvertTo-Json | Set-Content -LiteralPath $EvidenceFile -Encoding utf8
