Set-StrictMode -Version Latest

function Resolve-CompanionMutationRoot {
    param([Parameter(Mandatory=$true)][string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root) -or $Root -notmatch '^[A-Za-z]:[\\/]' -or
        $Root.Contains('"') -or $Root.Contains([char]13) -or $Root.Contains([char]10)) {
        throw 'MUTATION_ROOT_INVALID'
    }
    $full=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    if ($full.Length -le 3) { throw 'MUTATION_ROOT_INVALID' }
    $parent=Split-Path $full -Parent
    if ([string]::IsNullOrWhiteSpace($parent) -or !(Test-Path -LiteralPath $parent -PathType Container)) { throw 'MUTATION_ROOT_INVALID' }
    $cursor=$parent
    while($cursor){
        if((Get-Item -LiteralPath $cursor -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'MUTATION_ROOT_INVALID'}
        $next=Split-Path $cursor -Parent
        if([string]::IsNullOrWhiteSpace($next) -or $next -ceq $cursor){break}
        $cursor=$next
    }
    $full
}

function Get-CompanionMutationRootDigest {
    param([Parameter(Mandatory=$true)][string]$Root)
    $full=Resolve-CompanionMutationRoot $Root
    $sha=[Security.Cryptography.SHA256]::Create()
    try {
        ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($full.ToLowerInvariant())))).Replace('-','').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

