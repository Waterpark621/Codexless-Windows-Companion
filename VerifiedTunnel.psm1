Import-Module (Join-Path $PSScriptRoot 'MutationLock.psm1') -DisableNameChecking
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'PrivateConsole.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'CompanionRuntime.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'GenerationIdentity.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'ArtifactProvenance.psm1') -DisableNameChecking
if(!('Codexless.TunnelLifetime' -as [type])){
 Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using Microsoft.Win32.SafeHandles;
using System.Runtime.InteropServices;
using System.Text;
namespace Codexless {
 public sealed class TunnelLifetime : IDisposable {
  IntPtr handle;
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFile(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetFileInformationByHandle(SafeFileHandle file,int kind,byte[] data,uint size);
  public static bool RetireReceipt(string path,byte[] expected){
   // Hold the exact file object without write/delete sharing across compare and
   // disposition. A replacement cannot be deleted after the byte check.
   using(var file=CreateFile(path,0x80000000|0x10000,1,IntPtr.Zero,3,0x00200000,IntPtr.Zero)){
    if(file.IsInvalid)return false;
    using(var input=new FileStream(file,FileAccess.Read)){
     if(input.Length!=expected.Length || input.Length>16384)return false;
     byte[] bytes=new byte[expected.Length];int offset=0,count;
     while(offset<bytes.Length && (count=input.Read(bytes,offset,bytes.Length-offset))>0)offset+=count;
     if(offset!=bytes.Length)return false;
     for(int i=0;i<bytes.Length;i++)if(bytes[i]!=expected[i])return false;
     return SetFileInformationByHandle(file,4,new byte[]{1},1);
    }
   }
  }
  [DllImport("shell32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CommandLineToArgvW(string command,out int count);
  [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);
  public static string[] ParseArgs(string command){
   if(String.IsNullOrEmpty(command) || command.Length>32768)throw new ArgumentException();
   int count;IntPtr memory=CommandLineToArgvW(command,out count);if(memory==IntPtr.Zero)throw new Win32Exception();
   try{var args=new string[count];for(int i=0;i<count;i++)args[i]=Marshal.PtrToStringUni(Marshal.ReadIntPtr(memory,i*IntPtr.Size));return args;}finally{LocalFree(memory);}
  }
  [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint access,bool inherit,int pid);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetProcessTimes(IntPtr process,out long created,out long exited,out long kernel,out long user);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool QueryFullProcessImageName(IntPtr process,uint flags,StringBuilder name,ref int size);
  [DllImport("kernel32.dll",SetLastError=true)] static extern uint WaitForSingleObject(IntPtr handle,uint timeout);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
  public static string QueryRetainedCreationTime(int pid){
   IntPtr process=OpenProcess(0x1000,false,pid);if(process==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error());
   try{long c,e,k,u;if(!GetProcessTimes(process,out c,out e,out k,out u))throw new Win32Exception(Marshal.GetLastWin32Error());return DateTime.FromFileTimeUtc(c).ToString("o");}finally{CloseHandle(process);}
  }
  public IntPtr NativeHandle {get {return handle;}}
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
function Get-TunnelGenerationProof($Config,$Tunnel) {
 $context=Get-TunnelRuntimeContext $Config $Tunnel
 Assert-CompanionGenerationContract $context.owner.generationContract $Config
 $context
}
function Assert-TunnelExecutable($Config) {
 $policy=Get-ArtifactPolicy tunnel
 $cursor=[IO.Path]::GetFullPath($Config.tunnelExe)
 while($cursor){if((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'TUNNEL_EXECUTABLE_INVALID'};$cursor=Split-Path $cursor -Parent}
 if((Get-FileHash -LiteralPath $Config.tunnelExe -Algorithm SHA256).Hash.ToLowerInvariant() -cne $policy.executableSha256){throw 'TUNNEL_EXECUTABLE_INVALID'}
 $policy.executableSha256
}
function Get-TunnelCommandArguments([string]$Command){[Codexless.TunnelLifetime]::ParseArgs($Command)}
function Assert-TunnelManagedCommand($Identity,$Config,$Tunnel,$Context) {
 $actual=@(Get-TunnelCommandArguments $Identity.commandLine)
 $expected=@([string]$Config.tunnelExe,'run','--profile-dir',[string]$Context.profileRoot,'--profile',[string]$Tunnel.alias)
 if($actual.Count -ne $expected.Count){throw 'TUNNEL_COMMAND_MISMATCH'}
 for($i=0;$i-lt $actual.Count;$i++){if($actual[$i] -cne $expected[$i]){throw 'TUNNEL_COMMAND_MISMATCH'}}
}
function Read-TunnelReceipt([string]$Path) {
 $cursor=$Path
 while($cursor){if((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'TUNNEL_RECEIPT_PATH_INVALID'};$cursor=Split-Path $cursor -Parent}
 if((Get-Item -LiteralPath $Path).Length -gt 16384){throw 'TUNNEL_RECEIPT_INVALID'}
 $bytes=[IO.File]::ReadAllBytes($Path)
 [pscustomobject]@{bytes=$bytes;receipt=([Text.UTF8Encoding]::new($false,$true).GetString($bytes)|ConvertFrom-Json)}
}
function Assert-TunnelOwnerReceipt($Receipt,$Identity,$Tunnel,$Config) {
 $context=Get-TunnelGenerationProof $Config $Tunnel
 $hash=Assert-TunnelExecutable $Config
 if($null -eq $Identity -or $Receipt.version -ne 2 -or $Receipt.pid -ne $Identity.pid -or $Receipt.createdAt -cne $Identity.createdAt -or $Receipt.userSid -cne $Identity.userSid -or $Receipt.executable -ine $Identity.executable -or $Receipt.alias -cne $Tunnel.alias -or $Receipt.registrationDigest -cne (Get-TunnelRegistrationDigest $Tunnel.tunnelId) -or $Receipt.generationSha256 -cne $context.generationSha256 -or $Receipt.executableSha256 -cne $hash -or $Receipt.namespaceDigest -cne (Get-TunnelRegistrationDigest $context.stateRoot)){throw 'TUNNEL_LIFETIME_MISMATCH'}
 try{
  $native=[DateTimeOffset]::Parse($Receipt.nativeCreatedAt)
  if($Receipt.connectPid -le 0 -or $Receipt.connectPid -ne $Identity.parentPid -or $native -lt [DateTimeOffset]::Parse($Receipt.connectCreatedAt) -or $native -gt [DateTimeOffset]::Parse($Receipt.connectExitedAt)){throw 'invalid'}
 }catch{throw 'TUNNEL_LIFETIME_MISMATCH'}
 Assert-TunnelManagedCommand $Identity $Config $Tunnel $context
}
function Record-OwnedTunnelCore([string]$LauncherDirectory,$Config,$Tunnel,$Status,$LaunchEvidence){
 $context=Get-TunnelGenerationProof $Config $Tunnel
 $hash=Assert-TunnelExecutable $Config
 $identity=Get-VerifiedTunnelIdentity $Config $Tunnel $Status
 if($null -eq $identity -or !(Test-TunnelConnectCompleted $LaunchEvidence) -or $LaunchEvidence.ProcessId -le 0 -or $identity.parentPid -ne $LaunchEvidence.ProcessId -or $Status.healthy -isnot [bool] -or $Status.ready -isnot [bool] -or $Status.process.mode -cne 'process'){throw 'TUNNEL_LAUNCH_PROVENANCE_INVALID'}
 Assert-TunnelManagedCommand $identity $Config $Tunnel $context
 $file=Get-TunnelOwnerPath $LauncherDirectory $Tunnel
 if(Test-Path -LiteralPath $file){throw 'TUNNEL_OWNER_RECEIPT_EXISTS'}
 $directory=Split-Path $file
 New-Item -ItemType Directory -Path $directory -Force | Out-Null
 $cursor=$directory
 while($cursor){if((Get-Item -LiteralPath $cursor).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'TUNNEL_RECEIPT_PATH_INVALID'};$cursor=Split-Path $cursor -Parent}
 $lease=New-Object Codexless.TunnelLifetime($identity.pid)
 try{
  $native=[DateTimeOffset]::Parse($lease.CreatedAt)
  if($native -lt [DateTimeOffset]::Parse($LaunchEvidence.CreatedAt) -or $native -gt [DateTimeOffset]::Parse($LaunchEvidence.ExitedAt) -or $lease.CreatedAt.Substring(0,26) -cne $identity.createdAt.Substring(0,26) -or $lease.Executable -ine $identity.executable -or $lease.WaitForExit(0)){throw 'TUNNEL_LAUNCH_PROVENANCE_INVALID'}
  $receipt=[ordered]@{version=2;alias=$Tunnel.alias;pid=$identity.pid;createdAt=$identity.createdAt;nativeCreatedAt=$lease.CreatedAt;userSid=$identity.userSid;executable=$identity.executable;executableSha256=$hash;registrationDigest=(Get-TunnelRegistrationDigest $Tunnel.tunnelId);generationSha256=$context.generationSha256;namespaceDigest=(Get-TunnelRegistrationDigest $context.stateRoot);connectPid=$LaunchEvidence.ProcessId;connectCreatedAt=$LaunchEvidence.CreatedAt;connectExitedAt=$LaunchEvidence.ExitedAt}
  $stream=$null
  try{$stream=[IO.File]::Open($file,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read);$bytes=[Text.Encoding]::UTF8.GetBytes(($receipt|ConvertTo-Json));$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{if($stream){$stream.Dispose()}}
 }finally{$lease.Dispose()}
}
function Open-OwnedTunnelLifetime([string]$LauncherDirectory,$Config,$Tunnel,$Status){
 $file=Get-TunnelOwnerPath $LauncherDirectory $Tunnel
 $identity=Get-VerifiedTunnelIdentity $Config $Tunnel $Status
 if($null -eq $identity){
  # Retain evidence when status is inactive: explicit recovery owns retirement.
  if(Test-Path -LiteralPath $file){throw 'TUNNEL_LIFETIME_UNPROVEN'}
  return $null
 }
 if(!(Test-Path -LiteralPath $file)){throw 'TUNNEL_OWNER_RECEIPT_MISSING'}
 $snapshot=Read-TunnelReceipt $file;$receipt=$snapshot.receipt
 Assert-TunnelOwnerReceipt $receipt $identity $Tunnel $Config
 $lease=New-Object Codexless.TunnelLifetime($identity.pid)
 try{
  if($lease.CreatedAt -cne $receipt.nativeCreatedAt -or $lease.Executable -ine $receipt.executable){throw 'TUNNEL_LIFETIME_MISMATCH'}
  if($lease.WaitForExit(0)){throw 'TUNNEL_LIFETIME_EXITED'}
  [pscustomobject]@{lease=$lease;receipt=$receipt;bytes=$snapshot.bytes;path=$file}
 }catch{$lease.Dispose();throw}
}
function Test-TunnelGenerationUnlaunched($Config,$Tunnel) {
 $context=Get-TunnelGenerationProof $Config $Tunnel
 !(Test-Path -LiteralPath $context.stateRoot) -and !(Test-Path -LiteralPath (Get-TunnelOwnerPath $Config.companionRoot $Tunnel))
}
function Open-TunnelSiblingAdmission([string]$LauncherDirectory,$Config,$Tunnel) {
 $leases=[Collections.ArrayList]::new()
 try {
  $profiles=@()
  if($Config.PSObject.Properties['tunnels']){$profiles=@($Config.tunnels)}
  $clientName=[IO.Path]::GetFileName([string]$Config.tunnelExe).Replace("'","''")
  foreach($process in @(Get-CimInstance Win32_Process -Filter ("Name='tunnel-client.exe' OR Name='"+$clientName+"'") -OperationTimeoutSec 10 -ErrorAction Stop)){
   $bindings=@()
   foreach($sibling in $profiles){
    if($sibling.alias -ceq $Tunnel.alias){continue}
    $binding=$null
    try {$binding=Open-OwnedTunnelLifetime $LauncherDirectory $Config $sibling (Get-TunnelStatus $Config $sibling)}catch {continue}
    if($null -ne $binding){
     if($binding.receipt.pid -eq $process.ProcessId){$bindings += $binding}else{$binding.lease.Dispose()}
    }
   }
   foreach($binding in $bindings){[void]$leases.Add($binding.lease)}
   if($bindings.Count -ne 1){throw 'TUNNEL_FOREIGN_PROCESS_PRESENT'}
  }
  # Keep exact sibling lifetimes pinned until this connect has completed.
  [pscustomobject]@{leases=$leases}
 } catch {foreach($lease in $leases){$lease.Dispose()};throw}
}
function Start-OwnedTunnelCore([string]$LauncherDirectory,$Config,$Tunnel,[string]$PlainKey) {
 $context=Get-TunnelGenerationProof $Config $Tunnel
 Assert-TunnelExecutable $Config|Out-Null
 if(!(Test-TunnelGenerationUnlaunched $Config $Tunnel)){throw 'TUNNEL_CONNECT_GENERATION_FENCED'}
 $admission=Open-TunnelSiblingAdmission $LauncherDirectory $Config $Tunnel
 try {
 $ownerIdentity=Get-ConsoleProcessIdentity ([int]$context.owner.pid)
 if($null -eq $ownerIdentity -or $ownerIdentity.createdAt -cne $context.owner.createdAt -or $ownerIdentity.userSid -cne $context.owner.userSid){throw 'TUNNEL_GENERATION_OWNER_INVALID'}
 # Atomic fresh directory reservation. Every failed attempt stays fenced.
 $parent=Split-Path $context.stateRoot -Parent
 New-Item -ItemType Directory -Path $parent -Force|Out-Null
 New-Item -ItemType Directory -Path $context.stateRoot -ErrorAction Stop|Out-Null
 [IO.File]::WriteAllText($context.intentPath,('{"version":1,"state":"fenced","generationSha256":"'+$context.generationSha256+'"}'))
 try{
  $launch=Connect-TunnelRuntime $Config $Tunnel $PlainKey
  $status=Get-TunnelStatus $Config $Tunnel
  Record-OwnedTunnel $LauncherDirectory $Config $Tunnel $status $launch
  Test-OwnedTunnel $LauncherDirectory $Config $Tunnel $status
 }finally{$PlainKey=$null;$launch=$null;$status=$null}
 }finally{foreach($lease in $admission.leases){$lease.Dispose()}}
}
function Stop-OwnedTunnelCore([string]$LauncherDirectory,$Config,$Tunnel) {
 if(Test-TunnelGenerationUnlaunched $Config $Tunnel){return}
 $binding=Open-OwnedTunnelLifetime $LauncherDirectory $Config $Tunnel (Get-TunnelStatus $Config $Tunnel)
 if($null -eq $binding){return}
 $context=Get-TunnelGenerationProof $Config $Tunnel
 try{
  if($binding.lease.WaitForExit(0)){throw 'TUNNEL_STOP_LIFETIME_UNCERTAIN'}
  # The official stop receives an isolated immutable input snapshot, never an
  # ambient vendor process table that could target another PID or alias.
  $stopRoot=Join-Path $context.stateRoot ('stop-'+[Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $stopRoot -ErrorAction Stop|Out-Null
  $aliases=@{};$processes=@{}
  $aliases[$Tunnel.alias]=@{alias=$Tunnel.alias;tunnel_id=$Tunnel.tunnelId}
  $processes[$Tunnel.alias]=@{alias=$Tunnel.alias;tunnel_id=$Tunnel.tunnelId;pid=$binding.receipt.pid;mode='process'}
  [IO.File]::WriteAllText((Join-Path $stopRoot 'aliases.yaml'),($aliases|ConvertTo-Json -Depth 4))
  [IO.File]::WriteAllText((Join-Path $stopRoot 'processes.yaml'),($processes|ConvertTo-Json -Depth 4))
  Assert-TunnelReceiptUnchanged $binding
  $result=Invoke-TunnelNative $Config $Tunnel @('runtimes','stop',[string]$Tunnel.alias,'--json') 5000 -StateRoot $stopRoot -GuardHandle $binding.lease.NativeHandle
  if(!$result.Ok -or !$result.GuardTransferred){throw 'TUNNEL_STOP_NATIVE_UNCERTAIN'}
  $status=$result.Stdout|ConvertFrom-Json
  if($status.stopped -isnot [bool] -or !$status.stopped -or $status.alias -cne $Tunnel.alias -or $status.tunnel_id -cne $Tunnel.tunnelId){throw 'TUNNEL_STOP_NATIVE_UNCERTAIN'}
  Complete-OwnedTunnelStop $binding
 }finally{$binding.lease.Dispose();$result=$null}
}
function Test-OwnedTunnel([string]$LauncherDirectory,$Config,$Tunnel,$Status){
 $binding=Open-OwnedTunnelLifetime $LauncherDirectory $Config $Tunnel $Status
 if($null -eq $binding){return $false}
 try{$true}finally{$binding.lease.Dispose()}
}
function Assert-TunnelReceiptUnchanged($Binding) {
 $current=(Read-TunnelReceipt $Binding.path).bytes
 if([Convert]::ToBase64String($current) -cne [Convert]::ToBase64String($Binding.bytes)){throw 'TUNNEL_STOP_RECEIPT_CHANGED'}
}
function Complete-OwnedTunnelStopCore($Binding){
 if(!$Binding.lease.WaitForExit(30000)){throw 'TUNNEL_STOP_LIFETIME_REMAINS'}
 Assert-TunnelReceiptUnchanged $Binding
 if(![Codexless.TunnelLifetime]::RetireReceipt($Binding.path,$Binding.bytes)){throw 'TUNNEL_STOP_RECEIPT_CHANGED'}
}
function Start-OwnedTunnel([string]$LauncherDirectory,$Config,$Tunnel,[string]$PlainKey) {
 Invoke-CompanionResourceMutation $LauncherDirectory {Start-OwnedTunnelCore $LauncherDirectory $Config $Tunnel $PlainKey}
}
function Stop-OwnedTunnel([string]$LauncherDirectory,$Config,$Tunnel) {
 Invoke-CompanionResourceMutation $LauncherDirectory {Stop-OwnedTunnelCore $LauncherDirectory $Config $Tunnel}
}
function Record-OwnedTunnel([string]$LauncherDirectory,$Config,$Tunnel,$Status,$LaunchEvidence) {
 Invoke-CompanionResourceMutation $LauncherDirectory {Record-OwnedTunnelCore $LauncherDirectory $Config $Tunnel $Status $LaunchEvidence}
}
function Complete-OwnedTunnelStop($Binding) {
 Invoke-CompanionResourceMutation (Split-Path (Split-Path $Binding.path -Parent) -Parent) {Complete-OwnedTunnelStopCore $Binding}
}
Export-ModuleMember -Function Record-OwnedTunnel,Open-OwnedTunnelLifetime,Test-OwnedTunnel,Complete-OwnedTunnelStop,Get-VerifiedTunnelIdentity,Assert-TunnelOwnerReceipt,Get-TunnelOwnerPath,Start-OwnedTunnel,Stop-OwnedTunnel,Test-TunnelGenerationUnlaunched
