Set-StrictMode -Version Latest

if (-not ('Codexless.PrivateConsole' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
namespace Codexless {
    public static class PrivateConsole {
        [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
        struct StartupInfo {
            public int cb; public string reserved, desktop, title;
            public uint x, y, xSize, ySize, xChars, yChars, fill, flags;
            public ushort showWindow, reserved2Size; public IntPtr reserved2, stdin, stdout, stderr;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct ProcessInfo { public IntPtr process, thread; public uint pid, threadId; }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern bool CreateProcess(string application, StringBuilder command, IntPtr processSecurity,
            IntPtr threadSecurity, bool inheritHandles, uint flags, IntPtr environment, string directory,
            ref StartupInfo startup, out ProcessInfo process);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll", SetLastError=true)] public static extern bool AttachConsole(uint pid);
        [DllImport("kernel32.dll", SetLastError=true)] public static extern bool FreeConsole();
        [DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);
        [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GenerateConsoleCtrlEvent(uint signal, uint group);
        [DllImport("kernel32.dll", SetLastError=true)] static extern uint GetConsoleProcessList([Out] uint[] list, uint size);
        public static int Start(string executable, string command, string directory) {
            StartupInfo si = new StartupInfo(); si.cb = Marshal.SizeOf(si);
            si.flags = 1; si.showWindow = 0; // STARTF_USESHOWWINDOW, SW_HIDE
            ProcessInfo pi;
            // CREATE_NEW_CONSOLE only: do not detach from a security job or inherit arbitrary handles.
            if (!CreateProcess(executable, new StringBuilder(command), IntPtr.Zero, IntPtr.Zero,
                false, 0x10, IntPtr.Zero, directory, ref si, out pi))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            try { return checked((int)pi.pid); }
            finally { CloseHandle(pi.thread); CloseHandle(pi.process); }
        }
        public static uint[] Members() {
            uint[] list = new uint[64]; uint count = GetConsoleProcessList(list, (uint)list.Length);
            if (count == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
            if (count > 1024) throw new InvalidOperationException("PRIVATE_CONSOLE_MEMBER_LIMIT");
            if (count > list.Length) { list = new uint[count]; count = GetConsoleProcessList(list, (uint)list.Length); }
            if (count == 0 || count > list.Length) throw new InvalidOperationException("PRIVATE_CONSOLE_CHANGED");
            Array.Resize(ref list, (int)count); return list;
        }
    }
}
'@
}

function Get-ConsoleProcessIdentity {
    param([int]$ProcessId)
    $p = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop
    if ($null -eq $p) { return $null }
    $owner = Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction Stop
    if ($owner.ReturnValue -ne 0) { throw 'PRIVATE_CONSOLE_OWNER_UNAVAILABLE' }
    [pscustomobject]@{ pid=[int]$p.ProcessId; parentPid=[int]$p.ParentProcessId; userSid=$owner.Sid; executable=$p.ExecutablePath; commandLine=$p.CommandLine; createdAt=$p.CreationDate.ToUniversalTime().ToString('o') }
}

function Test-PrivateConsoleReceipt {
    param($Receipt,$Identity,[string]$CurrentUserSid)
    if ($null -eq $Identity -or $null -eq $Receipt) { return $false }
    try {
        $Receipt.version -eq 1 -and $Receipt.pid -eq $Identity.pid -and
        $Receipt.createdAt -ceq $Identity.createdAt -and $Receipt.userSid -ceq $Identity.userSid -and
        $Receipt.userSid -ceq $CurrentUserSid -and $Receipt.executable -ieq $Identity.executable -and
        $Receipt.commandLine -ceq $Identity.commandLine
    } catch { $false }
}

function Test-PrivateConsoleMember {
    param($Root,$Member,[hashtable]$Identities,[int]$HelperPid)
    if ($Member.pid -eq $HelperPid) { return $true }
    $seen = @{}
    $cursor = $Member
    for ($depth=0; $depth -lt 64; $depth++) {
        if ($null -eq $cursor -or $cursor.userSid -cne $Root.userSid -or $cursor.createdAt -clt $Root.createdAt) { return $false }
        if ($cursor.pid -eq $Root.pid) { return $cursor.createdAt -ceq $Root.createdAt }
        if ($seen.ContainsKey($cursor.pid)) { return $false }
        $seen[$cursor.pid] = $true
        $parent = $Identities[$cursor.parentPid]
        if ($null -eq $parent -or $parent.createdAt -cgt $cursor.createdAt) { return $false }
        $cursor = $parent
    }
    $false
}

function Test-PrivateConsoleListener {
    param([string]$ReceiptPath,[int]$Port)
    try {
        $receipt = Get-Content -LiteralPath $ReceiptPath -Raw -ErrorAction Stop | ConvertFrom-Json
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $root = Get-ConsoleProcessIdentity ([int]$receipt.pid)
        if (!(Test-PrivateConsoleReceipt $receipt $root $sid)) { return $false }
        $listeners = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop)
        if ($listeners.Count -eq 0) { return $false }
        $verified = @{}
        foreach ($listener in $listeners) {
            $cursor = Get-ConsoleProcessIdentity ([int]$listener.OwningProcess)
            $member = $cursor
            for ($depth=0; $depth -lt 64 -and $null -ne $cursor; $depth++) {
                $verified[$cursor.pid] = $cursor
                if ($cursor.pid -eq $root.pid) { break }
                $cursor = Get-ConsoleProcessIdentity $cursor.parentPid
            }
            if ($null -eq $member -or !(Test-PrivateConsoleMember $root $member $verified -1)) { return $false }
        }
        # Recheck both listener membership and PID identities before accepting readiness.
        $again = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop)
        $snapshot = @($listeners | ForEach-Object { "$($_.LocalAddress)|$($_.LocalPort)|$($_.OwningProcess)" } | Sort-Object)
        $current = @($again | ForEach-Object { "$($_.LocalAddress)|$($_.LocalPort)|$($_.OwningProcess)" } | Sort-Object)
        if (($snapshot -join ',') -cne ($current -join ',')) { return $false }
        foreach ($listener in $again) {
            $identity = Get-ConsoleProcessIdentity ([int]$listener.OwningProcess)
            $saved = $verified[[int]$listener.OwningProcess]
            if ($null -eq $identity -or $identity.createdAt -cne $saved.createdAt -or $identity.userSid -cne $saved.userSid -or $identity.executable -ine $saved.executable -or $identity.commandLine -cne $saved.commandLine) { return $false }
        }
        Test-PrivateConsoleReceipt $receipt (Get-ConsoleProcessIdentity ([int]$root.pid)) $sid
    } catch { $false }
}

function Write-PrivateConsoleReceipt {
    param([string]$Path,$Receipt,[switch]$Replace)
    $destination = if ($Replace) { "$Path.$PID.$([Guid]::NewGuid().ToString('N')).tmp" } else { $Path }
    $stream = $null
    try {
        # CreateNew makes the initial launch fence exclusive; Flush(true) persists it before spawn.
        $stream = [IO.File]::Open($destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        $bytes = [Text.Encoding]::UTF8.GetBytes(($Receipt | ConvertTo-Json))
        $stream.Write($bytes,0,$bytes.Length)
        $stream.Flush($true)
    } finally { if ($null -ne $stream) { $stream.Dispose() } }
    if ($Replace) {
        # Atomic replacement keeps the pending fence present even if writing or replacement fails.
        [IO.File]::Replace($destination,$Path,[System.Management.Automation.Language.NullString]::Value)
    }
}

function Start-PrivateConsoleNativeProcess {
    param([string]$Executable,[string]$Command,[string]$WorkingDirectory)
    [Codexless.PrivateConsole]::Start($Executable,$Command,$WorkingDirectory)
}

function Start-PrivateConsoleProcess {
    param([string]$Executable,[string]$Arguments,[string]$WorkingDirectory,[string]$ReceiptPath)
    foreach ($path in @($Executable,$WorkingDirectory,$ReceiptPath)) {
        if (![IO.Path]::IsPathRooted($path) -or $path.StartsWith('\\') -or $path.Contains('"') -or $path.Contains("`n") -or $path.Contains("`r")) { throw 'PRIVATE_CONSOLE_PATH_INVALID' }
    }
    if (Test-Path -LiteralPath $ReceiptPath) { throw 'PRIVATE_CONSOLE_RECEIPT_EXISTS: Existing owner must be resolved before starting another child.' }
    $command = '"'+$Executable+'" '+$Arguments
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $pending = [ordered]@{version=0;state='launch-pending';userSid=$sid;executable=$Executable;commandLine=$command;requestedAt=[DateTime]::UtcNow.ToString('o')}
    Write-PrivateConsoleReceipt $ReceiptPath $pending
    # Retain this fence on every failure. A launched child must never reopen duplicate startup.
    $childPid = Start-PrivateConsoleNativeProcess $Executable $command $WorkingDirectory
    $pending.pid = $childPid
    Write-PrivateConsoleReceipt $ReceiptPath $pending -Replace
    $identity = Get-ConsoleProcessIdentity $childPid
    if ($null -eq $identity -or $identity.userSid -cne $sid -or $identity.executable -ine $Executable -or $identity.commandLine -cne $command) { throw 'PRIVATE_CONSOLE_START_IDENTITY_INVALID' }
    $receipt = [ordered]@{version=1;pid=$childPid;createdAt=$identity.createdAt;userSid=$sid;executable=$Executable;commandLine=$command}
    Write-PrivateConsoleReceipt $ReceiptPath $receipt -Replace
    [pscustomobject]$receipt
}

function Request-PrivateConsoleStop {
    param([string]$ReceiptPath,[string]$HelperScript,[int]$TimeoutSeconds=60)
    if (!(Test-Path -LiteralPath $ReceiptPath)) { throw 'PRIVATE_CONSOLE_RECEIPT_MISSING' }
    foreach ($path in @($ReceiptPath,$HelperScript)) {
        if (![IO.Path]::IsPathRooted($path) -or $path.StartsWith('\\') -or $path.Contains('"') -or $path.Contains("`n") -or $path.Contains("`r")) { throw 'PRIVATE_CONSOLE_PATH_INVALID' }
    }
    $helper = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$HelperScript+'" -ReceiptPath "'+$ReceiptPath+'" -TimeoutSeconds '+$TimeoutSeconds) -WindowStyle Hidden -PassThru
    if (!$helper.WaitForExit(($TimeoutSeconds + 10) * 1000)) { throw 'PRIVATE_CONSOLE_HELPER_TIMEOUT: No termination or replacement was attempted.' }
    if ($helper.ExitCode -ne 0) { throw 'PRIVATE_CONSOLE_STOP_FAILED: Inspect helper error; no force termination or replacement was attempted.' }
}

Export-ModuleMember -Function Get-ConsoleProcessIdentity,Test-PrivateConsoleReceipt,Test-PrivateConsoleMember,Test-PrivateConsoleListener,Start-PrivateConsoleProcess,Request-PrivateConsoleStop