if(!('Codexless.MutationAdmission' -as [type])){
Add-Type -ReferencedAssemblies 'System.Management','System.Core' -TypeDefinition @'
using System;
using System.IO;
using System.IO.Pipes;
using System.Diagnostics;
using System.Collections.Generic;
using System.Management;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace Codexless {
 public static class MutationAdmission {
  [ThreadStatic] static Dictionary<string,RootMutationLease> roots;
  [ThreadStatic] static Dictionary<string,int> hosts;
  public static RootMutationLease Controller(string digest) {
   RootMutationLease value; return roots!=null && roots.TryGetValue(digest,out value) ? value : null;
  }
  internal static void Add(string d,RootMutationLease v) { if(roots==null)roots=new Dictionary<string,RootMutationLease>();roots.Add(d,v); }
  internal static void Remove(string d) { roots.Remove(d); }
  public static bool Admitted(string d) {return Controller(d)!=null || (hosts!=null && hosts.ContainsKey(d));}
  internal static void HostEnter(string d) {if(hosts==null)hosts=new Dictionary<string,int>();if(!hosts.ContainsKey(d))hosts[d]=0;hosts[d]++;}
  internal static void HostExit(string d) {if(--hosts[d]==0)hosts.Remove(d);}
 }
 public sealed class RootMutationLease : IDisposable {
  Mutex mutex; FileStream marker; bool held,owned; int thread;
  public readonly string Digest,Token,MarkerPath;
  public bool Poisoned;
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
  static extern SafeFileHandle CreateFileW(string p,uint a,uint s,IntPtr sec,uint creation,uint flags,IntPtr template);
  [DllImport("kernel32.dll",SetLastError=true)]
  static extern bool SetFileInformationByHandle(SafeFileHandle h,int kind,ref int value,uint length);
  public static FileStream CreateRecord(string path) {
   var handle=CreateFileW(path,0xC0010000u,1u,IntPtr.Zero,1u,0x00200000u,IntPtr.Zero);
   if(handle.IsInvalid){handle.Dispose();throw new IOException("MUTATION_RECORD_UNAVAILABLE");}
   return new FileStream(handle,FileAccess.ReadWrite);
  }
  public static void RetireRecord(FileStream stream) {
   int delete=1;if(!SetFileInformationByHandle(stream.SafeFileHandle,4,ref delete,4))throw new IOException("MUTATION_RECORD_RETIRE_FAILED");
  }
  public RootMutationLease(string root,string digest) {
   Digest=digest;Token=Guid.NewGuid().ToString("N");thread=Thread.CurrentThread.ManagedThreadId;
   MarkerPath=Path.Combine(Path.GetDirectoryName(root),".codexless-mutation-"+digest+".lock");
   try {
    mutex=new Mutex(false,"Global\\CodexlessMutation-"+digest);
    try {held=mutex.WaitOne(0);}catch(AbandonedMutexException){held=true;throw new IOException("MUTATION_LOCK_ABANDONED");}
    if(!held)throw new IOException("MUTATION_CONCURRENT_OPERATION");
    if(File.Exists(MarkerPath)||Directory.Exists(MarkerPath))throw new IOException("MUTATION_LOCK_ABANDONED");
    var handle=CreateFileW(MarkerPath,0xC0010000u,1u,IntPtr.Zero,1u,0x00200000u,IntPtr.Zero);
    if(handle.IsInvalid){handle.Dispose();throw new IOException("MUTATION_LOCK_UNAVAILABLE");}
    marker=new FileStream(handle,FileAccess.ReadWrite);owned=true;
    var record="{\"version\":2,\"rootDigest\":\""+digest+"\",\"token\":\""+Token+"\",\"pid\":"+Process.GetCurrentProcess().Id+",\"processTicks\":"+Process.GetCurrentProcess().StartTime.ToUniversalTime().Ticks+"}";
    var bytes=Encoding.UTF8.GetBytes(record);marker.Write(bytes,0,bytes.Length);marker.Flush(true);
    MutationAdmission.Add(digest,this);
   }catch{Close(false);throw;}
  }
  void Close(bool success) {
   try {
    if(marker!=null){
     if(success && owned && !Poisoned){int delete=1;if(!SetFileInformationByHandle(marker.SafeFileHandle,4,ref delete,4)){Poisoned=true;throw new IOException("MUTATION_LOCK_MARKER_RETIRE_FAILED");}}
    }
   } finally {
    if(marker!=null){marker.Dispose();marker=null;}
    if(held&&mutex!=null){mutex.ReleaseMutex();held=false;}
    if(mutex!=null){mutex.Dispose();mutex=null;}
   }
  }
  public void Dispose(){if(thread!=Thread.CurrentThread.ManagedThreadId)throw new IOException("MUTATION_WRONG_THREAD");MutationAdmission.Remove(Digest);Close(true);}
 }
 public sealed class DelegatedHostServer : IDisposable {
  readonly string name,expectedCommand,expectedExe,sid; readonly int parent; readonly RootMutationLease controller;
  readonly object sync=new object(); Thread worker; NamedPipeServerStream pipe; bool closing,active; Exception failure;
  public readonly string Phase;
  public string PipeName {get{return name;}}
  public DelegatedHostServer(RootMutationLease owner,string exe,string arguments,string userSid,int schedulerPid,string phase){
   controller=owner;expectedExe=exe;expectedCommand=arguments;sid=userSid;parent=schedulerPid;Phase=phase;
   name="CodexlessHostLease-"+Guid.NewGuid().ToString("N");
   pipe=NewPipe();worker=new Thread(Run);worker.IsBackground=true;worker.Start();
  }
  NamedPipeServerStream NewPipe(){
   var acl=new PipeSecurity();acl.SetAccessRuleProtection(true,false);
   acl.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(sid),PipeAccessRights.FullControl,AccessControlType.Allow));
   return new NamedPipeServerStream(name,PipeDirection.InOut,1,PipeTransmissionMode.Byte,PipeOptions.Asynchronous,4096,4096,acl);
  }
  [DllImport("kernel32.dll",SetLastError=true)]static extern bool GetNamedPipeClientProcessId(SafePipeHandle h,out uint pid);
  bool ValidatePeer(NamedPipeServerStream p){
   uint id;if(!GetNamedPipeClientProcessId(p.SafePipeHandle,out id))return false;
   using(var process=Process.GetProcessById((int)id)) {
    var keep=process.Handle;
    using(var search=new ManagementObjectSearcher("SELECT ExecutablePath,CommandLine,ParentProcessId FROM Win32_Process WHERE ProcessId="+id))
    using(var results=search.Get())foreach(ManagementObject obj in results){
     using(obj){
      if(Convert.ToInt32(obj["ParentProcessId"])!=parent || !String.Equals(Convert.ToString(obj["ExecutablePath"]),expectedExe,StringComparison.OrdinalIgnoreCase))return false;
      string cmd=Convert.ToString(obj["CommandLine"]);
      if(cmd!="\""+expectedExe+"\" "+expectedCommand && cmd!=expectedExe+" "+expectedCommand)return false;
      string peer=null;p.RunAsClient(()=>peer=WindowsIdentity.GetCurrent().User.Value);
      return peer==sid && !process.HasExited;
     }
    }
   }
   return false;
  }
  void Run(){
   try {
    while(true){
     NamedPipeServerStream current;lock(sync){if(closing)return;current=pipe;}
     current.WaitForConnection();
     // Exact native client PID, executable, action argv, Scheduler parent and SID.
     bool valid=current.ReadByte()==1 && ValidatePeer(current);
     lock(sync){if(closing)return;active=valid;}
     if(valid){
      current.WriteByte(1);current.Flush();
      if(current.ReadByte()!=1)throw new IOException("MUTATION_DELEGATE_INTERRUPTED");
     }
     lock(sync){active=false;current.Dispose();pipe=null;Monitor.PulseAll(sync);if(closing)return;pipe=NewPipe();}
    }
   }catch(Exception e){lock(sync){if(!closing||active){failure=e;controller.Poisoned=true;}active=false;Monitor.PulseAll(sync);}}
  }
  public void Dispose(){
   lock(sync){closing=true;if(!active&&pipe!=null)pipe.Dispose();}
   // No controller mutation may resume while any admitted host scope remains.
   if(!worker.Join(120000)){controller.Poisoned=true;throw new IOException("MUTATION_DELEGATE_DRAIN_TIMEOUT");}
   if(pipe!=null){pipe.Dispose();pipe=null;}
   if(failure!=null){controller.Poisoned=true;throw new IOException("MUTATION_DELEGATE_INTERRUPTED",failure);}
  }
 }
 public sealed class DelegatedHostClient : IDisposable {
  NamedPipeClientStream pipe;Process controller;readonly string digest;bool entered;
  [DllImport("kernel32.dll",SetLastError=true)]static extern bool GetNamedPipeServerProcessId(SafePipeHandle h,out uint pid);
  public DelegatedHostClient(string name,int controllerPid,long ticks,string rootDigest){
   digest=rootDigest;
   try{
    pipe=new NamedPipeClientStream(".",name,PipeDirection.InOut,PipeOptions.Asynchronous,TokenImpersonationLevel.Impersonation);
    pipe.Connect(2000);uint pid;
    if(!GetNamedPipeServerProcessId(pipe.SafePipeHandle,out pid)||pid!=(uint)controllerPid)throw new IOException("MUTATION_DELEGATE_OWNER_INVALID");
    controller=Process.GetProcessById(controllerPid);var held=controller.Handle;
    if(controller.StartTime.ToUniversalTime().Ticks!=ticks||controller.HasExited)throw new IOException("MUTATION_DELEGATE_OWNER_INVALID");
    pipe.WriteByte(1);pipe.Flush();
    var read=pipe.ReadAsync(new byte[1],0,1);
    if(!read.Wait(5000)||read.Result!=1)throw new IOException("MUTATION_DELEGATE_REFUSED");
    if(controller.HasExited)throw new IOException("MUTATION_DELEGATE_OWNER_EXITED");
    MutationAdmission.HostEnter(digest);entered=true;
   }catch{if(pipe!=null)pipe.Dispose();if(controller!=null)controller.Dispose();throw;}
  }
  public void Dispose(){
   try{if(entered){MutationAdmission.HostExit(digest);entered=false;}pipe.WriteByte(1);pipe.Flush();}
   finally{pipe.Dispose();controller.Dispose();}
  }
 }
}

