Set-StrictMode -Version Latest
if(!('Codexless.BoundedNative' -as [type])){
Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;
namespace Codexless {
 public sealed class NativeResult {
  public bool Ok, TimedOut, OutputOverflow, LifetimeMayRemain;
  public int ExitCode = -1, ProcessId;
  public string CreatedAt, Stdout, Code;
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
  public static NativeResult Run(string exe,string sha256,string[] args,string cwd,int timeout,int limit){
   var result=new NativeResult();Process process=null;var clock=Stopwatch.StartNew();
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
     process=new Process();process.StartInfo=info;
     if(clock.ElapsedMilliseconds>=timeout){result.TimedOut=true;result.Code="NATIVE_TIMEOUT";return result;}
     // An attempted launch that loses its identity query must remain fenced too.
     result.LifetimeMayRemain=true;
     if(!process.Start())throw new InvalidOperationException();
     result.ProcessId=process.Id;result.CreatedAt=process.StartTime.ToUniversalTime().ToString("o");
     result.LifetimeMayRemain=true;
     var output=new Capture();var error=new Capture();
     Task a=output.Drain(process.StandardOutput,limit,true),b=error.Drain(process.StandardError,limit,false);
     while(!process.WaitForExit(Math.Min(25,Math.Max(1,timeout-(int)clock.ElapsedMilliseconds)))){
      if(clock.ElapsedMilliseconds>=timeout){result.TimedOut=true;result.Code="NATIVE_TIMEOUT";return result;}
     }
     result.LifetimeMayRemain=false;result.ExitCode=process.ExitCode;
     int remaining=timeout-(int)clock.ElapsedMilliseconds;
     if(remaining<=0 || !Task.WhenAll(a,b).Wait(remaining)){result.TimedOut=true;result.Code="NATIVE_TIMEOUT";return result;}
     result.OutputOverflow=output.Overflow||error.Overflow;
     if(result.OutputOverflow){result.Code="NATIVE_OUTPUT_LIMIT";return result;}
     if(result.ExitCode!=0){result.Code="NATIVE_EXIT_FAILED";return result;}
     result.Stdout=output.Text.ToString();result.Ok=true;result.Code="NATIVE_OK";return result;
    }
   }catch{result.Code="NATIVE_UNAVAILABLE";return result;}
   finally{if(process!=null)process.Dispose();}
  }
 }
}
'@
}

function Invoke-BoundedNative {
    param([string]$Executable,[string]$ExpectedSha256,[string[]]$Arguments,[string]$WorkingDirectory,[ValidateRange(100,30000)][int]$TimeoutMs=5000,[ValidateRange(128,65536)][int]$OutputLimit=65536)
    if($ExpectedSha256 -cnotmatch '^[0-9a-f]{64}$' -or $Executable -notmatch '^[A-Za-z]:[\\/]' -or $WorkingDirectory -notmatch '^[A-Za-z]:[\\/]'){throw 'NATIVE_CONTRACT_INVALID'}
    try{
        if(!(Test-Path -LiteralPath $Executable -PathType Leaf) -or !(Test-Path -LiteralPath $WorkingDirectory -PathType Container)){throw 'invalid'}
        foreach($path in @($Executable,$WorkingDirectory)){
            $cursor=[IO.Path]::GetFullPath($path)
            while($cursor){if((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'invalid'};$cursor=Split-Path $cursor -Parent}
        }
    }catch{throw 'NATIVE_CONTRACT_INVALID'}
    [Codexless.BoundedNative]::Run($Executable,$ExpectedSha256,$Arguments,$WorkingDirectory,$TimeoutMs,$OutputLimit)
}

Export-ModuleMember -Function Invoke-BoundedNative
