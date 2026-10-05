$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\InstallTransaction.psm1') -Force
$module=Get-Module InstallTransaction
$fixtureRoot=Join-Path $PSScriptRoot ('.fixtures\reparse-race-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot -Force|Out-Null
$passed=0
function Assert([bool]$Value,[string]$Message){if(!$Value){throw $Message}}
function New-Fixture {
 $script:folder=Join-Path $fixtureRoot ([Guid]::NewGuid().ToString('N'))
 $script:payload=Join-Path $folder 'payload';$script:destination=Join-Path $folder 'destination';$script:outside=Join-Path $folder 'outside'
 New-Item -ItemType Directory -Path $payload,$outside -Force|Out-Null
 [IO.File]::WriteAllText((Join-Path $payload 'payload.bin'),'payload must stay inside')
 [IO.File]::WriteAllText((Join-Path $outside 'sentinel.txt'),'foreign outside sentinel')
 $script:outsideDigest=Get-TransactionTreeDigest $outside
 $script:mock=@{task=$null;running=$false;digest=(Get-TransactionTreeDigest $payload)}
 $script:adapter=@{
  Validate={param($r,$p)};VerifyStage={param($p) (Get-TransactionTreeDigest $p) -ceq $mock.digest};GetTask={$mock.task}
  RegisterTask={param($p,$r) $mock.task=$r.transactionId};AssertTask={param($r) if($mock.task -cne $r.transactionId){throw 'foreign task'}}
  Start={param($p,$r) $mock.running=$true};VerifyReady={param($p,$r) $mock.running}
  Stop={param($p,$r) $mock.running=$false};VerifyStopped={param($r) !$mock.running};RemoveTask={param($r) $mock.task=$null}
 }
 Invoke-InstallTransaction $destination $payload $adapter|Out-Null
 Invoke-OwnedUninstall $destination $adapter|Out-Null
 $script:generations=Join-Path $destination 'generations'
}
function Assert-Outside {
 Assert ((Get-TransactionTreeDigest $outside) -ceq $outsideDigest) 'outside target changed'
 Assert (@(Get-ChildItem -LiteralPath $outside -Force).Count -eq 1) 'payload escaped'
 Assert ($null -eq $mock.task -and !$mock.running) 'task mutation after refusal'
 $fence=Get-Content -LiteralPath (Join-Path $destination 'incomplete-install.json') -Raw|ConvertFrom-Json
 Assert ($fence.stage -ceq 'promoting' -and $fence.requiresVerifiedRecovery) 'promotion fence missing'
 $stage=Join-Path $folder ('.companion-stage-'+$fence.transactionId)
 Assert ((Get-TransactionTreeDigest $stage) -ceq $mock.digest) 'recovery payload lost'
}
function Refuses-Install {
 $blocked=$false
 try{Invoke-InstallTransaction $destination $payload $adapter|Out-Null}catch{$blocked=$_.Exception.Message -like 'TRANSACTION_INSTALL_INCOMPLETE*'}
 Assert $blocked 'install did not fail closed'
 Assert-Outside
}
function Recover {
 $result=Invoke-VerifiedIncompleteInstallRecovery $destination $adapter
 Assert ($result.verified -and $result.state -ceq 'recovered-installed') 'verified recovery failed'
 Assert ((Get-TransactionTreeDigest $outside) -ceq $outsideDigest) 'recovery changed outside'
}
function Pass([string]$Name){$script:passed++;Write-Output "PASS $Name"}

New-Fixture
[IO.Directory]::Delete($generations,$false)
New-Item -ItemType Junction -Path $generations -Target $outside|Out-Null
Refuses-Install
# Delete only the junction object, never its target; all paths are test fixtures.
[IO.Directory]::Delete($generations,$false)
Recover
Pass 'Retained tombstone junction refuses with zero outside payload; evidence supports recovery'

New-Fixture
$attack=[pscustomobject]@{generations=$generations;outside=$outside;fired=$false}
& $module {
 param($a)
 $script:E3Attack=$a;$script:E3Move=${function:Move-TransactionGeneration}
 function script:Move-TransactionGeneration([string]$Stage,[string]$Generations,[string]$GenerationId){
  $script:E3Attack.fired=$true
  [IO.Directory]::Delete($Generations,$false)
  New-Item -ItemType Junction -Path $Generations -Target $script:E3Attack.outside|Out-Null
  & $script:E3Move $Stage $Generations $GenerationId
 }
} $attack
try{Refuses-Install}finally{& $module {Set-Item Function:Move-TransactionGeneration $script:E3Move}}
Assert $attack.fired 'late junction injection missing'
[IO.Directory]::Delete($generations,$false)
Recover
Pass 'Replacement after earlier validation is rejected by no-follow mutation authority'

New-Fixture
$attack=[pscustomobject]@{generations=$generations;outside=$outside;fired=$false;denied=$false}
& $module {
 param($a)
 $script:E3Attack=$a;$script:E3Assert=${function:Assert-TransactionRoot}
 function script:Assert-TransactionRoot([string]$Root){
  if(!$script:E3Attack.fired -and $Root -match '\\generations\\[0-9a-f]{32}$'){
   $script:E3Attack.fired=$true
   try{[IO.Directory]::Move($script:E3Attack.generations,($script:E3Attack.generations+'.displaced'))}
   catch{$script:E3Attack.denied=$true;throw 'TEST_ATTACK_DENIED_AT_HELD_BOUNDARY'}
   New-Item -ItemType Junction -Path $script:E3Attack.generations -Target $script:E3Attack.outside|Out-Null
  }
  & $script:E3Assert $Root
 }
} $attack
try{Refuses-Install}finally{& $module {Set-Item Function:Assert-TransactionRoot $script:E3Assert}}
Assert ($attack.fired -and $attack.denied) 'held directory was replaceable'
Recover
Pass 'Ancestor replacement at the held promotion boundary is denied; abort retains evidence'

New-Fixture
$attack=[pscustomobject]@{outside=$outside;fired=$false;target=$null}
& $module {
 param($a)
 $script:E3Attack=$a
 function script:Test-Path {
  param([string]$LiteralPath)
  $result=Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath
  if(!$script:E3Attack.fired -and $LiteralPath -match '\\generations\\[0-9a-f]{32}$' -and !$result){
   $script:E3Attack.fired=$true;$script:E3Attack.target=$LiteralPath
   New-Item -ItemType Junction -Path $LiteralPath -Target $script:E3Attack.outside|Out-Null
  }
  $result
 }
} $attack
try{Refuses-Install}finally{& $module {Remove-Item Function:Test-Path}}
Assert $attack.fired 'post-collision-check target injection missing'
[IO.Directory]::Delete($attack.target,$false)
Recover
Pass 'Generation junction inserted after final absence check is not followed by native rename'

# Rename requires write-sharing on its destination directory. Test the real
# in-place conversion too: the relative rename must not resolve that reparse.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class ReparseWriterProbe {
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
 static extern SafeFileHandle CreateFileW(string p,uint a,uint s,IntPtr x,uint d,uint f,IntPtr t);
 [DllImport("kernel32.dll",SetLastError=true)]
 static extern bool DeviceIoControl(SafeFileHandle h,uint code,byte[] input,int length,IntPtr output,int outputLength,out int returned,IntPtr overlapped);
 public static int OpenWriter(string path) {
  using(var h=CreateFileW(path,0x40000000,7,IntPtr.Zero,3,0x02200000,IntPtr.Zero)) {
   return h.IsInvalid ? Marshal.GetLastWin32Error() : 0;
  }
 }
 public static void SetJunction(string path,string target) {
  byte[] substitute=System.Text.Encoding.Unicode.GetBytes("\\??\\"+target);
  byte[] print=System.Text.Encoding.Unicode.GetBytes(target);
  byte[] data=new byte[16+substitute.Length+2+print.Length+2];
  Array.Copy(BitConverter.GetBytes(0xA0000003u),0,data,0,4);
  Array.Copy(BitConverter.GetBytes((ushort)(data.Length-8)),0,data,4,2);
  Array.Copy(BitConverter.GetBytes((ushort)substitute.Length),0,data,10,2);
  Array.Copy(BitConverter.GetBytes((ushort)(substitute.Length+2)),0,data,12,2);
  Array.Copy(BitConverter.GetBytes((ushort)print.Length),0,data,14,2);
  Array.Copy(substitute,0,data,16,substitute.Length);
  Array.Copy(print,0,data,18+substitute.Length,print.Length);
  Control(path,0x900A4,data);
 }
 public static void ClearJunction(string path) {
  byte[] data=new byte[8];Array.Copy(BitConverter.GetBytes(0xA0000003u),data,4);
  Control(path,0x900AC,data);
 }
 static void Control(string path,uint code,byte[] data) {
  using(var h=CreateFileW(path,0x40000000,7,IntPtr.Zero,3,0x02200000,IntPtr.Zero)) {
   if(h.IsInvalid) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
   int returned;
   if(!DeviceIoControl(h,code,data,data.Length,IntPtr.Zero,0,out returned,IntPtr.Zero))
    throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
  }
 }
}
'@
New-Fixture
Assert ([ReparseWriterProbe]::OpenWriter($generations) -eq 0) 'writer control did not open'
$authority=[Codexless.TransactionDirectoryAuthority]::Acquire($generations,$false)
try {
 Assert ([ReparseWriterProbe]::OpenWriter($destination) -eq 32) 'ancestor reparse writer not excluded'
}finally{$authority.Dispose()}
Assert ([ReparseWriterProbe]::OpenWriter($generations) -eq 0) 'authority not released'
Pass 'Held ancestor authority denies in-place reparse writers and releases cleanly'