'@
}
function Assert-CompanionMutationHeld {
    param([string]$Root)
    $digest=Get-CompanionMutationRootDigest $Root
    if($null -eq [Codexless.MutationAdmission]::Controller($digest)){throw 'MUTATION_LEASE_REQUIRED'}
}

function Invoke-CompanionMutationLocked {
    param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][scriptblock]$Body)
    $full=Resolve-CompanionMutationRoot $Root
    $digest=Get-CompanionMutationRootDigest $full
    $existing=[Codexless.MutationAdmission]::Controller($digest)
    if($null -ne $existing){if($existing.Poisoned){throw 'MUTATION_LEASE_POISONED'};return & $Body}
    $lease=$null
    try{
        try{$lease=[Codexless.RootMutationLease]::new($full,$digest)}catch{
            $message=$_.Exception.ToString()
            foreach($code in @('MUTATION_CONCURRENT_OPERATION','MUTATION_LOCK_ABANDONED')){if($message.Contains($code)){throw $code}}
            throw 'MUTATION_LOCK_UNAVAILABLE'
        }
        & $Body
    } finally {if($lease){$lease.Dispose()}}
}

function Invoke-CompanionResourceMutation {
    param([string]$Root,[scriptblock]$Body)
    $digest=Get-CompanionMutationRootDigest $Root
    if([Codexless.MutationAdmission]::Admitted($digest)){return & $Body}
    Invoke-CompanionMutationLocked $Root $Body
}

