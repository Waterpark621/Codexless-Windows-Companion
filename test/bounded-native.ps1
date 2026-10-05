$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\BoundedNative.psm1') -Force
$root=Join-Path $PSScriptRoot ('.fixtures\native-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root|Out-Null
$node=(Get-Command node.exe).Source
$hash=(Get-FileHash -LiteralPath $node -Algorithm SHA256).Hash.ToLowerInvariant()
$script=Join-Path $root 'fixture.mjs'
[IO.File]::WriteAllText($script,@'
const mode=process.argv[2];
if(mode==='args') process.stdout.write(JSON.stringify(process.argv.slice(3)));
if(mode==='env') process.stdout.write(String(process.env.NODE_OPTIONS===undefined));
if(mode==='stdout') process.stdout.write('x'.repeat(200000));
if(mode==='stderr') process.stderr.write('fixture-private-value'.repeat(10000));
if(mode==='exit'){process.stderr.write('fixture-private-value');process.exitCode=7;}
if(mode==='timeout') setTimeout(()=>process.exit(0),1800);
'@,[Text.UTF8Encoding]::new($false))
$passed=0
function Assert([bool]$v){if(!$v){throw 'assertion failed'}}
function Test([string]$n,[scriptblock]$b){& $b;$script:passed++;Write-Output "PASS $n"}
function Run([string]$Mode,[int]$Timeout=5000){Invoke-BoundedNative $node $hash @($script,$Mode) $root -TimeoutMs $Timeout -OutputLimit 1024}
Test 'Wrong executable hash refuses before process start' {$r=Invoke-BoundedNative $node ('0'*64) @($script,'env') $root;Assert (!$r.Ok -and $r.ProcessId -eq 0 -and $r.Code -ceq 'NATIVE_EXECUTABLE_MISMATCH')}
Test 'Windows argv preserves quotes backslashes spaces and shell metacharacters' {$values=@('with space','quote"here','trailing\','& literal | >','');$r=Invoke-BoundedNative $node $hash (@($script,'args')+$values) $root;Assert $r.Ok;$got=ConvertFrom-Json -InputObject $r.Stdout;Assert ($got.Count -eq $values.Count);for($i=0;$i-lt $values.Count;$i++){Assert ($got[$i] -ceq $values[$i])}}
Test 'Child NODE_OPTIONS is absent and caller state is retained' {$saved=$env:NODE_OPTIONS;try{$env:NODE_OPTIONS='--trace-warnings';$r=Run env;Assert ($r.Ok -and $r.Stdout -ceq 'true');Assert ($env:NODE_OPTIONS -ceq '--trace-warnings')}finally{if($null-eq $saved){Remove-Item Env:NODE_OPTIONS -ErrorAction SilentlyContinue}else{$env:NODE_OPTIONS=$saved}}}
foreach($mode in @('stdout','stderr')){Test "Bounded $mode overflow returns no raw output" {$r=Run $mode;Assert (!$r.Ok -and $r.OutputOverflow -and !$r.Stdout -and $r.Code -ceq 'NATIVE_OUTPUT_LIMIT')}}
Test 'Nonzero exit is sanitized and preserves exit code' {$r=Run exit;Assert (!$r.Ok -and $r.ExitCode -eq 7 -and !$r.Stdout -and $r.Code -ceq 'NATIVE_EXIT_FAILED')}
Test 'Timeout returns bounded indeterminate lifetime without force termination' {$clock=[Diagnostics.Stopwatch]::StartNew();$r=Run timeout 200;Assert ($r.TimedOut -and !$r.Ok -and $r.LifetimeMayRemain -and $r.ProcessId -gt 0 -and $r.CreatedAt -and !$r.Stdout);Assert ($clock.ElapsedMilliseconds -lt 1500);Start-Sleep -Milliseconds 1900;Assert ($null -eq (Get-Process -Id $r.ProcessId -ErrorAction SilentlyContinue))}
Test 'Control characters are rejected before child start' {$r=Invoke-BoundedNative $node $hash @("bad`nargument") $root;Assert (!$r.Ok -and $r.ProcessId -eq 0)}
Write-Output ("RESULT: {0}/{0} PASS; benign disposable Node children; no tunnel/task/production operations" -f $passed)
