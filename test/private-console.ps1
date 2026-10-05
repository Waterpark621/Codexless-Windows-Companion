$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\PrivateConsole.psm1') -Force
$helper = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\Signal-PrivateConsole.ps1'))
$node = (Get-Command node.exe -ErrorAction Stop).Source
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$fixtureRoot = Join-Path $PSScriptRoot ('fixtures-console-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
$results = [Collections.Generic.List[object]]::new()
function Assert-True([bool]$Value,[string]$Message='assertion failed') { if (!$Value) { throw $Message } }
function Test([string]$Name,[scriptblock]$Body) { & $Body; $results.Add($Name); Write-Output "PASS $Name" }
function Wait-Fixture([string]$Path) {
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while (!(Test-Path -LiteralPath $Path)) { if ([DateTime]::UtcNow -ge $deadline) { throw "FIXTURE_NOT_READY $Path" }; Start-Sleep -Milliseconds 100 }
}
$fixtureScript = Join-Path $fixtureRoot 'fixture.mjs'
@'
import fs from 'node:fs';
import net from 'node:net';
const stem = process.argv[2];
let closing = false;
const server = net.createServer(socket => socket.end());
server.listen(0, '127.0.0.1', () => {
    fs.writeFileSync(stem+'.ready.json', JSON.stringify({pid:process.pid,ppid:process.ppid,port:server.address().port}));
});
const deadline = setTimeout(() => { fs.writeFileSync(stem+'.expired.json','{}'); process.exit(3); }, 45000);
process.once('SIGINT', async () => {
    if (closing) return;
    closing = true;
    fs.writeFileSync(stem+'.signal.json', JSON.stringify({signal:'SIGINT',pid:process.pid}));
    await new Promise(resolve => setTimeout(resolve,500));
    await new Promise(resolve => server.close(resolve));
    fs.writeFileSync(stem+'.closed.json', JSON.stringify({asyncCleanupCompleted:true}));
    clearTimeout(deadline);
    process.exit(0);
});
'@ | Set-Content -LiteralPath $fixtureScript -Encoding utf8

Test 'Receipt and ancestry reject reused PID, wrong owner, executable, and foreign console member' {
    $root = [pscustomobject]@{pid=101;parentPid=50;createdAt='2026-10-03T00:00:00.0000000Z';userSid='S-1-5-21-1-2-3-4';executable='C:\Windows\powershell.exe';commandLine='exact'}
    $receipt = [pscustomobject]@{version=1;pid=101;createdAt=$root.createdAt;userSid=$root.userSid;executable=$root.executable;commandLine='exact'}
    Assert-True (Test-PrivateConsoleReceipt $receipt $root $root.userSid)
    foreach ($field in @('pid','createdAt','userSid','executable','commandLine')) {
        $bad = $root.PSObject.Copy(); $bad.$field = if ($field -eq 'pid') { 102 } else { 'wrong' }
        Assert-True (!(Test-PrivateConsoleReceipt $receipt $bad $root.userSid))
    }
    $child = [pscustomobject]@{pid=102;parentPid=101;createdAt='2026-10-03T00:00:01.0000000Z';userSid=$root.userSid}
    Assert-True (Test-PrivateConsoleMember $root $child @{101=$root;102=$child} 199)
    $child.parentPid=55
    Assert-True (!(Test-PrivateConsoleMember $root $child @{101=$root;102=$child} 199))
    $child.parentPid=101; $child.userSid='other'
    Assert-True (!(Test-PrivateConsoleMember $root $child @{101=$root;102=$child} 199))
}

$sentinelStem = Join-Path $fixtureRoot 'sentinel'
$sentinelReceipt = Join-Path $fixtureRoot 'sentinel.receipt.json'
$sentinel = Start-PrivateConsoleProcess $node ('"'+$fixtureScript+'" "'+$sentinelStem+'"') $fixtureRoot $sentinelReceipt
Wait-Fixture ($sentinelStem+'.ready.json')
try {
    Test 'Real Windows private-console CTRL_C reaches Node SIGINT and awaits asynchronous cleanup' {
        $stem = Join-Path $fixtureRoot 'direct'
        $receipt = Join-Path $fixtureRoot 'direct.receipt.json'
        $r = Start-PrivateConsoleProcess $node ('"'+$fixtureScript+'" "'+$stem+'"') $fixtureRoot $receipt
        Wait-Fixture ($stem+'.ready.json')
        $ready=Get-Content -LiteralPath ($stem+'.ready.json') -Raw | ConvertFrom-Json
        $sentinelReady=Get-Content -LiteralPath ($sentinelStem+'.ready.json') -Raw | ConvertFrom-Json
        Assert-True (Test-PrivateConsoleListener $receipt ([int]$ready.port))
        Assert-True (!(Test-PrivateConsoleListener $receipt ([int]$sentinelReady.port)))
        Request-PrivateConsoleStop $receipt $helper 15
        Assert-True (Test-Path -LiteralPath ($stem+'.signal.json'))
        Assert-True (Test-Path -LiteralPath ($stem+'.closed.json'))
        Assert-True (!(Test-Path -LiteralPath $receipt))
        Assert-True ($null -eq (Get-ConsoleProcessIdentity $r.pid))
    }
    Test 'Existing PowerShell-to-Node wrapper can receive the same signal without bypassing Node cleanup' {
        $stem = Join-Path $fixtureRoot 'wrapper'
        $receipt = Join-Path $fixtureRoot 'wrapper.receipt.json'
        $command = '& "'+$node+'" "'+$fixtureScript+'" "'+$stem+'"'
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $r = Start-PrivateConsoleProcess $powershell ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand '+$encoded) $fixtureRoot $receipt
        Wait-Fixture ($stem+'.ready.json')
        $ready=Get-Content -LiteralPath ($stem+'.ready.json') -Raw | ConvertFrom-Json
        Assert-True (Test-PrivateConsoleListener $receipt ([int]$ready.port))
        Request-PrivateConsoleStop $receipt $helper 15
        Assert-True (Test-Path -LiteralPath ($stem+'.signal.json'))
        Assert-True (Test-Path -LiteralPath ($stem+'.closed.json'))
        Assert-True ($null -eq (Get-ConsoleProcessIdentity $r.pid))
    }
    Test 'Signals did not reach the unrelated private-console fixture' {
        Assert-True (!(Test-Path -LiteralPath ($sentinelStem+'.signal.json')))
        Assert-True ($null -ne (Get-ConsoleProcessIdentity $sentinel.pid))
    }
} finally {
    if (Test-Path -LiteralPath $sentinelReceipt) { Request-PrivateConsoleStop $sentinelReceipt $helper 15 }
}
Test 'Sentinel stops only when its own verified private console is requested' {
    Assert-True (Test-Path -LiteralPath ($sentinelStem+'.closed.json'))
    Assert-True ($null -eq (Get-ConsoleProcessIdentity $sentinel.pid))
}
Write-Output ("RESULT: {0}/{0} PASS; real benign Node/PowerShell processes only; evidence={1}" -f $results.Count,$fixtureRoot)
