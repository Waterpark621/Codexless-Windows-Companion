Set-StrictMode -Version Latest

function Resolve-CompanionMutationRoot {
    param([Parameter(Mandatory=$true)][string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root) -or $Root -notmatch '^[A-Za-z]:[\\/]' -or
        $Root.Contains('"') -or $Root.Contains([char]13) -or $Root.Contains([char]10)) {
        throw 'MUTATION_ROOT_INVALID'
    }
    $full=[IO.Path]::GetFullPath($Root).TrimEnd('\')
    if ($full.Length -le 3) { throw 'MUTATION_ROOT_INVALID' }
    $parent=Split-Path $full -Parent
    if ([string]::IsNullOrWhiteSpace($parent) -or !(Test-Path -LiteralPath $parent -PathType Container)) { throw 'MUTATION_ROOT_INVALID' }
    $cursor=$parent
    while($cursor){
        if((Get-Item -LiteralPath $cursor -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'MUTATION_ROOT_INVALID'}
        $next=Split-Path $cursor -Parent
        if([string]::IsNullOrWhiteSpace($next) -or $next -ceq $cursor){break}
        $cursor=$next
    }
    $full
}

function Get-CompanionMutationRootDigest {
    param([Parameter(Mandatory=$true)][string]$Root)
    $full=Resolve-CompanionMutationRoot $Root
    $sha=[Security.Cryptography.SHA256]::Create()
    try {
        ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($full.ToLowerInvariant())))).Replace('-','').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Invoke-CompanionMutationLocked {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][scriptblock]$Body
    )
    $full=Resolve-CompanionMutationRoot $Root
    $digest=Get-CompanionMutationRootDigest $full
    $parent=Split-Path $full -Parent
    $marker=Join-Path $parent ('.codexless-mutation-'+$digest+'.lock')
    $mutex=$null
    $held=$false
    $markerOwned=$false
    $markerToken=[Guid]::NewGuid().ToString('N')
    try {
        try { $mutex=[Threading.Mutex]::new($false,('Global\CodexlessMutation-'+$digest)) }
        catch { throw 'MUTATION_LOCK_UNAVAILABLE' }
        try {
            $held=$mutex.WaitOne(0)
        } catch [Threading.AbandonedMutexException] {
            $held=$true
            throw 'MUTATION_LOCK_ABANDONED: Explicit verified recovery is required.'
        } catch {
            throw 'MUTATION_LOCK_UNAVAILABLE'
        }
        if (!$held) { throw 'MUTATION_CONCURRENT_OPERATION' }
        if (Test-Path -LiteralPath $marker) { throw 'MUTATION_LOCK_ABANDONED: Durable mutation intent remains; explicit verified recovery is required.' }
        $record=[ordered]@{version=1;rootDigest=$digest;token=$markerToken;pid=$PID;createdAt=[DateTime]::UtcNow.ToString('o')}
        $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($record|ConvertTo-Json -Compress))
        $stream=$null
        try {
            $stream=[IO.File]::Open($marker,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
            $stream.Write($bytes,0,$bytes.Length)
            $stream.Flush($true)
            $markerOwned=$true
        } finally { if($stream){$stream.Dispose()} }
        & $Body
    } finally {
        if ($markerOwned) {
            $safeToRemove=$false
            try {
                if(Test-Path -LiteralPath $marker -PathType Leaf){
                    $item=Get-Item -LiteralPath $marker -Force -ErrorAction Stop
                    if(!($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $item.Length -le 4096){
                        $current=Get-Content -LiteralPath $marker -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
                        $safeToRemove=($current.version -eq 1 -and $current.rootDigest -ceq $digest -and $current.token -ceq $markerToken -and [int]$current.pid -eq $PID)
                    }
                }
            } catch { $safeToRemove=$false }
            if($safeToRemove){Remove-Item -LiteralPath $marker -Force -ErrorAction Stop}
            else { throw 'MUTATION_LOCK_MARKER_CHANGED: Durable mutation intent was replaced; explicit verified recovery is required.' }
        }
        if ($held -and $null -ne $mutex) {
            try { $mutex.ReleaseMutex() } catch {}
        }
        if ($null -ne $mutex) { $mutex.Dispose() }
    }
}

Export-ModuleMember -Function Get-CompanionMutationRootDigest,Invoke-CompanionMutationLocked