function Read-CompanionLeaseRecord {
    param([string]$Path)
    if((Get-Item -LiteralPath $Path -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'MUTATION_DELEGATE_INVALID'}
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try{
        if($stream.Length -gt 4096){throw 'MUTATION_DELEGATE_INVALID'}
        $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8)
        try{$reader.ReadToEnd()|ConvertFrom-Json -ErrorAction Stop}finally{$reader.Dispose()}
    }finally{$stream.Dispose()}
}

function Invoke-CompanionHostDelegation {
    param($Definition,[ValidateSet('Startup','Shutdown')][string]$Phase,[scriptblock]$Body)
    $root=Resolve-CompanionMutationRoot $Definition.LauncherDirectory
    $digest=Get-CompanionMutationRootDigest $root
    Assert-CompanionMutationHeld $root
    $controller=[Codexless.MutationAdmission]::Controller($digest)
    if($controller.Poisoned){throw 'MUTATION_LEASE_POISONED'}
    $path=$controller.MarkerPath+'.delegate'
    $server=$null;$stream=$null
    try{
        if(Test-Path -LiteralPath $path){$controller.Poisoned=$true;throw 'MUTATION_DELEGATE_STALE'}
        $service=Get-CimInstance Win32_Service -Filter "Name='Schedule'" -ErrorAction Stop
        if($service.State -cne 'Running' -or $service.StartName -ine 'LocalSystem'){throw 'MUTATION_SCHEDULER_UNAVAILABLE'}
        $server=[Codexless.DelegatedHostServer]::new($controller,$Definition.PowerShellExe,$Definition.Arguments,$Definition.UserSid,[int]$service.ProcessId,$Phase)
        $record=[ordered]@{version=1;rootDigest=$digest;token=$controller.Token;pid=$PID;processTicks=[Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().Ticks;pipe=$server.PipeName;taskName=$Definition.Name;transactionId=$Definition.TransactionId;generationId=$Definition.GenerationId;phase=$Phase}
        $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($record|ConvertTo-Json -Compress))
        $stream=[Codexless.RootMutationLease]::CreateRecord($path)
        $stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)
        & $Body
    }finally{
        try{if($server){$server.Dispose()}}finally{
            if($stream){try{if(!$controller.Poisoned){[Codexless.RootMutationLease]::RetireRecord($stream)}}catch{$controller.Poisoned=$true;throw}finally{$stream.Dispose()}}
        }
    }
}

function Enter-CompanionHostLease {
    param($Definition,[ValidateSet('Startup','Shutdown')][string]$Phase)
    $root=Resolve-CompanionMutationRoot $Definition.LauncherDirectory
    $digest=Get-CompanionMutationRootDigest $root
    # Autonomous logon/supervision takes the ordinary root lock. An incomplete
    # transaction always requires a live controller's exact delegated admission.
    $local=$null
    try{$local=[Codexless.RootMutationLease]::new($root,$digest)}catch{
        if(!$_.Exception.ToString().Contains('MUTATION_CONCURRENT_OPERATION')){throw 'MUTATION_LOCK_ABANDONED'}
    }
    if($local){
        if(Test-Path -LiteralPath (Join-Path $root 'incomplete-install.json')){$local.Dispose();throw 'MUTATION_TRANSACTION_FENCED'}
        return $local
    }
    try{
        $marker=Join-Path (Split-Path $root -Parent) ('.codexless-mutation-'+$digest+'.lock')
        $owner=Read-CompanionLeaseRecord $marker
        $lease=Read-CompanionLeaseRecord ($marker+'.delegate')
        if($owner.version -ne 2 -or $lease.version -ne 1 -or $lease.rootDigest -cne $digest -or $owner.rootDigest -cne $digest -or
           $owner.token -cne $lease.token -or $owner.pid -ne $lease.pid -or $owner.processTicks -ne $lease.processTicks -or
           $lease.taskName -cne $Definition.Name -or [string]$lease.transactionId -cne [string]$Definition.TransactionId -or
           [string]$lease.generationId -cne [string]$Definition.GenerationId -or $lease.phase -cne $Phase -or
           $lease.pipe -cnotmatch '^CodexlessHostLease-[0-9a-f]{32}$'){throw 'invalid'}
        [Codexless.DelegatedHostClient]::new($lease.pipe,[int]$lease.pid,[long]$lease.processTicks,$digest)
    }catch{throw 'MUTATION_CONCURRENT_OPERATION: No matching live host admission.'}
}

Export-ModuleMember -Function Get-CompanionMutationRootDigest,Invoke-CompanionMutationLocked,Assert-CompanionMutationHeld,Invoke-CompanionResourceMutation,Invoke-CompanionHostDelegation,Enter-CompanionHostLease
