param([Parameter(Mandatory=$true)][string]$LauncherDirectory,[Parameter(Mandatory=$true)][string]$VerifiedWrapper)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1') -Force
# Launcher-only shim for this reviewed installation. Do not bypass an unknown wrapper/shim.
if((Get-FileHash -LiteralPath $VerifiedWrapper).Hash -cne '9073366C8180E6408D87D132D57F92D3E77115C2578E570F738E97E48D5F1214'){throw 'HOUSEHOLD_VERIFIED_WRAPPER_UNKNOWN'}
$binding=Get-Content -LiteralPath (Join-Path $LauncherDirectory 'verified-codex-runtime.json') -Raw | ConvertFrom-Json
if((Get-FileHash -LiteralPath $binding.launcher).Hash -cne 'E87800C1AF3EB9E695BF978B3C358906EA64E5516E9F0392348EB936C41F28E7'){throw 'HOUSEHOLD_BATCH_SHIM_UNKNOWN'}
foreach($entry in $binding.hashes.PSObject.Properties){
 $binary=Join-Path $binding.binaryRoot $entry.Name
 if((Get-FileHash -LiteralPath $binary).Hash -ine $entry.Value){throw 'HOUSEHOLD_PINNED_BINARY_CHANGED'}
 if((Get-AuthenticodeSignature -LiteralPath $binary).Status -ne 'Valid'){throw 'HOUSEHOLD_PINNED_SIGNATURE_INVALID'}
}
$env:CODEX_BIN=Join-Path $binding.binaryRoot 'codex.exe'
$env:CODEXLESS_BROWSER_SNAPSHOT_STORE=Join-Path $LauncherDirectory 'runtimes\browser-snapshots\v1'
# The reviewed batch shim only runs `node ../scripts/launch.mjs http`. Calling that
# same maintained entrypoint avoids CMD's interrupted-batch shutdown hang.
$entrypoint=Join-Path (Split-Path (Split-Path $binding.launcher)) 'scripts\launch.mjs'
$node=(Get-Command node.exe -ErrorAction Stop).Source
& $node $entrypoint http
exit $LASTEXITCODE
