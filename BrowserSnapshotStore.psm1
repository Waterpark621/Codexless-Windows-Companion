Set-StrictMode -Version Latest

function Initialize-WorkspaceBrowserSnapshotStore {
    param([Parameter(Mandatory=$true)][string]$Workspace)
    $workspacePath=[IO.Path]::GetFullPath($Workspace)
    $current=$workspacePath
    while($current){
        $item=Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if(!$item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'BROWSER_SNAPSHOT_PATH_UNTRUSTED'}
        $parent=Split-Path $current -Parent
        if(!$parent -or $parent -ceq $current){break}
        $current=$parent
    }
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
    $system=[Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    try{$sandbox=([Security.Principal.NTAccount]::new('CodexSandboxUsers')).Translate([Security.Principal.SecurityIdentifier])}
    catch{throw 'BROWSER_SANDBOX_SETUP_REQUIRED'}
    # A separate protected cache keeps copied trusted code out of the sandbox's
    # workspace write access. The selected workspace remains the only root.
    $store=Join-Path $workspacePath '.codexless-browser-runtime-v1'
    if(!(Test-Path -LiteralPath $store)){
        $acl=New-Object Security.AccessControl.DirectorySecurity
        $acl.SetOwner($sid)
        $acl.SetAccessRuleProtection($true,$false)
        foreach($identity in @($sid,$system)){
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
        }
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sandbox,'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow'))
        # Windows PowerShell/.NET Framework creates the directory with this
        # descriptor, without first exposing a writable inherited cache.
        $null=[IO.Directory]::CreateDirectory($store,$acl)
    }
    $item=Get-Item -LiteralPath $store -Force -ErrorAction Stop
    if(!$item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'BROWSER_SNAPSHOT_PATH_UNTRUSTED'}
    $acl=Get-Acl -LiteralPath $store -ErrorAction Stop
    if(!$acl.AreAccessRulesProtected -or $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $sid.Value){throw 'BROWSER_SNAPSHOT_ACCESS_UNTRUSTED'}
    $rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    if($rules.Count -ne 3){throw 'BROWSER_SNAPSHOT_ACCESS_UNTRUSTED'}
    foreach($rule in $rules){
        $expected=if($rule.IdentityReference.Value -eq $sandbox.Value){[Security.AccessControl.FileSystemRights]::ReadAndExecute}else{[Security.AccessControl.FileSystemRights]::FullControl}
        if($rule.IdentityReference.Value -notin @($sid.Value,$system.Value,$sandbox.Value) -or
           $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or $rule.IsInherited -or
           $rule.InheritanceFlags -ne ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit) -or
           $rule.PropagationFlags -ne [Security.AccessControl.PropagationFlags]::None -or
           ($rule.FileSystemRights -band (-bnot [Security.AccessControl.FileSystemRights]::Synchronize)) -ne ($expected -band (-bnot [Security.AccessControl.FileSystemRights]::Synchronize))){throw 'BROWSER_SNAPSHOT_ACCESS_UNTRUSTED'}
    }
    Join-Path $store 'snapshots'
}

Export-ModuleMember -Function Initialize-WorkspaceBrowserSnapshotStore
