$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\PriorBootOwnership.psm1') -Force
$module=Get-Module PriorBootOwnership
$passed=0
function Assert([bool]$Value){if(!$Value){throw 'assertion failed'}}
function Test([string]$Name,[scriptblock]$Body){& $Body;$script:passed++;Write-Output "PASS $Name"}
function New-Fixture {
    & $module {
        $task=[pscustomobject]@{Result='{"alias":"fixture","tunnel_id":"fixture-id","process_running":false}';Complete=$true}
        $task | Add-Member ScriptMethod Wait {param($milliseconds) if($milliseconds -ne 1000){throw 'unbounded read wait'};$this.Complete}
        $output=[pscustomobject]@{Pending=$task}
        $output | Add-Member ScriptMethod ReadToEndAsync {$this.Pending}
        $script:native=[pscustomobject]@{StartInfo=$null;StandardOutput=$output;StandardError=$output;StartOk=$true;Exited=$true;ExitCode=0;Disposed=$false}
        $script:native | Add-Member ScriptMethod Start {$this.StartOk}
        $script:native | Add-Member ScriptMethod WaitForExit {param($milliseconds) if($milliseconds -ne 5000){throw 'unbounded process wait'};$this.Exited}
        $script:native | Add-Member ScriptMethod Dispose {$this.Disposed=$true}
        function script:New-Object {
            param($TypeName)
            if($TypeName -ceq 'Diagnostics.Process'){return $script:native}
            if($TypeName -ceq 'Diagnostics.ProcessStartInfo'){return Microsoft.PowerShell.Utility\New-Object Diagnostics.ProcessStartInfo}
            throw 'unexpected construction'
        }
    }
}
function Probe { & $module {Get-RecoveryTunnelStatus ([pscustomobject]@{tunnelExe='C:\fixture\tunnel-client.exe'}) ([pscustomobject]@{alias='fixture'})} }
function Refuses {
    $caught=$false;try{Probe | Out-Null}catch{$caught=$true};Assert $caught
    Assert (& $module {$script:native.Disposed})
}
Test 'Exact read-only status invocation is hidden, redirected, shell-free and bounded' {
    New-Fixture;$status=Probe;Assert (!$status.process_running -and $status.alias -ceq 'fixture')
    Assert (& $module {$s=$script:native.StartInfo;$s.FileName -ceq 'C:\fixture\tunnel-client.exe' -and $s.Arguments -ceq 'runtimes status fixture --json' -and !$s.UseShellExecute -and $s.CreateNoWindow -and $s.RedirectStandardOutput -and $s.RedirectStandardError -and $script:native.Disposed})
}
Test 'Probe start failure refuses' {New-Fixture;& $module {$script:native.StartOk=$false};Refuses}
Test 'Probe timeout refuses without killing the process' {New-Fixture;& $module {$script:native.Exited=$false};Refuses}
Test 'Incomplete pipe read refuses' {New-Fixture;& $module {$script:native.StandardOutput.Pending.Complete=$false};Refuses}
Test 'Nonzero probe exit refuses even with parseable output' {New-Fixture;& $module {$script:native.ExitCode=1};Refuses}
Test 'Oversized status refuses' {New-Fixture;& $module {$script:native.StandardOutput.Pending.Result='x'*65537};Refuses}
Test 'Malformed status JSON refuses' {New-Fixture;& $module {$script:native.StandardOutput.Pending.Result='{'};Refuses}
Write-Output ("RESULT: {0}/{0} PASS; process creation and pipes mocked; no native/tunnel actions" -f $passed)
