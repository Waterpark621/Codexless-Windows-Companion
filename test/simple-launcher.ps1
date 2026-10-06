$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module (Join-Path $repo 'LauncherUi.psm1') -Force -DisableNameChecking
$module=Get-Module LauncherUi
$root=Join-Path $PSScriptRoot ('.fixtures/launcher-'+[Guid]::NewGuid().ToString('N'))
$generation=Join-Path $root 'owned-generation'
New-Item -ItemType Directory -Path $root,$generation -Force|Out-Null
$passed=0
function Assert([bool]$v){if(!$v){throw 'launcher assertion failed'}}
function Test([string]$name,[scriptblock]$body){& $body;$script:passed++;Write-Output ('PASS '+$name)}
function Refuses([scriptblock]$body,[string]$prefix){$failed=$false;try{& $body|Out-Null}catch{$failed=$_.Exception.Message -like ($prefix+'*')};Assert $failed}
$state=[pscustomobject]@{reads=[Collections.Generic.Queue[string]]::new();prompts=[Collections.Generic.List[string]]::new();calls=[Collections.Generic.List[object]]::new();events=[Collections.Generic.List[string]]::new();foreign=$false;unpublished=$false;tampered=$false}
$services=@{
 Version={param($p) '0.1.0-preview.2'}
 Trust={param($v) $state.events.Add('trust');if($state.unpublished){throw 'LAUNCHER_RELEASE_TRUST_UNAVAILABLE'};'a'*64}.GetNewClosure()
 Verify={param($p,$d) $state.events.Add('verify');if($state.tampered){throw 'LAUNCHER_PAYLOAD_CHANGED'};Assert ($d -ceq ('a'*64))}.GetNewClosure()
 Owned={param($p) $state.events.Add('owned');if($state.foreign){throw 'TRANSACTION_OWNER_INVALID'};[pscustomobject]@{generation=$generation}}.GetNewClosure()
 Invoke={param($p,$a) $copy=@{};foreach($key in $a.Keys){$copy[$key]=$a[$key]};$state.calls.Add([pscustomobject]@{script=$p;parameters=$copy})}.GetNewClosure()
 Client={param($p) Join-Path $root 'qualified-client.exe'}.GetNewClosure()
 Read={param($p) $state.prompts.Add($p);if(!$state.reads.Count){throw 'unexpected prompt'};$state.reads.Dequeue()}.GetNewClosure()
 Write={param($m)}
}
& $module {param($s) $script:UiFixture=$s;function script:New-LauncherUiServices {$script:UiFixture}} $services
function Reset([string[]]$Answers=@()){$state.calls.Clear();$state.prompts.Clear();$state.events.Clear();$state.reads.Clear();$state.foreign=$false;$state.unpublished=$false;$state.tampered=$false;foreach($a in $Answers){$state.reads.Enqueue($a)}}
function Run([string]$Action){Invoke-SimpleLauncher -Action $Action -PayloadRoot $repo -Root $root}

