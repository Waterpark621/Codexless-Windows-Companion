$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$fixtureBase=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '.fixtures'))
$root=Join-Path $fixtureBase ('fresh-process-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
$passed=0
function Assert([bool]$value){if(!$value){throw 'fresh process assertion failed'}}
function Case([string]$name,[scriptblock]$body){&$body;$script:passed++;Write-Output ('PASS '+$name)}
Case 'Fresh Doctor imports retain caller-visible runtime commands' {
 $check=Join-Path $root 'doctor-imports.ps1'
 @'
param([string]$Repo)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $Repo 'CompanionRuntime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $Repo 'DoctorSupport.psm1') -Force -DisableNameChecking
foreach($name in @('Get-CompanionConfig','Test-CodexlessReady','Get-DoctorListenerOwnershipSnapshot','Get-DoctorBrowserAcceptance')){
 if(!(Get-Command $name -ErrorAction SilentlyContinue)){throw 'DOCTOR_FRESH_PROCESS_COMMAND_MISSING'}
}
'@|Set-Content -LiteralPath $check -Encoding UTF8
 &$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File $check -Repo $repo
 Assert ($LASTEXITCODE -eq 0)
}
$install=Join-Path $root 'installation';$id='a'*32
$generation=Join-Path (Join-Path $install 'generations') $id
$project=Join-Path $root 'project'
$null=New-Item -ItemType Directory -Path $generation,$project
foreach($file in Get-ChildItem -LiteralPath $repo -File){Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $generation $file.Name)}
$receiptPath=Join-Path $install 'native-adapter-owner.json'
$receipt=[ordered]@{version=2;state='active';transactionId=$id;generationId=$id;payloadSha256=('b'*64)}
$receipt|ConvertTo-Json|Set-Content -LiteralPath $receiptPath -Encoding UTF8
$settings=Join-Path $install 'settings.json';[IO.File]::WriteAllText($settings,'{}')
$cfg=[pscustomobject]@{companionRoot=$install;projectPath=$project;nodeExe=(Join-Path $root 'node.exe');nodeSha256=('c'*64);launchScript=(Join-Path $root 'launch.mjs');port=17690;settingsPath=$settings;codexlessRoot=$root;tunnelExe='';profileDir='';tunnels=@();release=[pscustomobject]@{version='fixture';buildId=('d'*64);sourceRevision=('e'*40);manifestSha256=('f'*64);hostContractVersion='fixture'}}
Case 'Source and installed generation bind the identical Browser command and contract' {
 $sourceRuntime=Import-Module (Join-Path $repo 'CompanionRuntime.psm1') -Force -PassThru -DisableNameChecking
 $sourceCommand=&$sourceRuntime {param($c) Get-CodexlessPrivateConsoleCommand $c} $cfg
 $sourceIdentity=Import-Module (Join-Path $repo 'GenerationIdentity.psm1') -Force -PassThru
 $sourceContract=&$sourceIdentity {param($c) Get-CompanionGenerationContract $c} $cfg
 $installedRuntime=Import-Module (Join-Path $generation 'CompanionRuntime.psm1') -Force -PassThru -DisableNameChecking
 $installedCommand=&$installedRuntime {param($c) Get-CodexlessPrivateConsoleCommand $c} $cfg
 $installedIdentity=Import-Module (Join-Path $generation 'GenerationIdentity.psm1') -Force -PassThru
 $installedContract=&$installedIdentity {param($c) Get-CompanionGenerationContract $c} $cfg
 Assert ($sourceCommand -ceq $installedCommand -and $sourceContract.sha256 -ceq $installedContract.sha256)
 Assert ($sourceCommand.Contains((Join-Path $generation 'BrowserSnapshotStore.psm1')))
}
Case 'Malformed native binding cannot select a Browser helper' {
 $runtime=Import-Module (Join-Path $repo 'CompanionRuntime.psm1') -Force -PassThru -DisableNameChecking
 [IO.File]::WriteAllText($receiptPath,'{}')
 $refused=$false
 try{&$runtime {param($c) Get-CodexlessPrivateConsoleCommand $c} $cfg|Out-Null}catch{$refused=$_.Exception.Message -ceq 'BROWSER_GENERATION_BINDING_INVALID'}
 Assert $refused
 $receipt|ConvertTo-Json|Set-Content -LiteralPath $receiptPath -Encoding UTF8
}
Case 'Changed generation helper is refused before importing it' {
 $helper=Join-Path $generation 'BrowserSnapshotStore.psm1'
 $bytes=[IO.File]::ReadAllBytes($helper)
 try{
  [IO.File]::WriteAllText($helper,"throw 'MUST_NOT_EXECUTE'")
  $runtime=Import-Module (Join-Path $repo 'CompanionRuntime.psm1') -Force -PassThru -DisableNameChecking
  $refused=$false
  try{&$runtime {param($c) Get-CodexlessPrivateConsoleCommand $c} $cfg|Out-Null}catch{$refused=$_.Exception.Message -ceq 'BROWSER_GENERATION_BINDING_INVALID'}
  Assert $refused
 }finally{[IO.File]::WriteAllBytes($helper,$bytes)}
}
Case 'Packaged AppData destination refuses before staging or installation mutation' {
 $public=Import-Module (Join-Path $repo 'PublicInstall.psm1') -Force -PassThru -DisableNameChecking
 $destination=Join-Path $root 'AppData\Local\Companion'
 &$public {
  param($appData,$destination,$repo,$project)
  $script:FixtureContext=[pscustomobject]@{packaged=$true;appDataRoot=$appData}
  function script:Get-PublicInstallPackageContext {$script:FixtureContext}
  $refused=$false
  try{Invoke-PublicCompanionInstall -PayloadRoot $repo -TrustedPayloadSha256 ('a'*64) -InstallDirectory $destination -ProjectPath $project -NoTunnel|Out-Null}catch{$refused=$_.Exception.Message -clike 'INSTALL_APPDATA_VIRTUALIZED:*'}
  if(!$refused -or (Test-Path -LiteralPath $destination)){throw 'APPDATA_GUARD_FAILED'}
 } (Join-Path $root 'AppData') $destination $repo $project
}
Case 'Ordinary AppData and packaged custom destinations retain the public flow' {
 $public=Get-Module PublicInstall
 &$public {
  param($root)
  $script:FixtureContext.packaged=$false
  Assert-PublicInstallVisibility (Join-Path $root 'AppData\Local\Companion')
  $script:FixtureContext.packaged=$true
  Assert-PublicInstallVisibility (Join-Path $root 'custom\Companion')
 } $root
}
$resolved=[IO.Path]::GetFullPath($root)
if(!$resolved.StartsWith($fixtureBase+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'FIXTURE_CLEANUP_PATH_INVALID'}
Remove-Item -LiteralPath $resolved -Recurse -Force
Write-Output ('RESULT: '+$passed+'/'+$passed+' PASS')
