Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'MutationLock.psm1') -Force

if(!('Codexless.TransactionFileIdentity' -as [type])){
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Codexless {
  [StructLayout(LayoutKind.Sequential)]
  public struct TransactionByHandleFileInformation {
    public uint FileAttributes;
    public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
    public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
    public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
    public uint VolumeSerialNumber;
    public uint FileSizeHigh;
    public uint FileSizeLow;
    public uint NumberOfLinks;
    public uint FileIndexHigh;
    public uint FileIndexLow;
  }
  public static class TransactionFileIdentity {
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetFileInformationByHandle(IntPtr hFile, out TransactionByHandleFileInformation info);
    public static string Get(IntPtr handle) {
      TransactionByHandleFileInformation info;
      if(!GetFileInformationByHandle(handle,out info)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
      return info.VolumeSerialNumber.ToString("x8")+":"+info.FileIndexHigh.ToString("x8")+info.FileIndexLow.ToString("x8");
    }
  }
}
'@
}

function Assert-TransactionRoot([string]$Root) {
 if($Root -notmatch '^[A-Za-z]:[\\/]' -or $Root -match '["\x00\r\n]'){throw 'TRANSACTION_ROOT_INVALID'}
 $full=[IO.Path]::GetFullPath($Root).TrimEnd('\')
 if($full.Length -le 3){throw 'TRANSACTION_ROOT_INVALID'}
 $cursor=$full
 while($cursor){if((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'TRANSACTION_REPARSE_POINT'};$cursor=Split-Path $cursor -Parent}
 $full
}
function Get-TransactionOwnerDigest {
 $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
 $sha=[Security.Cryptography.SHA256]::Create()
 try{([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($sid)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}
function Get-TransactionBytesDigest([byte[]]$Bytes) {
 $sha=[Security.Cryptography.SHA256]::Create()
 try{([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}
function Read-TransactionRecord([string]$Path) {
 Assert-TransactionRoot $Path|Out-Null
 if((Get-Item -LiteralPath $Path -ErrorAction Stop).Length -gt 32768){throw 'TRANSACTION_RECORD_INVALID'}
 $bytes=[IO.File]::ReadAllBytes($Path)
 try{[Text.UTF8Encoding]::new($false,$true).GetString($bytes)|ConvertFrom-Json}catch{throw 'TRANSACTION_RECORD_INVALID'}
}
function Get-TransactionRecordSnapshot([string]$Path) {
 Assert-TransactionRoot $Path|Out-Null
 $stream=$null
 try{
  $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
  if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt 32768){throw 'TRANSACTION_RECORD_INVALID'}
  $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
  $identity=[Codexless.TransactionFileIdentity]::Get($stream.SafeFileHandle.DangerousGetHandle())
  $bytes=New-Object byte[] $stream.Length
  $offset=0
  while($offset -lt $bytes.Length){$count=$stream.Read($bytes,$offset,$bytes.Length-$offset);if($count -le 0){throw 'TRANSACTION_RECORD_INVALID'};$offset+=$count}
  try{$record=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)|ConvertFrom-Json -ErrorAction Stop}catch{throw 'TRANSACTION_RECORD_INVALID'}
  [pscustomobject]@{record=$record;sha256=(Get-TransactionBytesDigest $bytes);length=$bytes.Length;fileIdentity=$identity}
 } finally {if($stream){$stream.Dispose()}}
}
function Assert-TransactionRecordSnapshot([string]$Path,$Snapshot) {
 $now=Get-TransactionRecordSnapshot $Path
 if($null -eq $Snapshot -or $now.sha256 -cne $Snapshot.sha256 -or $now.length -ne $Snapshot.length -or $now.fileIdentity -cne $Snapshot.fileIdentity){
  throw 'TRANSACTION_OWNER_CHANGED: install-owner.json authority changed.'
 }
 $now
}
function Write-TransactionRecord([string]$Path,$Record,[switch]$CreateNew) {
 Assert-TransactionRoot $Path|Out-Null
 $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Record|ConvertTo-Json -Depth 8 -Compress))
 $stream=$null
 if($CreateNew){try{$stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{if($stream){$stream.Dispose()}};return}
 $temp=$Path+'.'+[Guid]::NewGuid().ToString('N')+'.pending'
 try{
  $stream=[IO.File]::Open($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true);$stream.Dispose();$stream=$null
  if(Test-Path -LiteralPath $Path){[IO.File]::Replace($temp,$Path,($Path+'.'+[Guid]::NewGuid().ToString('N')+'.previous'))}else{[IO.File]::Move($temp,$Path)}
 }finally{if($stream){$stream.Dispose()}}
}
function Get-TransactionInventory([string]$Root) {
 $root=Assert-TransactionRoot $Root
 $files=@(Get-ChildItem -LiteralPath $root -Recurse -Force -File|Sort-Object FullName)
 if(!$files.Count -or $files.Count -gt 20000){throw 'TRANSACTION_INVENTORY_INVALID'}
 $inventory=@();$total=0L
 foreach($file in $files){
  Assert-TransactionRoot $file.FullName|Out-Null
  $total+=$file.Length;if($total -gt 2147483648){throw 'TRANSACTION_INVENTORY_LIMIT'}
  $path=$file.FullName.Substring($root.Length+1).Replace('\','/')
  $inventory+=[pscustomobject]@{path=$path;sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
 }
 # Traverse all directories too, including empty junctions.
 foreach($dir in @(Get-ChildItem -LiteralPath $root -Recurse -Force -Directory)){Assert-TransactionRoot $dir.FullName|Out-Null}
 $inventory
}
function Get-TransactionTreeDigest([string]$Root) {
 $inventory=@(Get-TransactionInventory $Root)
 Get-TransactionBytesDigest ([Text.Encoding]::UTF8.GetBytes(($inventory|ConvertTo-Json -Depth 4 -Compress)))
}
function Assert-TransactionAdapter([hashtable]$Adapter) {
 foreach($name in @('Validate','VerifyStage','GetTask','RegisterTask','AssertTask','Start','VerifyReady','Stop','VerifyStopped','RemoveTask')){
  if(!$Adapter.ContainsKey($name) -or $Adapter[$name] -isnot [scriptblock]){throw 'TRANSACTION_ADAPTER_INVALID'}
 }
}
function Get-OwnedInstall($Root,[hashtable]$Adapter) {
 $root=Assert-TransactionRoot $Root
 if(Test-Path -LiteralPath (Join-Path $root 'incomplete-install.json')){throw 'TRANSACTION_INCOMPLETE: Explicit verified recovery is required.'}
 $ownerPath=Join-Path $root 'install-owner.json'
 $ownerSnapshot=Get-TransactionRecordSnapshot $ownerPath
 $record=$ownerSnapshot.record
 if($record.version -ne 1 -or $record.ownerDigest -cne (Get-TransactionOwnerDigest) -or $record.transactionId -cnotmatch '^[0-9a-f]{32}$' -or $record.generationId -cnotmatch '^[0-9a-f]{32}$' -or $record.payloadSha256 -cnotmatch '^[0-9a-f]{64}$' -or $record.state -cne 'installed' -or $record.rootDigest -cne (Get-TransactionBytesDigest ([Text.Encoding]::UTF8.GetBytes($root.ToLowerInvariant())))){throw 'TRANSACTION_OWNER_INVALID'}
 $generation=Join-Path (Join-Path $root 'generations') $record.generationId
 if((Get-TransactionTreeDigest $generation) -cne $record.payloadSha256){throw 'TRANSACTION_PAYLOAD_CHANGED'}
 if(!(& $Adapter.VerifyStage $generation)){throw 'TRANSACTION_PROVENANCE_INVALID'}
 & $Adapter.AssertTask $record
 [pscustomobject]@{record=$record;generation=$generation;root=$root;ownerPath=$ownerPath;ownerSnapshot=$ownerSnapshot}
}
function Set-TransactionStage($Fence,[string]$Path,[string]$Stage) {
 $Fence.stage=$Stage
 Write-TransactionRecord $Path $Fence
}
function Invoke-InstallTransactionCore {
 param([string]$Root,[string]$Payload,[hashtable]$Adapter)
 Assert-TransactionAdapter $Adapter
 $root=Assert-TransactionRoot $Root;$payload=Assert-TransactionRoot $Payload
 $reinstall=$false
 if(Test-Path -LiteralPath $root){
  if((Test-Path -LiteralPath (Join-Path $root 'install-owner.json')) -or (Test-Path -LiteralPath (Join-Path $root 'incomplete-install.json'))){throw 'TRANSACTION_DESTINATION_EXISTS'}
  try{$retired=Read-TransactionRecord (Join-Path $root 'uninstalled-owner.json');if($retired.version -ne 1 -or $retired.state -cne 'uninstalled' -or $retired.ownerDigest -cne (Get-TransactionOwnerDigest) -or $retired.rootDigest -cne (Get-TransactionBytesDigest ([Text.Encoding]::UTF8.GetBytes($root.ToLowerInvariant())))){throw 'invalid'}}catch{throw 'TRANSACTION_DESTINATION_EXISTS'}
  $reinstall=$true
 }
 & $Adapter.Validate $root $payload
 if($null -ne (& $Adapter.GetTask)){throw 'TRANSACTION_FOREIGN_TASK: Existing task must not be overwritten.'}
 if(!(& $Adapter.VerifyStage $payload)){throw 'TRANSACTION_PROVENANCE_INVALID'}
 $inventory=@(Get-TransactionInventory $payload);$digest=Get-TransactionTreeDigest $payload
 $parent=Split-Path $root -Parent
 if(!(Test-Path -LiteralPath $parent -PathType Container)){throw 'TRANSACTION_PARENT_INVALID'}
 $id=[Guid]::NewGuid().ToString('N');$stage=Join-Path $parent ('.companion-stage-'+$id)
 # Fresh staged copy precedes destination mutation. No source binary trust.
 New-Item -ItemType Directory -Path $stage -ErrorAction Stop|Out-Null
 foreach($entry in $inventory){$destination=Join-Path $stage $entry.path;New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force|Out-Null;[IO.File]::Copy((Join-Path $payload $entry.path),$destination,$false)}
 if((Get-TransactionTreeDigest $stage) -cne $digest -or !(& $Adapter.VerifyStage $stage)){throw 'TRANSACTION_STAGE_INVALID'}
 if($null -ne (& $Adapter.GetTask)){throw 'TRANSACTION_FOREIGN_TASK'}
 if(!$reinstall){New-Item -ItemType Directory -Path $root -ErrorAction Stop|Out-Null}
 $fencePath=Join-Path $root 'incomplete-install.json'
 $fence=[ordered]@{version=1;transactionId=$id;ownerDigest=(Get-TransactionOwnerDigest);operation='install';stage='fenced';generationId=$id;payloadSha256=$digest;requiresVerifiedRecovery=$true}
 Write-TransactionRecord $fencePath $fence -CreateNew
 try{
  Set-TransactionStage $fence $fencePath 'promoting'
  $generations=Join-Path $root 'generations'
  if(Test-Path -LiteralPath $generations){Assert-TransactionRoot $generations|Out-Null}
  else{New-Item -ItemType Directory -Path $generations -ErrorAction Stop|Out-Null}
  Assert-TransactionRoot $root|Out-Null;Assert-TransactionRoot $generations|Out-Null
  $generation=Join-Path $generations $id
  if(Test-Path -LiteralPath $generation){throw 'TRANSACTION_GENERATION_COLLISION'}
  Assert-TransactionRoot $generations|Out-Null
  [IO.Directory]::Move($stage,$generation)
  Assert-TransactionRoot $generation|Out-Null
  if((Get-TransactionTreeDigest $generation) -cne $digest -or !(& $Adapter.VerifyStage $generation)){throw 'invalid'}
  $record=[ordered]@{version=1;state='installed';transactionId=$id;generationId=$id;ownerDigest=$fence.ownerDigest;payloadSha256=$digest;rootDigest=(Get-TransactionBytesDigest ([Text.Encoding]::UTF8.GetBytes($root.ToLowerInvariant())))}
  Set-TransactionStage $fence $fencePath 'registering'
  if($null -ne (& $Adapter.GetTask)){throw 'foreign task'}
  & $Adapter.RegisterTask $generation $record
  & $Adapter.AssertTask $record
  Set-TransactionStage $fence $fencePath 'starting'
  & $Adapter.Start $generation $record
  Set-TransactionStage $fence $fencePath 'verifying'
  if(!(& $Adapter.VerifyReady $generation $record)){throw 'readiness failed'}
  Write-TransactionRecord (Join-Path $root 'install-owner.json') $record -CreateNew
  Set-TransactionStage $fence $fencePath 'finalizing'
  Remove-Item -LiteralPath $fencePath -ErrorAction Stop
  [pscustomobject]@{state='installed';transactionId=$id;verified=$true}
 }catch{throw 'TRANSACTION_INSTALL_INCOMPLETE: Exact transaction evidence retained; no installation success claimed.'}
}
function Invoke-OwnedRepairCore {
 param([string]$Root,[hashtable]$Adapter)
 Assert-TransactionAdapter $Adapter
 $owned=Get-OwnedInstall $Root $Adapter
 $fencePath=Join-Path $owned.root 'incomplete-install.json'
 $fence=[ordered]@{version=1;transactionId=$owned.record.transactionId;ownerDigest=$owned.record.ownerDigest;operation='repair';stage='stopping';generationId=$owned.record.generationId;payloadSha256=$owned.record.payloadSha256;requiresVerifiedRecovery=$true}
 Write-TransactionRecord $fencePath $fence -CreateNew
 try{
  & $Adapter.Stop $owned.generation $owned.record
  if(!(& $Adapter.VerifyStopped $owned.record)){throw 'stop unproven'}
  $null=Assert-TransactionRecordSnapshot $owned.ownerPath $owned.ownerSnapshot
  Set-TransactionStage $fence $fencePath 'starting'
  $null=Assert-TransactionRecordSnapshot $owned.ownerPath $owned.ownerSnapshot
  & $Adapter.Start $owned.generation $owned.record
  Set-TransactionStage $fence $fencePath 'verifying'
  if(!(& $Adapter.VerifyReady $owned.generation $owned.record)){throw 'readiness failed'}
  Remove-Item -LiteralPath $fencePath -ErrorAction Stop
  [pscustomobject]@{state='repaired';verified=$true}
 }catch{throw 'TRANSACTION_REPAIR_INCOMPLETE: Verified recovery required; transaction evidence retained.'}
}
function Invoke-OwnedUninstallCore {
 param([string]$Root,[hashtable]$Adapter)
 Assert-TransactionAdapter $Adapter
 $owned=Get-OwnedInstall $Root $Adapter
 $inventory=@(Get-TransactionInventory $owned.generation)
 $fencePath=Join-Path $owned.root 'incomplete-install.json'
 $fence=[ordered]@{version=1;transactionId=$owned.record.transactionId;ownerDigest=$owned.record.ownerDigest;operation='uninstall';stage='stopping';generationId=$owned.record.generationId;payloadSha256=$owned.record.payloadSha256;requiresVerifiedRecovery=$true}
 Write-TransactionRecord $fencePath $fence -CreateNew
 try{
  & $Adapter.Stop $owned.generation $owned.record
  if(!(& $Adapter.VerifyStopped $owned.record)){throw 'stop uncertain'}
  $null=Assert-TransactionRecordSnapshot $owned.ownerPath $owned.ownerSnapshot
  & $Adapter.AssertTask $owned.record
  Set-TransactionStage $fence $fencePath 'unregistering'
  $null=Assert-TransactionRecordSnapshot $owned.ownerPath $owned.ownerSnapshot
  & $Adapter.RemoveTask $owned.record
  if($null -ne (& $Adapter.GetTask)){throw 'task remains'}
  if((Get-TransactionTreeDigest $owned.generation) -cne $owned.record.payloadSha256){throw 'changed material'}
  Set-TransactionStage $fence $fencePath 'removing-owned-files'
  foreach($entry in $inventory){
   $path=Assert-TransactionRoot (Join-Path $owned.generation $entry.path)
   if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.sha256){throw 'changed file'}
   $null=Assert-TransactionRecordSnapshot $owned.ownerPath $owned.ownerSnapshot
   Remove-Item -LiteralPath $path -ErrorAction Stop
  }
  # Never recursively delete a generation or root. Unknown/user files survive.
  foreach($directory in @(Get-ChildItem -LiteralPath $owned.generation -Recurse -Directory|Sort-Object {$_.FullName.Length} -Descending)){
   Assert-TransactionRoot $directory.FullName|Out-Null
   if(@(Get-ChildItem -LiteralPath $directory.FullName -Force).Count -eq 0){[IO.Directory]::Delete($directory.FullName,$false)}
  }
  if(@(Get-ChildItem -LiteralPath $owned.generation -Force).Count -eq 0){[IO.Directory]::Delete($owned.generation,$false)}else{throw 'unknown files'}
  $receipt=$owned.ownerPath
  $null=Assert-TransactionRecordSnapshot $receipt $owned.ownerSnapshot
  $retired=[ordered]@{version=1;state='uninstalled';transactionId=$owned.record.transactionId;ownerDigest=$owned.record.ownerDigest;rootDigest=$owned.record.rootDigest}
  Write-TransactionRecord (Join-Path $owned.root 'uninstalled-owner.json') $retired
  $null=Assert-TransactionRecordSnapshot $receipt $owned.ownerSnapshot
  Remove-Item -LiteralPath $receipt -ErrorAction Stop
  Set-TransactionStage $fence $fencePath 'finalizing'
  Remove-Item -LiteralPath $fencePath -ErrorAction Stop
  [pscustomobject]@{state='uninstalled';verified=$true;userDataPreserved=$true}
 }catch{throw 'TRANSACTION_UNINSTALL_INCOMPLETE: Exact evidence retained; ambiguous material was not removed.'}
}
function Invoke-OwnedUpdateCore {
 param([string]$Root,[string]$Payload,[hashtable]$Adapter)
 Assert-TransactionAdapter $Adapter
 $owned=Get-OwnedInstall $Root $Adapter
 $payload=Assert-TransactionRoot $Payload
 & $Adapter.Validate $Root $payload
 if(!(& $Adapter.VerifyStage $payload)){throw 'TRANSACTION_PROVENANCE_INVALID'}
 $inventory=@(Get-TransactionInventory $payload);$digest=Get-TransactionTreeDigest $payload
 $id=[Guid]::NewGuid().ToString('N')
 $generations=Join-Path $owned.root 'generations'
 Assert-TransactionRoot $generations|Out-Null
 $generation=Join-Path $generations $id
 $fencePath=Join-Path $owned.root 'incomplete-install.json'
 $fence=[ordered]@{version=1;transactionId=$id;ownerDigest=$owned.record.ownerDigest;operation='update';stage='staging';generationId=$id;payloadSha256=$digest;rollbackGenerationId=$owned.record.generationId;rollbackSha256=$owned.record.payloadSha256;requiresVerifiedRecovery=$true}
 Write-TransactionRecord $fencePath $fence -CreateNew
 $activeOwnerSnapshot=$owned.ownerSnapshot
 $stopAttempted=$false;$candidateStartAttempted=$false;$promoted=$false
 try{
  Assert-TransactionRoot $generations|Out-Null
  New-Item -ItemType Directory -Path $generation -ErrorAction Stop|Out-Null
  Assert-TransactionRoot $generation|Out-Null
  foreach($entry in $inventory){$target=Join-Path $generation $entry.path;New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force|Out-Null;[IO.File]::Copy((Join-Path $payload $entry.path),$target,$false)}
  if((Get-TransactionTreeDigest $generation) -cne $digest -or !(& $Adapter.VerifyStage $generation)){throw 'candidate changed'}
  $candidate=[ordered]@{version=1;state='installed';transactionId=$id;generationId=$id;ownerDigest=$owned.record.ownerDigest;rootDigest=$owned.record.rootDigest;payloadSha256=$digest}
  # Freeze the complete previous receipt in sanitized rollback material.
  Write-TransactionRecord (Join-Path $owned.root 'rollback-owner.json') $owned.record
  if((Get-TransactionTreeDigest $owned.generation) -cne $owned.record.payloadSha256 -or !(& $Adapter.VerifyStage $owned.generation)){throw 'rollback changed'}
  $null=Assert-TransactionRecordSnapshot $owned.ownerPath $owned.ownerSnapshot
  & $Adapter.AssertTask $owned.record
  Set-TransactionStage $fence $fencePath 'stopping-current'
  $stopAttempted=$true
  & $Adapter.Stop $owned.generation $owned.record
  if(!(& $Adapter.VerifyStopped $owned.record)){throw 'stop uncertain'}
  $null=Assert-TransactionRecordSnapshot $owned.ownerPath $owned.ownerSnapshot
  & $Adapter.AssertTask $owned.record
  Set-TransactionStage $fence $fencePath 'promoting-candidate'
  if(!$Adapter.ContainsKey('Promote') -or $Adapter.Promote -isnot [scriptblock]){throw 'promotion unsupported'}
  if((Get-TransactionTreeDigest $generation) -cne $digest -or !(& $Adapter.VerifyStage $generation)){throw 'candidate changed before promotion'}
  Assert-TransactionRoot $generation|Out-Null
  $null=Assert-TransactionRecordSnapshot $owned.ownerPath $owned.ownerSnapshot
  $promoted=$true
  & $Adapter.Promote $generation $candidate
  & $Adapter.AssertTask $candidate
  $null=Assert-TransactionRecordSnapshot $owned.ownerPath $owned.ownerSnapshot
  Write-TransactionRecord $owned.ownerPath $candidate
  $activeOwnerSnapshot=Get-TransactionRecordSnapshot $owned.ownerPath
  Set-TransactionStage $fence $fencePath 'starting-candidate'
  $candidateStartAttempted=$true
  & $Adapter.Start $generation $candidate
  Set-TransactionStage $fence $fencePath 'verifying-candidate'
  if(!(& $Adapter.VerifyReady $generation $candidate)){throw 'candidate readiness'}
  Set-TransactionStage $fence $fencePath 'finalizing'
  Remove-Item -LiteralPath $fencePath -ErrorAction Stop
  [pscustomobject]@{state='updated';verified=$true;rollbackAvailable=$true}
 }catch{
  # Never roll back around unproven stop, changed material or missing evidence.
  try{
   if(!$stopAttempted){throw 'no stop proof'}
   $null=Assert-TransactionRecordSnapshot $owned.ownerPath $activeOwnerSnapshot
   if($candidateStartAttempted){
    Set-TransactionStage $fence $fencePath 'stopping-failed-candidate'
    & $Adapter.AssertTask $candidate
    & $Adapter.Stop $generation $candidate
    if(!(& $Adapter.VerifyStopped $candidate)){throw 'candidate still exists'}
   }elseif(!(& $Adapter.VerifyStopped $owned.record)){throw 'current stop uncertain'}
   $rollback=Read-TransactionRecord (Join-Path $owned.root 'rollback-owner.json')
   if(($rollback|ConvertTo-Json -Compress) -cne ($owned.record|ConvertTo-Json -Compress) -or (Get-TransactionTreeDigest $owned.generation) -cne $owned.record.payloadSha256 -or !(& $Adapter.VerifyStage $owned.generation)){throw 'rollback evidence changed'}
   Set-TransactionStage $fence $fencePath 'restoring-prior'
   if($promoted){& $Adapter.AssertTask $candidate;& $Adapter.Promote $owned.generation $owned.record}
   & $Adapter.AssertTask $owned.record
   $null=Assert-TransactionRecordSnapshot $owned.ownerPath $activeOwnerSnapshot
   Write-TransactionRecord $owned.ownerPath $owned.record
   Set-TransactionStage $fence $fencePath 'restarting-prior'
   & $Adapter.Start $owned.generation $owned.record
   if(!(& $Adapter.VerifyReady $owned.generation $owned.record)){throw 'rollback readiness'}
   Set-TransactionStage $fence $fencePath 'rolled-back'
   Remove-Item -LiteralPath $fencePath -ErrorAction Stop
   [pscustomobject]@{state='rolled-back';verified=$true;candidateAccepted=$false}
  }catch{throw 'TRANSACTION_UPDATE_INCOMPLETE: Exact generations retained; rollback proof incomplete.'}
 }
}
function Test-TransactionInstalledRecordMatch($Actual,$Expected) {
 try {
  ($Actual.version -eq 1 -and $Actual.state -ceq 'installed' -and
   $Actual.transactionId -ceq $Expected.transactionId -and
   $Actual.generationId -ceq $Expected.generationId -and
   $Actual.ownerDigest -ceq $Expected.ownerDigest -and
   $Actual.payloadSha256 -ceq $Expected.payloadSha256 -and
   $Actual.rootDigest -ceq $Expected.rootDigest)
 } catch { $false }
}
function Invoke-VerifiedIncompleteInstallRecoveryCore {
 param([string]$Root,[hashtable]$Adapter)
 Assert-TransactionAdapter $Adapter
 $root=Assert-TransactionRoot $Root
 $fencePath=Join-Path $root 'incomplete-install.json'
 if(!(Test-Path -LiteralPath $fencePath -PathType Leaf)){throw 'TRANSACTION_RECOVERY_NOT_REQUIRED'}
 $fence=Read-TransactionRecord $fencePath
 $allowed=@('fenced','promoting','registering','starting','verifying','finalizing')
 if($fence.version -ne 1 -or $fence.operation -cne 'install' -or
    $fence.ownerDigest -cne (Get-TransactionOwnerDigest) -or
    $fence.transactionId -cnotmatch '^[0-9a-f]{32}$' -or
    $fence.generationId -cne $fence.transactionId -or
    $fence.payloadSha256 -cnotmatch '^[0-9a-f]{64}$' -or
    $fence.stage -cnotin $allowed -or $fence.requiresVerifiedRecovery -ne $true){
  throw 'TRANSACTION_RECOVERY_EVIDENCE_INVALID'
 }
 $record=[ordered]@{
  version=1;state='installed';transactionId=[string]$fence.transactionId;generationId=[string]$fence.generationId
  ownerDigest=[string]$fence.ownerDigest;payloadSha256=[string]$fence.payloadSha256
  rootDigest=(Get-TransactionBytesDigest ([Text.Encoding]::UTF8.GetBytes($root.ToLowerInvariant())))
 }
 $parent=Split-Path $root -Parent
 $stage=Join-Path $parent ('.companion-stage-'+[string]$fence.transactionId)
 $generations=Join-Path $root 'generations'
 $generation=Join-Path $generations ([string]$fence.generationId)
 $ownerPath=Join-Path $root 'install-owner.json'
 try {
  while($true){
   switch([string]$fence.stage){
    'fenced' {
     if(!(Test-Path -LiteralPath $stage -PathType Container) -or
        (Get-TransactionTreeDigest $stage) -cne $record.payloadSha256 -or !(& $Adapter.VerifyStage $stage)){throw 'recovery stage unavailable'}
     Set-TransactionStage $fence $fencePath 'promoting'
     continue
    }
    'promoting' {
     if(Test-Path -LiteralPath $generation){
      Assert-TransactionRoot $generation|Out-Null
      if((Get-TransactionTreeDigest $generation) -cne $record.payloadSha256 -or !(& $Adapter.VerifyStage $generation)){throw 'generation changed'}
      if(Test-Path -LiteralPath $stage){throw 'ambiguous promotion evidence'}
     } else {
      if(!(Test-Path -LiteralPath $stage -PathType Container) -or
         (Get-TransactionTreeDigest $stage) -cne $record.payloadSha256 -or !(& $Adapter.VerifyStage $stage)){throw 'recovery stage unavailable'}
      if(Test-Path -LiteralPath $generations){Assert-TransactionRoot $generations|Out-Null}else{New-Item -ItemType Directory -Path $generations -ErrorAction Stop|Out-Null}
      Assert-TransactionRoot $root|Out-Null;Assert-TransactionRoot $generations|Out-Null
      [IO.Directory]::Move($stage,$generation)
      Assert-TransactionRoot $generation|Out-Null
      if((Get-TransactionTreeDigest $generation) -cne $record.payloadSha256 -or !(& $Adapter.VerifyStage $generation)){throw 'promoted generation unproven'}
     }
     Set-TransactionStage $fence $fencePath 'registering'
     continue
    }
    'registering' {
     Assert-TransactionRoot $generation|Out-Null
     if((Get-TransactionTreeDigest $generation) -cne $record.payloadSha256 -or !(& $Adapter.VerifyStage $generation)){throw 'generation changed'}
     $task=& $Adapter.GetTask
     if($null -eq $task){& $Adapter.RegisterTask $generation $record}
     & $Adapter.AssertTask $record
     Set-TransactionStage $fence $fencePath 'starting'
     continue
    }
    'starting' {
     & $Adapter.AssertTask $record
     & $Adapter.Start $generation $record
     Set-TransactionStage $fence $fencePath 'verifying'
     continue
    }
    'verifying' {
     & $Adapter.AssertTask $record
     if(!(& $Adapter.VerifyReady $generation $record)){throw 'readiness failed'}
     if(Test-Path -LiteralPath $ownerPath){
      $snap=Get-TransactionRecordSnapshot $ownerPath
      if(!(Test-TransactionInstalledRecordMatch $snap.record $record)){throw 'owner evidence ambiguous'}
     } else {
      Write-TransactionRecord $ownerPath $record -CreateNew
     }
     Set-TransactionStage $fence $fencePath 'finalizing'
     continue
    }
    'finalizing' {
     $snap=Get-TransactionRecordSnapshot $ownerPath
     if(!(Test-TransactionInstalledRecordMatch $snap.record $record)){throw 'owner evidence ambiguous'}
     Assert-TransactionRoot $generation|Out-Null
     if((Get-TransactionTreeDigest $generation) -cne $record.payloadSha256 -or !(& $Adapter.VerifyStage $generation)){throw 'generation changed'}
     & $Adapter.AssertTask $record
     if(!(& $Adapter.VerifyReady $generation $record)){throw 'readiness failed'}
     Remove-Item -LiteralPath $fencePath -ErrorAction Stop
     return [pscustomobject]@{state='recovered-installed';verified=$true;transactionId=$record.transactionId;stage='finalized'}
    }
   }
  }
 } catch {
  throw 'TRANSACTION_INSTALL_RECOVERY_INCOMPLETE: Verified install evidence retained; ambiguous state was not adopted.'
 }
}
function Invoke-TransactionLocked([string]$Root,[scriptblock]$Body) {
 $root=Assert-TransactionRoot $Root
 try { Invoke-CompanionMutationLocked $root $Body }
 catch {
  if($_.Exception.Message -like 'MUTATION_CONCURRENT_OPERATION*'){throw 'TRANSACTION_CONCURRENT_OPERATION'}
  if($_.Exception.Message -like 'MUTATION_LOCK_ABANDONED*'){throw 'TRANSACTION_LOCK_ABANDONED: Explicit verified recovery is required.'}
  if($_.Exception.Message -like 'MUTATION_LOCK_*'){throw 'TRANSACTION_LOCK_UNCERTAIN'}
  throw
 }
}
function Invoke-InstallTransaction {param([string]$Root,[string]$Payload,[hashtable]$Adapter) Invoke-TransactionLocked $Root {Invoke-InstallTransactionCore $Root $Payload $Adapter}}
function Invoke-OwnedRepair {param([string]$Root,[hashtable]$Adapter) Invoke-TransactionLocked $Root {if(Test-Path -LiteralPath (Join-Path (Assert-TransactionRoot $Root) 'incomplete-install.json')){Invoke-VerifiedIncompleteInstallRecoveryCore $Root $Adapter}else{Invoke-OwnedRepairCore $Root $Adapter}}}
function Invoke-OwnedUninstall {param([string]$Root,[hashtable]$Adapter) Invoke-TransactionLocked $Root {Invoke-OwnedUninstallCore $Root $Adapter}}
function Invoke-OwnedUpdate {param([string]$Root,[string]$Payload,[hashtable]$Adapter) Invoke-TransactionLocked $Root {Invoke-OwnedUpdateCore $Root $Payload $Adapter}}
function Invoke-VerifiedIncompleteInstallRecovery {param([string]$Root,[hashtable]$Adapter) Invoke-TransactionLocked $Root {Invoke-VerifiedIncompleteInstallRecoveryCore $Root $Adapter}}
Export-ModuleMember -Function Invoke-InstallTransaction,Invoke-OwnedRepair,Invoke-OwnedUninstall,Invoke-OwnedUpdate,Invoke-VerifiedIncompleteInstallRecovery,Get-OwnedInstall,Get-TransactionTreeDigest
