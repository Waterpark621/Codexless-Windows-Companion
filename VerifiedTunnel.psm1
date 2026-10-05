Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'PrivateConsole.psm1')
if(!('Codexless.TunnelLifetime' -as [type])){
 Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
namespace Codexless {
 public sealed class TunnelLifetime : IDisposable {
  IntPtr handle;
  [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint access,bool inherit,int pid);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetProcessTimes(IntPtr process,out long created,out long exited,out long kernel,out long user);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool QueryFullProcessImageName(IntPtr process,uint flags,StringBuilder name,ref int size);
  [DllImport("kernel32.dll",SetLastError=true)] static extern uint WaitForSingleObject(IntPtr handle,uint timeout);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
  public string CreatedAt {get;private set;}
  public string Executable {get;private set;}
  public TunnelLifetime(int pid){
   handle=OpenProcess(0x1000|0x100000,false,pid); // Limited query and synchronize only.
   if(handle==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error());
   try{
    long c,e,k,u;if(!GetProcessTimes(handle,out c,out e,out k,out u))throw new Win32Exception(Marshal.GetLastWin32Error());
    CreatedAt=DateTime.FromFileTimeUtc(c).ToString("o");
    int length=32768;var image=new StringBuilder(length);
    if(!QueryFullProcessImageName(handle,0,image,ref length))throw new Win32Exception(Marshal.GetLastWin32Error());
    Executable=image.ToString();
   }catch{Dispose();throw;}
  }
  public bool WaitForExit(int milliseconds){
   uint result=WaitForSingleObject(handle,checked((uint)milliseconds));
   if(result==0)return true;if(result==258)return false;throw new Win32Exception(Marshal.GetLastWin32Error());
  }
  public void Dispose(){if(handle!=IntPtr.Zero){CloseHandle(handle);handle=IntPtr.Zero;}}
 }
}
'@
}
function Get-TunnelRegistrationDigest([string]$Value){
 $sha=[Security.Cryptography.SHA256]::Create()
 try{([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}
function Get-TunnelOwnerPath([string]$LauncherDirectory,$Tunnel){
 if($Tunnel.alias -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$'){throw 'TUNNEL_ALIAS_INVALID'}
 Join-Path (Join-Path $LauncherDirectory 'tunnel-owners') ($Tunnel.alias+'.json')
}
function Get-VerifiedTunnelIdentity($Config,$Tunnel,$Status){
 if($null -eq $Status -or !$Status.PSObject.Properties['process_running'] -or $Status.process_running -isnot [bool]){throw 'TUNNEL_STATUS_UNKNOWN'}
 if(!$Status.PSObject.Properties['alias'] -or $Status.alias -cne $Tunnel.alias -or !$Status.PSObject.Properties['tunnel_id'] -or $Status.tunnel_id -cne $Tunnel.tunnelId){throw 'TUNNEL_REGISTRATION_MISMATCH'}
 if(!$Status.process_running){return $null}
 $processId=0
 if(!$Status.PSObject.Properties['process'] -or $null -eq $Status.process -or !$Status.process.PSObject.Properties['pid'] -or ![int]::TryParse([string]$Status.process.pid,[ref]$processId) -or $processId -lt 1){throw 'TUNNEL_LIFETIME_UNKNOWN'}
 if(!$Status.process.PSObject.Properties['tunnel_id'] -or $Status.process.tunnel_id -cne $Tunnel.tunnelId -or !$Status.process.PSObject.Properties['alias'] -or $Status.process.alias -cne $Tunnel.alias){throw 'TUNNEL_REGISTRATION_MISMATCH'}
 $identity=Get-ConsoleProcessIdentity $processId
 $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
 if($null -eq $identity -or $identity.userSid -cne $sid -or $identity.executable -ine $Config.tunnelExe){throw 'TUNNEL_PROCESS_OWNER_INVALID'}
 $identity
}
function Assert-TunnelOwnerReceipt($Receipt,$Identity,$Tunnel){
 if($null -eq $Identity -or $Receipt.version -ne 1 -or $Receipt.pid -ne $Identity.pid -or $Receipt.createdAt -cne $Identity.createdAt -or $Receipt.userSid -cne $Identity.userSid -or $Receipt.executable -ine $Identity.executable -or $Receipt.alias -cne $Tunnel.alias -or $Receipt.registrationDigest -cne (Get-TunnelRegistrationDigest $Tunnel.tunnelId)){throw 'TUNNEL_LIFETIME_MISMATCH'}
}
function Record-OwnedTunnel([string]$LauncherDirectory,$Config,$Tunnel,$Status,[DateTime]$LaunchedAfter){
 $identity=Get-VerifiedTunnelIdentity $Config $Tunnel $Status
 if($null -eq $identity -or [DateTime]::Parse($identity.createdAt).ToUniversalTime() -lt $LaunchedAfter.ToUniversalTime()){throw 'TUNNEL_LIFETIME_MISMATCH'}
 $file=Get-TunnelOwnerPath $LauncherDirectory $Tunnel
 if(Test-Path -LiteralPath $file){
  Assert-TunnelOwnerReceipt (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json) $identity $Tunnel
  return
 }
 $directory=Split-Path $file
 New-Item -ItemType Directory -Path $directory -Force | Out-Null
 if((Get-Item -LiteralPath $directory).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'TUNNEL_RECEIPT_PATH_INVALID'}
 $lease=New-Object Codexless.TunnelLifetime($identity.pid)
 try{
  # CIM timestamps have microsecond precision; retain the full native creation time for later stop.
  if($lease.CreatedAt.Substring(0,26) -cne $identity.createdAt.Substring(0,26) -or $lease.Executable -ine $identity.executable -or $lease.WaitForExit(0)){throw 'TUNNEL_LIFETIME_MISMATCH'}
  $receipt=[ordered]@{version=1;alias=$Tunnel.alias;pid=$identity.pid;createdAt=$identity.createdAt;nativeCreatedAt=$lease.CreatedAt;userSid=$identity.userSid;executable=$identity.executable;registrationDigest=(Get-TunnelRegistrationDigest $Tunnel.tunnelId)}
 }finally{$lease.Dispose()}
 $stream=$null
 try{$stream=[IO.File]::Open($file,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read);$bytes=[Text.Encoding]::UTF8.GetBytes(($receipt | ConvertTo-Json));$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{if($null -ne $stream){$stream.Dispose()}}
}
function Open-OwnedTunnelLifetime([string]$LauncherDirectory,$Config,$Tunnel,$Status){
 $file=Get-TunnelOwnerPath $LauncherDirectory $Tunnel
 $identity=Get-VerifiedTunnelIdentity $Config $Tunnel $Status
 if($null -eq $identity){
  if(Test-Path -LiteralPath $file){
   $saved=Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
   $old=Get-ConsoleProcessIdentity ([int]$saved.pid)
   if($null -ne $old -and $old.createdAt -ceq $saved.createdAt){throw 'TUNNEL_LIFETIME_UNPROVEN: Status cannot retire a still-existing saved process'}
   # Absent PID or a later lifetime proves the saved process exited. Never signal a reused PID.
   if($saved.version -ne 1 -or $saved.alias -cne $Tunnel.alias -or $saved.registrationDigest -cne (Get-TunnelRegistrationDigest $Tunnel.tunnelId) -or $saved.executable -ine $Config.tunnelExe -or $saved.userSid -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value){throw 'TUNNEL_LIFETIME_MISMATCH'}
   Remove-Item -LiteralPath $file -ErrorAction Stop
  }
  return $null
 }
 if(!(Test-Path -LiteralPath $file)){throw 'TUNNEL_OWNER_RECEIPT_MISSING'}
 $receipt=Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
 Assert-TunnelOwnerReceipt $receipt $identity $Tunnel
 $lease=New-Object Codexless.TunnelLifetime($identity.pid)
 try{
  if($lease.CreatedAt -cne $receipt.nativeCreatedAt -or $lease.Executable -ine $receipt.executable){throw 'TUNNEL_LIFETIME_MISMATCH'}
  if($lease.WaitForExit(0)){throw 'TUNNEL_LIFETIME_EXITED'}
  [pscustomobject]@{lease=$lease;receipt=$receipt;path=$file}
 }catch{$lease.Dispose();throw}
}
function Complete-OwnedTunnelStop($Binding){
 if(!$Binding.lease.WaitForExit(30000)){throw 'TUNNEL_STOP_LIFETIME_REMAINS'}
 $saved=Get-Content -LiteralPath $Binding.path -Raw | ConvertFrom-Json
 if($saved.pid -ne $Binding.receipt.pid -or $saved.createdAt -cne $Binding.receipt.createdAt){throw 'TUNNEL_STOP_RECEIPT_CHANGED'}
 Remove-Item -LiteralPath $Binding.path -ErrorAction Stop
}
Export-ModuleMember -Function Record-OwnedTunnel,Open-OwnedTunnelLifetime,Complete-OwnedTunnelStop,Get-VerifiedTunnelIdentity,Assert-TunnelOwnerReceipt,Get-TunnelOwnerPath