New-Fixture
$attack=[pscustomobject]@{generations=$generations;outside=$outside;fired=$false}
& $module {
 param($a)
 $script:E3Attack=$a
 function script:Test-Path {
  param([string]$LiteralPath)
  $result=Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath
  if(!$script:E3Attack.fired -and $LiteralPath -match '\\generations\\[0-9a-f]{32}$' -and !$result){
   $script:E3Attack.fired=$true
   [ReparseWriterProbe]::SetJunction($script:E3Attack.generations,$script:E3Attack.outside)
  }
  $result
 }
} $attack
try {
 $blocked=$false
 try{Invoke-InstallTransaction $destination $payload $adapter|Out-Null}catch{$blocked=$_.Exception.Message -like 'TRANSACTION_INSTALL_INCOMPLETE*'}
 Assert ($attack.fired -and $blocked) 'in-place conversion did not fail closed'
 Assert ((Get-TransactionTreeDigest $outside) -ceq $outsideDigest) 'in-place conversion escaped outside'
 Assert (@(Get-ChildItem -LiteralPath $outside -Force).Count -eq 1) 'outside payload appeared'
} finally {
 & $module {Remove-Item Function:Test-Path}
 if($attack.fired){[ReparseWriterProbe]::ClearJunction($generations)}
}
$fence=Get-Content -LiteralPath (Join-Path $destination 'incomplete-install.json') -Raw|ConvertFrom-Json
Assert ($fence.stage -ceq 'promoting' -and $fence.requiresVerifiedRecovery) 'conversion fence missing'
$retainedStage=Join-Path $folder ('.companion-stage-'+$fence.transactionId)
$retainedGeneration=Join-Path $generations $fence.generationId
Assert ((Test-Path -LiteralPath $retainedStage) -xor (Test-Path -LiteralPath $retainedGeneration)) 'promotion evidence ambiguous'
Recover
Pass 'In-place generations junction after last proof cannot redirect handle-relative rename; verified recovery succeeds'
Write-Output ("RESULT: {0}/{0} PASS; real NTFS junctions, outside sentinels, held-handle replacement refusal and verified recovery" -f $passed)