Test 'Zero tunnel installation hides external trust plumbing and passes exact literal project' {
 Reset @('C:/Projects/Example & sibling','n');Run Install
 Assert ($state.prompts.Count -eq 2 -and $state.events[0] -ceq 'trust' -and $state.events[1] -ceq 'verify')
 $c=$state.calls[0];Assert ($c.script -ceq (Join-Path $repo 'Install.ps1') -and $c.parameters.ProjectPath -ceq 'C:/Projects/Example & sibling' -and $c.parameters.NoTunnel -and $c.parameters.TrustedPayloadSha256 -ceq ('a'*64))
 Assert (!$c.parameters.ContainsKey('TunnelRuntimeKey'))
}
Test 'One tunnel install passes ID and delegates secure runtime-key prompt to qualified backend' {
 Reset @('C:/Projects/Example','y','tunnel_fixture');Run Install
 $c=$state.calls[0];Assert ($state.prompts.Count -eq 3 -and $c.parameters.TunnelId -ceq 'tunnel_fixture' -and $c.parameters.TunnelAlias -ceq 'default' -and !$c.parameters.ContainsKey('NoTunnel') -and !$c.parameters.ContainsKey('TunnelRuntimeKey'))
}
Test 'Default empty choice selects zero tunnels' {Reset @('C:/Projects/Example','');Run Install;Assert $state.calls[0].parameters.NoTunnel}
Test 'Unknown install choice refuses before backend mutation' {Reset @('C:/Projects/Example','perhaps');Refuses {Run Install} 'LAUNCHER_CHOICE_INVALID';Assert ($state.calls.Count -eq 0)}
Test 'Unpublished exact release refuses before configuration prompts or backend' {Reset;$state.unpublished=$true;Refuses {Run Install} 'LAUNCHER_RELEASE_TRUST_UNAVAILABLE';Assert ($state.prompts.Count -eq 0 -and $state.calls.Count -eq 0)}
Test 'Changed local payload refuses before prompts or backend' {Reset;$state.tampered=$true;Refuses {Run Install} 'LAUNCHER_PAYLOAD_CHANGED';Assert ($state.prompts.Count -eq 0 -and $state.calls.Count -eq 0)}
foreach($action in @('Start','Stop','Restart','Status','Doctor')){
 Test ($action+' dispatches exact verified installed script without online trust or setup prompts') {
  Reset;Run $action
  Assert ($state.calls.Count -eq 1 -and $state.calls[0].script -ceq (Join-Path $generation ($action+'.ps1')) -and $state.calls[0].parameters.InstallDirectory -ceq $root -and $state.prompts.Count -eq 0 -and $state.events.Count -eq 1 -and $state.events[0] -ceq 'owned')
 }
}
Test 'Foreign/ambiguous installed owner prevents lifecycle dispatch' {Reset;$state.foreign=$true;Refuses {Run Start} 'TRANSACTION_OWNER_INVALID';Assert ($state.calls.Count -eq 0)}
Test 'Tunnel numbered menu maps all five operations to installed backend and never supplies a plaintext key' {
 Reset @('1','2','office','tunnel_fixture','3','office','4','office','5','0');Run Tunnels
 Assert (($state.calls|ForEach-Object {$_.parameters.Action}) -join '|' -ceq 'List|Add|Remove|RotateKey|Status')
 foreach($c in $state.calls){Assert ($c.script -ceq (Join-Path $generation 'Tunnels.ps1') -and $c.parameters.Root -ceq $root -and !$c.parameters.ContainsKey('RuntimeApiKey'))}
 Assert ($state.calls[1].parameters.ProfileId -ceq 'office' -and $state.calls[1].parameters.Alias -ceq 'office' -and $state.calls[1].parameters.TunnelClientExe -ceq (Join-Path $root 'qualified-client.exe'))
 Assert ($state.calls[2].parameters.ProfileId -ceq 'office' -and $state.calls[3].parameters.ProfileId -ceq 'office')
}
Test 'Unknown tunnel menu choice does not mutate and exit returns cleanly' {Reset @('unknown','0');Run Tunnels;Assert ($state.calls.Count -eq 0)}

