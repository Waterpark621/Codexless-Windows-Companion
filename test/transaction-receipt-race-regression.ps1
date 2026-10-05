$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\InstallTransaction.psm1') -Force
$root=Join-Path $PSScriptRoot ('.fixtures\transaction-receipt-race-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force|Out-Null
$failures=[Collections.Generic.List[string]]::new()
$observed=0

function New-Fixture {
    $folder=Join-Path $root ([Guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $folder|Out-Null
    $script:payload=Join-Path $folder 'payload';$script:candidate=Join-Path $folder 'candidate'
    New-Item -ItemType Directory -Path $payload,$candidate|Out-Null
    [IO.File]::WriteAllText((Join-Path $payload 'fixture.txt'),'old generation')
    [IO.File]::WriteAllText((Join-Path $candidate 'fixture.txt'),'new generation')
    $script:destination=Join-Path $folder 'destination'
    $script:oldDigest=Get-TransactionTreeDigest $payload;$script:newDigest=Get-TransactionTreeDigest $candidate
    $script:mock=[pscustomobject]@{Task=$null;Running=$false}
    $script:adapter=@{
        Validate={param($r,$p)}
        VerifyStage={param($path) (Get-TransactionTreeDigest $path) -cin @($oldDigest,$newDigest)}
        GetTask={$mock.Task}
        RegisterTask={param($path,$record) $mock.Task=$record.transactionId}
        AssertTask={param($record) if($mock.Task -cne $record.transactionId){throw 'foreign task'}}
        Start={param($path,$record) $mock.Running=$true}
        VerifyReady={param($path,$record) $mock.Running}
        Stop={param($path,$record) $mock.Running=$false}
        VerifyStopped={param($record) !$mock.Running}
        RemoveTask={param($record) $mock.Task=$null}
        Promote={param($path,$record) $mock.Task=$record.transactionId}
    }
    Invoke-InstallTransaction $destination $payload $adapter|Out-Null
}
function Replace-ReceiptIdentity {
    $p=Join-Path $script:destination 'install-owner.json'
    $x=Get-Content -LiteralPath $p -Raw|ConvertFrom-Json
    $x.transactionId=('f'*32)
    [IO.File]::WriteAllText($p,($x|ConvertTo-Json -Compress))
}
function Expect-Blocked([string]$Name,[scriptblock]$Body,[scriptblock]$Evidence){
    $script:observed++
    $blocked=$false
    try{& $Body|Out-Null}catch{$blocked=$true}
    $evidenceOk=$false
    try{$evidenceOk=[bool](& $Evidence)}catch{$evidenceOk=$false}
    if(!$blocked -or !$evidenceOk){
        $script:failures.Add($Name)
        Write-Output "FAIL $Name"
    }else{
        Write-Output "PASS $Name"
    }
}

New-Fixture
$originalStop=$adapter.Stop
$adapter.Stop={
    param($path,$record)
    & $originalStop $path $record
    Replace-ReceiptIdentity
}.GetNewClosure()
Expect-Blocked 'Update rejects install-owner replacement after stop before promotion' {
    Invoke-OwnedUpdate $destination $candidate $adapter
} {
    (Test-Path -LiteralPath (Join-Path $destination 'incomplete-install.json')) -and
    ((Get-Content -LiteralPath (Join-Path $destination 'install-owner.json') -Raw|ConvertFrom-Json).transactionId -ceq ('f'*32))
}

New-Fixture
$owned=Get-OwnedInstall $destination $adapter
$originalStop=$adapter.Stop
$adapter.Stop={
    param($path,$record)
    & $originalStop $path $record
    Replace-ReceiptIdentity
}.GetNewClosure()
Expect-Blocked 'Uninstall rejects receipt replacement before removing task or payload' {
    Invoke-OwnedUninstall $destination $adapter
} {
    ($null -ne $mock.Task) -and
    (Test-Path -LiteralPath (Join-Path $owned.generation 'fixture.txt')) -and
    (Test-Path -LiteralPath (Join-Path $destination 'incomplete-install.json'))
}

if($failures.Count){
    throw ("TRANSACTION_RECEIPT_RACE_REGRESSION: {0}/{1} desired fail-closed assertions failed: {2}" -f $failures.Count,$observed,($failures -join '; '))
}
Write-Output ("RESULT: {0}/{0} PASS; receipt-race regression expectations satisfied" -f $observed)
