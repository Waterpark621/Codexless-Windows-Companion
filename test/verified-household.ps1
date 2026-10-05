$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
# Load built-in commands before installing mocks; lazy module exports must not replace them.
Microsoft.PowerShell.Core\Import-Module Microsoft.PowerShell.Utility
Microsoft.PowerShell.Core\Import-Module Microsoft.PowerShell.Security
$shim=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\Start-VerifiedHousehold.ps1'))
$launcher="C:\Fixture owner's launcher"
$wrapper=Join-Path $launcher 'Start-Codexless-VerifiedRuntime.ps1'
$batch="C:\Fixture maintained app\bin\codexless-http.cmd"
$binaryRoot=Join-Path $launcher 'runtimes\codex-pinned'
$hashes=[ordered]@{'codex.exe'=('1'*64);'codex-command-runner.exe'=('2'*64);'codex-code-mode-host.exe'=('3'*64);'codex-windows-sandbox-setup.exe'=('4'*64)}
$binding=[pscustomobject]@{launcher=$batch;binaryRoot=$binaryRoot;hashes=[pscustomobject]$hashes}
$mock=[pscustomobject]@{changed=$null;invalidSignature=$null;nativeCalls=0;nativeArguments=$null;nativeCwd=$null;nativeCodex=$null;nativeSnapshot=$null;exitCode=0;hashReads=[Collections.Generic.List[string]]::new();signatureReads=[Collections.Generic.List[string]]::new()}
$results=[Collections.Generic.List[string]]::new()
function Assert-True([bool]$Value,[string]$Message='assertion failed'){if(!$Value){throw $Message}}
function Assert-Throws([scriptblock]$Body,[string]$Code){try{& $Body | Out-Null}catch{if($_.Exception.Message.Contains($Code)){return};throw};throw "Expected $Code"}
function Test([string]$Name,[scriptblock]$Body){& $Body;$results.Add($Name);Write-Output "PASS $Name"}
function Reset-Fixture{$mock.changed=$null;$mock.invalidSignature=$null;$mock.nativeCalls=0;$mock.hashReads.Clear();$mock.signatureReads.Clear();$mock.exitCode=0}
# Mock every shim dependency that could read installation state or start a native process.
function Import-Module{param($Name,[switch]$Force)}
function Get-Content{param($LiteralPath,[switch]$Raw);if($LiteralPath -cne (Join-Path $launcher 'verified-codex-runtime.json')){throw 'UNEXPECTED_BINDING_READ'};$binding | ConvertTo-Json -Depth 3}
function Get-FileHash{
    param($LiteralPath)
    $mock.hashReads.Add($LiteralPath)
    $value=if($LiteralPath -ceq $wrapper){'9073366C8180E6408D87D132D57F92D3E77115C2578E570F738E97E48D5F1214'}elseif($LiteralPath -ceq $batch){'E87800C1AF3EB9E695BF978B3C358906EA64E5516E9F0392348EB936C41F28E7'}else{$name=Split-Path $LiteralPath -Leaf;if($LiteralPath -cne (Join-Path $binaryRoot $name) -or !$hashes.Contains($name)){throw 'UNEXPECTED_BINARY_READ'};$hashes[$name]}
    if($LiteralPath -ceq $mock.changed){$value='0'*64}
    [pscustomobject]@{Hash=$value}
}
function Get-AuthenticodeSignature{param($LiteralPath);$mock.signatureReads.Add($LiteralPath);[pscustomobject]@{Status=if($LiteralPath -ceq $mock.invalidSignature){'NotSigned'}else{'Valid'}}}
function Get-Command{param($Name,$ErrorAction);if($Name -cne 'node.exe'){throw 'UNEXPECTED_NATIVE_COMMAND'};[pscustomobject]@{Source='Invoke-FixtureNode'}}
function Invoke-FixtureNode{
    param($EntryPoint,$Mode)
    $mock.nativeCalls++;$mock.nativeArguments=@($EntryPoint,$Mode);$mock.nativeCwd=(Get-Location).Path
    $mock.nativeCodex=$env:CODEX_BIN;$mock.nativeSnapshot=$env:CODEXLESS_BROWSER_SNAPSHOT_STORE
    $global:LASTEXITCODE=$mock.exitCode
}
function Invoke-Fixture{
    $oldCodex=$env:CODEX_BIN;$oldSnapshot=$env:CODEXLESS_BROWSER_SNAPSHOT_STORE
    try{& $shim -LauncherDirectory $launcher -VerifiedWrapper $wrapper}finally{$env:CODEX_BIN=$oldCodex;$env:CODEXLESS_BROWSER_SNAPSHOT_STORE=$oldSnapshot}
}
Test 'Unknown verified wrapper rejects before binding or native launch'{
    Reset-Fixture;$mock.changed=$wrapper
    Assert-Throws {Invoke-Fixture} 'HOUSEHOLD_VERIFIED_WRAPPER_UNKNOWN'
    Assert-True ($mock.nativeCalls -eq 0 -and $mock.hashReads.Count -eq 1 -and $mock.signatureReads.Count -eq 0)
}
Test 'Changed maintained batch shim rejects before pinned binaries or native launch'{
    Reset-Fixture;$mock.changed=$batch
    Assert-Throws {Invoke-Fixture} 'HOUSEHOLD_BATCH_SHIM_UNKNOWN'
    Assert-True ($mock.nativeCalls -eq 0 -and $mock.hashReads.Count -eq 2 -and $mock.signatureReads.Count -eq 0)
}
Test 'Each of the four changed pinned binaries blocks native launch'{
    foreach($name in $hashes.Keys){Reset-Fixture;$mock.changed=Join-Path $binaryRoot $name;Assert-Throws {Invoke-Fixture} 'HOUSEHOLD_PINNED_BINARY_CHANGED';Assert-True ($mock.nativeCalls -eq 0)}
}
Test 'Each of the four invalid pinned signatures blocks native launch'{
    foreach($name in $hashes.Keys){Reset-Fixture;$mock.invalidSignature=Join-Path $binaryRoot $name;Assert-Throws {Invoke-Fixture} 'HOUSEHOLD_PINNED_SIGNATURE_INVALID';Assert-True ($mock.nativeCalls -eq 0)}
}
Test 'Known guards invoke maintained Node entrypoint once with pinned env and unchanged CWD'{
    Reset-Fixture;$mock.exitCode=7;$cwd=(Get-Location).Path
    Invoke-Fixture
    Assert-True ($mock.hashReads.Count -eq 6 -and $mock.signatureReads.Count -eq 4 -and $mock.nativeCalls -eq 1)
    Assert-True ($mock.nativeArguments[0] -ceq 'C:\Fixture maintained app\scripts\launch.mjs' -and $mock.nativeArguments[1] -ceq 'http')
    Assert-True ($mock.nativeCodex -ceq (Join-Path $binaryRoot 'codex.exe') -and $mock.nativeSnapshot -ceq (Join-Path $launcher 'runtimes\browser-snapshots\v1'))
    Assert-True ($mock.nativeCwd -ceq $cwd -and (Get-Location).Path -ceq $cwd -and $LASTEXITCODE -eq 7)
}
Write-Output ("RESULT: {0}/{0} PASS; hashes/signatures/binding/native call mocked; no household actions" -f $results.Count)
