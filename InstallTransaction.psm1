Set-StrictMode -Version Latest

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
 $record=Read-TransactionRecord (Join-Path $root 'install-owner.json')
 if($record.version -ne 1 -or $record.ownerDigest -cne (Get-TransactionOwnerDigest) -or $record.transactionId -cnotmatch '^[0-9a-f]{32}$' -or $record.generationId -cnotmatch '^[0-9a-f]{32}$' -or $record.payloadSha256 -cnotmatch '^[0-9a-f]{64}$' -or $record.state -cne 'installed' -or $record.rootDigest -cne (Get-TransactionBytesDigest ([Text.Encoding]::UTF8.GetBytes($root.ToLowerInvariant())))){throw 'TRANSACTION_OWNER_INVALID'}
 $generation=Join-Path (Join-Path $root 'generations') $record.generationId
 if((Get-TransactionTreeDigest $generation) -cne $record.payloadSha256){throw 'TRANSACTION_PAYLOAD_CHANGED'}
 if(!(& $Adapter.VerifyStage $generation)){throw 'TRANSACTION_PROVENANCE_INVALID'}
 & $Adapter.AssertTask $record
 [pscustomobject]@{record=$record;generation=$generation;root=$root}
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
  $generations=Join-Path $root 'generations';New-Item -ItemType Directory -Path $generations -Force|Out-Null
  $generation=Join-Path $generations $id;[IO.Directory]::Move($stage,$generation)
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
  Set-TransactionStage $fence $fencePath 'starting'
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
  & $Adapter.AssertTask $owned.record
  Set-TransactionStage $fence $fencePath 'unregistering'
  & $Adapter.RemoveTask $owned.record
  if($null -ne (& $Adapter.GetTask)){throw 'task remains'}
  if((Get-TransactionTreeDigest $owned.generation) -cne $owned.record.payloadSha256){throw 'changed material'}
  Set-TransactionStage $fence $fencePath 'removing-owned-files'
  foreach($entry in $inventory){
   $path=Assert-TransactionRoot (Join-Path $owned.generation $entry.path)
   if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.sha256){throw 'changed file'}
   Remove-Item -LiteralPath $path -ErrorAction Stop
  }
  # Never recursively delete a generation or root. Unknown/user files survive.
  foreach($directory in @(Get-ChildItem -LiteralPath $owned.generation -Recurse -Directory|Sort-Object {$_.FullName.Length} -Descending)){
   Assert-TransactionRoot $directory.FullName|Out-Null
   if(@(Get-ChildItem -LiteralPath $directory.FullName -Force).Count -eq 0){[IO.Directory]::Delete($directory.FullName,$false)}
  }
  if(@(Get-ChildItem -LiteralPath $owned.generation -Force).Count -eq 0){[IO.Directory]::Delete($owned.generation,$false)}else{throw 'unknown files'}
  $receipt=Join-Path $owned.root 'install-owner.json'
  $now=Read-TransactionRecord $receipt
  if(($now|ConvertTo-Json -Compress) -cne ($owned.record|ConvertTo-Json -Compress)){throw 'receipt changed'}
  $retired=[ordered]@{version=1;state='uninstalled';transactionId=$owned.record.transactionId;ownerDigest=$owned.record.ownerDigest;rootDigest=$owned.record.rootDigest}
  Write-TransactionRecord (Join-Path $owned.root 'uninstalled-owner.json') $retired
  Remove-Item -LiteralPath $receipt -ErrorAction Stop
  Set-TransactionStage $fence $fencePath 'finalizing'
  Remove-Item -LiteralPath $fencePath -ErrorAction Stop
  [pscustomobject]@{state='uninstalled';verified=$true;userDataPreserved=$true}
 }catch{throw 'TRANSACTION_UNINSTALL_INCOMPLETE: Exact evidence retained; ambiguous material was not removed.'}
}
function Invoke-TransactionLocked([string]$Root,[scriptblock]$Body) {
 $root=Assert-TransactionRoot $Root
 $digest=Get-TransactionBytesDigest ([Text.Encoding]::UTF8.GetBytes($root.ToLowerInvariant()))
 $mutex=[Threading.Mutex]::new($false,('Local\CodexlessInstall-'+$digest))
 $held=$false
 try{
  try{$held=$mutex.WaitOne(0)}catch{throw 'TRANSACTION_LOCK_UNCERTAIN'}
  if(!$held){throw 'TRANSACTION_CONCURRENT_OPERATION'}
  & $Body
 }finally{if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
function Invoke-InstallTransaction {param([string]$Root,[string]$Payload,[hashtable]$Adapter) Invoke-TransactionLocked $Root {Invoke-InstallTransactionCore $Root $Payload $Adapter}}
function Invoke-OwnedRepair {param([string]$Root,[hashtable]$Adapter) Invoke-TransactionLocked $Root {Invoke-OwnedRepairCore $Root $Adapter}}
function Invoke-OwnedUninstall {param([string]$Root,[hashtable]$Adapter) Invoke-TransactionLocked $Root {Invoke-OwnedUninstallCore $Root $Adapter}}
Export-ModuleMember -Function Invoke-InstallTransaction,Invoke-OwnedRepair,Invoke-OwnedUninstall,Get-OwnedInstall,Get-TransactionTreeDigest
