Set-StrictMode -Version Latest
if(!('Codexless.BoundedNative' -as [type])){
Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
namespace Codexless {
 public sealed class NativeResult {
  public bool Ok, TimedOut, OutputOverflow, LifetimeMayRemain, GuardTransferred, Suspended;
  public int ExitCode = -1, ProcessId;
  public string CreatedAt, ExitedAt, Stdout, Code;
 }
 public static class BoundedNative {
  static string Quote(string value) {
   if(value==null || value.IndexOfAny(new char[]{'\0','\r','\n'})>=0)throw new ArgumentException();
   var b=new StringBuilder("\"");int slashes=0;
   foreach(char c in value){
    if(c=='\\'){slashes++;continue;}
    if(c=='"'){b.Append('\\',slashes*2+1);b.Append(c);}else{b.Append('\\',slashes);b.Append(c);}
    slashes=0;
   }
   b.Append('\\',slashes*2);b.Append('"');return b.ToString();
  }
  sealed class Capture {
   public readonly StringBuilder Text=new StringBuilder();public bool Overflow;
   public async Task Drain(StreamReader reader,int limit,bool retain){
    char[] buffer=new char[1024];int total=0,count;
    while((count=await reader.ReadAsync(buffer,0,buffer.Length).ConfigureAwait(false))>0){
     int available=Math.Max(0,limit-total);
     if(retain && available>0)Text.Append(buffer,0,Math.Min(count,available));
     if(count>available)Overflow=true;
     total=Math.Min(limit,total+count);
    }
   }
  }
  [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct StartupInfo {
   public int cb;public string reserved,desktop,title;public int x,y,xsize,ysize,xcount,ycount,fill,flags;public short show,reserved2;public IntPtr reservedBytes,input,output,error;
  }
  [StructLayout(LayoutKind.Sequential)] struct StartupInfoEx {public StartupInfo info;public IntPtr attributes;}
  [StructLayout(LayoutKind.Sequential)] struct ProcessInfo {public IntPtr process,thread;public int pid,tid;}
  [StructLayout(LayoutKind.Sequential)] struct SecurityAttributes {public int size;public IntPtr descriptor;[MarshalAs(UnmanagedType.Bool)] public bool inherit;}
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool CreatePipe(out IntPtr read,out IntPtr write,ref SecurityAttributes security,int size);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetHandleInformation(IntPtr handle,uint mask,uint flags);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
  [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr GetCurrentProcess();
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool DuplicateHandle(IntPtr sourceProcess,IntPtr source,IntPtr destinationProcess,out IntPtr destination,uint access,bool inherit,uint options);
  [DllImport("kernel32.dll",SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool InitializeProcThreadAttributeList(IntPtr list,int count,int flags,ref IntPtr size);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool UpdateProcThreadAttribute(IntPtr list,uint flags,IntPtr attribute,IntPtr value,IntPtr size,IntPtr previous,IntPtr returned);
  [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr list);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcess(string application,StringBuilder command,IntPtr processSecurity,IntPtr threadSecurity,bool inherit,uint flags,IntPtr environment,string directory,ref StartupInfoEx startup,out ProcessInfo process);
  static Process StartGuarded(ProcessStartInfo info,IntPtr guard,NativeResult result,out StreamReader stdout,out StreamReader stderr){
   stdout=null;stderr=null;
   IntPtr or=IntPtr.Zero,ow=IntPtr.Zero,er=IntPtr.Zero,ew=IntPtr.Zero,ir=IntPtr.Zero,iw=IntPtr.Zero;
   IntPtr attributes=IntPtr.Zero,handles=IntPtr.Zero,environment=IntPtr.Zero;
   ProcessInfo pi=new ProcessInfo();bool initialized=false;
   try{
    var security=new SecurityAttributes();security.size=Marshal.SizeOf(security);security.inherit=true;
    if(!CreatePipe(out or,out ow,ref security,0)||!CreatePipe(out er,out ew,ref security,0)||!CreatePipe(out ir,out iw,ref security,0))throw new Win32Exception(Marshal.GetLastWin32Error());
    if(!SetHandleInformation(or,1,0)||!SetHandleInformation(er,1,0)||!SetHandleInformation(iw,1,0))throw new Win32Exception(Marshal.GetLastWin32Error());
    IntPtr size=IntPtr.Zero;InitializeProcThreadAttributeList(IntPtr.Zero,1,0,ref size);
    attributes=Marshal.AllocHGlobal(size);
    if(!InitializeProcThreadAttributeList(attributes,1,0,ref size))throw new Win32Exception(Marshal.GetLastWin32Error());initialized=true;
    handles=Marshal.AllocHGlobal(IntPtr.Size*3);Marshal.WriteIntPtr(handles,0,ir);Marshal.WriteIntPtr(handles,IntPtr.Size,ow);Marshal.WriteIntPtr(handles,IntPtr.Size*2,ew);
    if(!UpdateProcThreadAttribute(attributes,0,new IntPtr(0x20002),handles,new IntPtr(IntPtr.Size*3),IntPtr.Zero,IntPtr.Zero))throw new Win32Exception(Marshal.GetLastWin32Error());
    var entries=new List<string>();foreach(string name in info.EnvironmentVariables.Keys)entries.Add(name+"="+info.EnvironmentVariables[name]);entries.Sort(StringComparer.OrdinalIgnoreCase);
    environment=Marshal.StringToHGlobalUni(String.Join("\0",entries)+"\0\0");
    var startup=new StartupInfoEx();startup.info.cb=Marshal.SizeOf(startup);startup.info.flags=0x100;startup.info.input=ir;startup.info.output=ow;startup.info.error=ew;startup.attributes=attributes;
    // Suspended, Unicode environment, no window, exact inherited stdio list.
    if(!CreateProcess(info.FileName,new StringBuilder(Quote(info.FileName)+" "+info.Arguments),IntPtr.Zero,IntPtr.Zero,true,0x08080404,environment,info.WorkingDirectory,ref startup,out pi))throw new Win32Exception(Marshal.GetLastWin32Error());
    result.LifetimeMayRemain=true;result.ProcessId=pi.pid;
    IntPtr transferred;
    if(!DuplicateHandle(GetCurrentProcess(),guard,pi.process,out transferred,0,false,2)){
     // No stop code has run. Retain a suspended/fenced native lifetime; no kill.
     result.Code="NATIVE_GUARD_UNAVAILABLE";result.Suspended=true;return null;
    }
    result.GuardTransferred=true;
    stdout=new StreamReader(new FileStream(new Microsoft.Win32.SafeHandles.SafeFileHandle(or,true),FileAccess.Read));or=IntPtr.Zero;
    stderr=new StreamReader(new FileStream(new Microsoft.Win32.SafeHandles.SafeFileHandle(er,true),FileAccess.Read));er=IntPtr.Zero;
    var process=Process.GetProcessById(pi.pid);
    // GetProcessById supplies a lazy PID association. Anchor its managed
    // process handle while the native child is still suspended and pi.process
    // pins that exact lifetime. WaitForExit's temporary handle alone does not
    // preserve ExitCode/ExitTime after a short-lived guarded child exits.
    try{
     IntPtr anchored=process.Handle;
     result.CreatedAt=process.StartTime.ToUniversalTime().ToString("o");
    }catch{
     process.Dispose();result.Code="NATIVE_GUARD_UNAVAILABLE";result.Suspended=true;return null;
    }
    if(ResumeThread(pi.thread)==0xffffffff){process.Dispose();result.Code="NATIVE_GUARD_UNAVAILABLE";result.Suspended=true;return null;}
    return process;
   }finally{
    foreach(IntPtr handle in new IntPtr[]{or,ow,er,ew,ir,iw,pi.thread,pi.process})if(handle!=IntPtr.Zero)CloseHandle(handle);
    if(initialized)DeleteProcThreadAttributeList(attributes);
    if(attributes!=IntPtr.Zero)Marshal.FreeHGlobal(attributes);if(handles!=IntPtr.Zero)Marshal.FreeHGlobal(handles);if(environment!=IntPtr.Zero)Marshal.FreeHGlobal(environment);
   }
  }

  public static NativeResult Run(string exe,string sha256,string[] args,string cwd,int timeout,int limit,Dictionary<string,string> environment,IntPtr guard){
   var result=new NativeResult();Process process=null;StreamReader stdout=null,stderr=null;var clock=Stopwatch.StartNew();
   try{
    using(var image=File.Open(exe,FileMode.Open,FileAccess.Read,FileShare.Read)){
     if(image.Length<=0 || image.Length>134217728){result.Code="NATIVE_EXECUTABLE_MISMATCH";return result;}
     using(var hash=SHA256.Create()){
      byte[] buffer=new byte[65536];int count;
      while((count=image.Read(buffer,0,buffer.Length))>0){
       if(clock.ElapsedMilliseconds>=timeout){result.TimedOut=true;result.Code="NATIVE_TIMEOUT";return result;}
       hash.TransformBlock(buffer,0,count,buffer,0);
      }
      hash.TransformFinalBlock(new byte[0],0,0);
      string actual=BitConverter.ToString(hash.Hash).Replace("-","").ToLowerInvariant();
      if(actual!=sha256){result.Code="NATIVE_EXECUTABLE_MISMATCH";return result;}
     }
     var command=new StringBuilder();foreach(string arg in args){if(command.Length>0)command.Append(' ');command.Append(Quote(arg));}
     var info=new ProcessStartInfo(exe,command.ToString());info.WorkingDirectory=cwd;
     info.UseShellExecute=false;info.CreateNoWindow=true;info.RedirectStandardOutput=true;info.RedirectStandardError=true;
     info.EnvironmentVariables.Remove("NODE_OPTIONS");
     foreach(string name in new string[]{"CONTROL_PLANE_API_KEY","OPENAI_ADMIN_KEY","OPENAI_API_KEY","TUNNEL_CLIENT_STATE_DIR","TUNNEL_CLIENT_PROFILE_DIR"})info.EnvironmentVariables.Remove(name);
     foreach(var entry in environment)info.EnvironmentVariables[entry.Key]=entry.Value;

     if(clock.ElapsedMilliseconds>=timeout){result.TimedOut=true;result.Code="NATIVE_TIMEOUT";return result;}
     // An attempted launch that loses its identity query must remain fenced too.
     result.LifetimeMayRemain=true;
     try{
      if(guard!=IntPtr.Zero){process=StartGuarded(info,guard,result,out stdout,out stderr);if(process==null)return result;}
      else{process=new Process();process.StartInfo=info;if(!process.Start())throw new InvalidOperationException();stdout=process.StandardOutput;stderr=process.StandardError;}
     }catch(Win32Exception){if(result.ProcessId==0)result.LifetimeMayRemain=false;throw;}
     result.ProcessId=process.Id;result.CreatedAt=process.StartTime.ToUniversalTime().ToString("o");
     result.LifetimeMayRemain=true;
     var output=new Capture();var error=new Capture();
     Task a=output.Drain(stdout,limit,true),b=error.Drain(stderr,limit,false);
     while(!process.WaitForExit(Math.Min(25,Math.Max(1,timeout-(int)clock.ElapsedMilliseconds)))){
      if(clock.ElapsedMilliseconds>=timeout){result.TimedOut=true;result.Code="NATIVE_TIMEOUT";return result;}
     }
     result.LifetimeMayRemain=false;result.ExitCode=process.ExitCode;result.ExitedAt=process.ExitTime.ToUniversalTime().ToString("o");
     int remaining=timeout-(int)clock.ElapsedMilliseconds;
     if(remaining<=0 || !Task.WhenAll(a,b).Wait(remaining)){result.TimedOut=true;result.Code="NATIVE_TIMEOUT";return result;}
     result.OutputOverflow=output.Overflow||error.Overflow;
     if(result.OutputOverflow){result.Code="NATIVE_OUTPUT_LIMIT";return result;}
     if(result.ExitCode!=0){result.Code="NATIVE_EXIT_FAILED";return result;}
     result.Stdout=output.Text.ToString();result.Ok=true;result.Code="NATIVE_OK";return result;
    }
   }catch(Win32Exception failure){
    // A refused CreateProcess has no child lifetime. Never change security policy.
    result.Code=(failure.NativeErrorCode==577 || failure.NativeErrorCode==1260)?"NATIVE_SECURITY_POLICY_UNSUPPORTED":"NATIVE_UNAVAILABLE";return result;
   }catch{result.Code="NATIVE_UNAVAILABLE";return result;}
   finally{if(stdout!=null)stdout.Dispose();if(stderr!=null)stderr.Dispose();if(process!=null)process.Dispose();}
  }
 }
}
'@
}

function Invoke-BoundedNative {
    param([string]$Executable,[string]$ExpectedSha256,[string[]]$Arguments,[string]$WorkingDirectory,[ValidateRange(100,30000)][int]$TimeoutMs=5000,[ValidateRange(128,65536)][int]$OutputLimit=65536,[hashtable]$Environment=@{},[IntPtr]$GuardHandle=[IntPtr]::Zero)
    if($ExpectedSha256 -cnotmatch '^[0-9a-f]{64}$' -or $Executable -notmatch '^[A-Za-z]:[\\/]' -or $WorkingDirectory -notmatch '^[A-Za-z]:[\\/]'){throw 'NATIVE_CONTRACT_INVALID'}
    try{
        if(!(Test-Path -LiteralPath $Executable -PathType Leaf) -or !(Test-Path -LiteralPath $WorkingDirectory -PathType Container)){throw 'invalid'}
        foreach($path in @($Executable,$WorkingDirectory)){
            $cursor=[IO.Path]::GetFullPath($path)
            while($cursor){if((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'invalid'};$cursor=Split-Path $cursor -Parent}
        }
    }catch{throw 'NATIVE_CONTRACT_INVALID'}
    $childEnvironment=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($key in $Environment.Keys){
        if($key -cnotin @('CONTROL_PLANE_API_KEY','TUNNEL_CLIENT_STATE_DIR','TUNNEL_CLIENT_PROFILE_DIR') -or $null -eq $Environment[$key] -or [string]$Environment[$key] -match '[\x00\r\n]'){throw 'NATIVE_ENVIRONMENT_INVALID'}
        $childEnvironment.Add([string]$key,[string]$Environment[$key])
    }
    [Codexless.BoundedNative]::Run($Executable,$ExpectedSha256,$Arguments,$WorkingDirectory,$TimeoutMs,$OutputLimit,$childEnvironment,$GuardHandle)
}

Export-ModuleMember -Function Invoke-BoundedNative
