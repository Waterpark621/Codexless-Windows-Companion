param([Parameter(Mandatory=$true)][string]$ReceiptPath,[ValidateRange(1,120)][int]$TimeoutSeconds=60)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PrivateConsole.psm1') -Force
$attached = $false
try {
    $receipt = Get-Content -LiteralPath $ReceiptPath -Raw | ConvertFrom-Json
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $root = Get-ConsoleProcessIdentity ([int]$receipt.pid)
    if (!(Test-PrivateConsoleReceipt $receipt $root $sid)) { throw 'PRIVATE_CONSOLE_RECEIPT_INVALID' }
    # Detach only this disposable helper. Never detach the supervisor/Desktop/user terminal.
    [Codexless.PrivateConsole]::FreeConsole() | Out-Null
    if (![Codexless.PrivateConsole]::AttachConsole([uint32]$root.pid)) { throw 'PRIVATE_CONSOLE_ATTACH_FAILED' }
    $attached = $true
    if (![Codexless.PrivateConsole]::SetConsoleCtrlHandler([IntPtr]::Zero,$true)) { throw 'PRIVATE_CONSOLE_HANDLER_FAILED' }
    $members = @([Codexless.PrivateConsole]::Members())
    if ($members -notcontains [uint32]$root.pid) { throw 'PRIVATE_CONSOLE_ROOT_MISSING' }
    $identities = @{}
    foreach ($p in Get-CimInstance Win32_Process -ErrorAction Stop) {
        # Only obtain owner information for the bounded console ancestry we validate below.
        $identities[[int]$p.ProcessId] = $p
    }
    $verified = @{}
    foreach ($memberPid in $members) {
        $cursor = Get-ConsoleProcessIdentity ([int]$memberPid)
        for ($depth=0; $depth -lt 64 -and $null -ne $cursor; $depth++) {
            $verified[$cursor.pid] = $cursor
            if ($cursor.pid -eq $root.pid -or $cursor.pid -eq $PID) { break }
            if (!$identities.ContainsKey($cursor.parentPid)) { break }
            $cursor = Get-ConsoleProcessIdentity $cursor.parentPid
        }
    }
    foreach ($memberPid in $members) {
        if (!(Test-PrivateConsoleMember $root $verified[[int]$memberPid] $verified $PID)) { throw 'PRIVATE_CONSOLE_FOREIGN_MEMBER' }
    }
    # CTRL_C cannot target a process group. Send it only after proving this private console.
    $again = @([Codexless.PrivateConsole]::Members())
    if (($members | Sort-Object) -join ',' -cne (($again | Sort-Object) -join ',')) { throw 'PRIVATE_CONSOLE_CHANGED' }
    $rootAgain = Get-ConsoleProcessIdentity ([int]$root.pid)
    if (!(Test-PrivateConsoleReceipt $receipt $rootAgain $sid)) { throw 'PRIVATE_CONSOLE_RECEIPT_INVALID' }
    if (![Codexless.PrivateConsole]::GenerateConsoleCtrlEvent(0,0)) { throw 'PRIVATE_CONSOLE_SIGNAL_FAILED' }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        # Keep the console alive while Node runs asynchronous runtime.close().
        $remaining = @([Codexless.PrivateConsole]::Members() | Where-Object { $_ -ne $PID })
        if ($remaining.Count -eq 0) { break }
        if ([DateTime]::UtcNow -ge $deadline) { throw 'PRIVATE_CONSOLE_STOP_TIMEOUT' }
        Start-Sleep -Milliseconds 100
    } while ($true)
    $saved = Get-Content -LiteralPath $ReceiptPath -Raw | ConvertFrom-Json
    if ($saved.pid -eq $receipt.pid -and $saved.createdAt -ceq $receipt.createdAt) { Remove-Item -LiteralPath $ReceiptPath }
    exit 0
} catch {
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    exit 1
} finally {
    if ($attached) { [Codexless.PrivateConsole]::FreeConsole() | Out-Null }
}
