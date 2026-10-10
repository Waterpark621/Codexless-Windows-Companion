$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\BrowserSnapshotStore.psm1') -Force
$root=Join-Path $PSScriptRoot ('.fixtures\browser-store-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root -Force
$count=0
function Assert([bool]$value){if(!$value){throw 'assertion failed'}}
function Test([string]$name,[scriptblock]$body){& $body;$script:count++;Write-Output ('PASS '+$name)}
$workspace=Join-Path $root 'project'
$null=New-Item -ItemType Directory -Path $workspace
$store=Initialize-WorkspaceBrowserSnapshotStore $workspace
$sandbox=([Security.Principal.NTAccount]::new('CodexSandboxUsers')).Translate([Security.Principal.SecurityIdentifier])
Test 'Cache permits sandbox read/execute without sandbox write access' {
    $acl=Get-Acl -LiteralPath (Split-Path $store -Parent)
    $rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    $rule=@($rules|Where-Object {$_.IdentityReference.Value -eq $sandbox.Value})
    Assert ($acl.AreAccessRulesProtected -and $rules.Count -eq 3 -and $rule.Count -eq 1)
    Assert (($rule[0].FileSystemRights -band [Security.AccessControl.FileSystemRights]::ReadAndExecute) -eq [Security.AccessControl.FileSystemRights]::ReadAndExecute)
    Assert (($rule[0].FileSystemRights -band [Security.AccessControl.FileSystemRights]::Write) -eq 0)
}
Test 'Repeated initialization verifies the existing ACL without rewriting it' {
    Assert ((Initialize-WorkspaceBrowserSnapshotStore $workspace) -ceq $store)
}
Test 'An existing inherited workspace directory is refused rather than silently adopted' {
    $other=Join-Path $root 'unowned';$null=New-Item -ItemType Directory -Path $other
    $null=New-Item -ItemType Directory -Path (Join-Path $other '.codexless-browser-runtime-v1')
    $failed=$false;try{Initialize-WorkspaceBrowserSnapshotStore $other|Out-Null}catch{$failed=$_.Exception.Message -ceq 'BROWSER_SNAPSHOT_ACCESS_UNTRUSTED'}
    Assert $failed
}
Test 'Broadening the sandbox cache rule to write access is detected' {
    $cache=Split-Path $store -Parent
    $acl=Get-Acl -LiteralPath $cache
    $acl.SetAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sandbox,'Modify','ContainerInherit,ObjectInherit','None','Allow'))
    [IO.Directory]::SetAccessControl($cache,$acl)
    $failed=$false;try{Initialize-WorkspaceBrowserSnapshotStore $workspace|Out-Null}catch{$failed=$_.Exception.Message -ceq 'BROWSER_SNAPSHOT_ACCESS_UNTRUSTED'}
    Assert $failed
}
"RESULT: $count/$count PASS; disposable cache ACL fixtures only"
