param(
    [string]$PrivateNeedlesPath
)
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$extensions=@('.ps1','.psm1','.json','.md','.txt','.toml','.yml','.yaml','.cmd','.bat','.mjs','.js')
$rules=@(
    @{Name='absolute-user-profile-path'; Pattern='(?i)[A-Z]:\\Users\\(?!<USER>)[^\\\r\n]+\\'},
    @{Name='real-machine-sid'; Pattern='S-1-5-21-(?:\d{5,}-){2,}\d{5,}'},
    @{Name='private-key-material'; Pattern='-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'},
    @{Name='browser-snapshot-cache-path'; Pattern='(?i)browser-snapshots\\v1\\[0-9a-f]{64}'},
    @{Name='dpapi-ciphertext-field'; Pattern='(?i)"(?:dpapi|ciphertext|encryptedKey|encryptedSecret)"\s*:\s*"[^"<][^"]{12,}"'}
)
$needles=@()
if($PrivateNeedlesPath){
    if(!(Test-Path -LiteralPath $PrivateNeedlesPath -PathType Leaf)){throw 'PRIVATE_NEEDLES_FILE_NOT_FOUND'}
    $needles=@(Get-Content -LiteralPath $PrivateNeedlesPath | Where-Object { ![string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
}
$findings=@()
Get-ChildItem -LiteralPath $root -Recurse -File -Force | Where-Object {
    $_.FullName -notmatch '[\\/]\.git[\\/]' -and
    ($extensions -contains $_.Extension.ToLowerInvariant() -or $_.Name -in @('VERSION','.gitignore'))
} | ForEach-Object {
    $file=$_
    $lineNo=0
    Get-Content -LiteralPath $file.FullName -ErrorAction Stop | ForEach-Object {
        $lineNo++
        $line=[string]$_
        foreach($rule in $rules){
            if($line -match $rule.Pattern){
                $findings += [pscustomobject]@{File=$file.FullName.Substring($root.Length+1);Line=$lineNo;Category=$rule.Name}
            }
        }
        foreach($needle in $needles){
            if($needle.Length -ge 4 -and $line.IndexOf($needle,[StringComparison]::OrdinalIgnoreCase) -ge 0){
                $findings += [pscustomobject]@{File=$file.FullName.Substring($root.Length+1);Line=$lineNo;Category='private-needle'}
                break
            }
        }
    }
}
if($findings.Count){
    $findings | Sort-Object File,Line,Category | Format-Table -AutoSize
    throw ('PUBLIC_TREE_PRIVACY_SCAN_FAILED: '+$findings.Count+' finding(s)')
}
Write-Output 'PASS: public tree privacy scan found no blocked machine-specific or credential material.'