function ReleaseFixture {
 [pscustomobject]@{draft=$false;prerelease=$true;tag_name='v0.1.0-preview.2';html_url='https://github.com/Waterpark621/Codexless-Windows-Companion/releases/tag/v0.1.0-preview.2';target_commitish=('b'*40);body=('- **Companion payload tree SHA-256** (required by Install.ps1): `'+('a'*64)+'`');assets=@([pscustomobject]@{name='Codexless-Windows-Companion-0.1.0-preview.2-'+('b'*12)+'.zip';browser_download_url='https://github.com/Waterpark621/Codexless-Windows-Companion/releases/download/v0.1.0-preview.2/Codexless-Windows-Companion-0.1.0-preview.2-'+('b'*12)+'.zip';digest='sha256:'+('c'*64)})}
}
Test 'Published exact release note is the external expected digest authority' {$d=ReleaseFixture;Assert ((& $module {param($d) Get-LauncherReleaseDigest $d '0.1.0-preview.2'} $d) -ceq ('a'*64))}
foreach($case in @('draft','wrong-tag','wrong-owner-url','missing-digest','duplicate-digest','wrong-asset','extra-asset','missing-asset-checksum','moving-commit')){
 Test ('Release trust rejects '+$case) {
  $d=ReleaseFixture
  switch($case){
   draft {$d.draft=$true}
   wrong-tag {$d.tag_name='v0.1.0-preview.1'}
   wrong-owner-url {$d.html_url='https://foreign.invalid/release'}
   missing-digest {$d.body='No digest'}
   duplicate-digest {$d.body=$d.body+"`n"+$d.body}
   wrong-asset {$d.assets[0].browser_download_url='https://foreign.invalid/payload.zip'}
   extra-asset {$d.assets=@($d.assets[0],$d.assets[0])}
   missing-asset-checksum {$d.assets[0].digest=$null}
   moving-commit {$d.target_commitish='main'}
  }
  Refuses {& $module {param($d) Get-LauncherReleaseDigest $d '0.1.0-preview.2'} $d} 'LAUNCHER_RELEASE_TRUST_INVALID'
 }
}
Test 'Invalid version refuses before network request' {Refuses {& $module {Get-LauncherReleaseTrust '../latest'}} 'LAUNCHER_VERSION_INVALID'}
Test 'Backend nonzero exit remains visible failure' {
 $script=Join-Path $root 'failure.ps1';[IO.File]::WriteAllText($script,'exit 2')
 $failed=$false
 try{& $module {param($p) Invoke-LauncherBackend $p @{}} $script}catch{$failed=$_.Exception.Message -like 'LAUNCHER_BACKEND_FAILED*' -and $_.Exception.Data['LauncherExitCode'] -eq 2}
 Assert $failed
}
Test 'CMD launchers use only fixed PowerShell calls and work from unrelated cwd with spaces/metacharacters' {
 $cmdRoot=Join-Path $root 'space & literal folder';New-Item -ItemType Directory -Path $cmdRoot|Out-Null
 [IO.File]::WriteAllText((Join-Path $cmdRoot 'Launcher.ps1'),@'
param([string]$Action)
if($Action -notin @('Install','Start','Stop','Restart','Status','Doctor','Tunnels')){exit 99}
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'called.txt'),$Action)
exit 7
'@)
 foreach($action in @('Install','Start','Stop','Restart','Status','Doctor','Tunnels')){
  $name=$action.ToUpperInvariant()+'.cmd';$raw=[IO.File]::ReadAllText((Join-Path $repo $name))
  Assert ($raw -ceq ('@echo off'+"`r`n"+'"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Launcher.ps1" -Action '+$action+"`r`n"))
  Copy-Item (Join-Path $repo $name) (Join-Path $cmdRoot $name)
  $info=[Diagnostics.ProcessStartInfo]::new()
  $info.FileName=$env:ComSpec;$info.Arguments='/d /s /c ""'+(Join-Path $cmdRoot $name)+'""'
  $info.WorkingDirectory=$env:SystemRoot;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
  $process=[Diagnostics.Process]::Start($info)
  try{Assert ($process.WaitForExit(15000));$code=$process.ExitCode}finally{$process.Dispose()}
  Assert ($code -eq 7 -and [IO.File]::ReadAllText((Join-Path $cmdRoot 'called.txt')) -ceq $action)
 }
}

$resolved=[IO.Path]::GetFullPath($root);$expected=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '.fixtures'))+[IO.Path]::DirectorySeparatorChar
if(!$resolved.StartsWith($expected,[StringComparison]::OrdinalIgnoreCase)){throw 'fixture cleanup path invalid'}
Remove-Item -LiteralPath $resolved -Recurse -Force
Write-Output ("RESULT: {0}/{0} PASS; wrapper routing, real CMD/PowerShell invocation and fail-closed external trust fixtures; no production/native owner mutation" -f $passed)
