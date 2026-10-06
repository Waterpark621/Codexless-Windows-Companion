# Codexless Windows Companion

A Windows companion for installing, running and supervising Codexless with automatic startup, recovery, Browser support, health checks and optional OpenAI tunnels.

**Preview — locally qualified; external clean-machine validation pending.**

## Quick Install

1. Download the Companion Preview ZIP from [Releases](https://github.com/Waterpark621/Codexless-Windows-Companion/releases).
2. Compare its SHA-256 with the release notes, then extract it into a new folder. Use the attached ZIP, not GitHub's source-code archive.
3. In that extracted folder, start **Windows PowerShell 5.1** with `powershell.exe -NoProfile -ExecutionPolicy Bypass`. This sets script policy only for that session; enforced Windows security policy must still permit installation. Copy the **payload tree SHA-256** from the same release notes into `$trustedPayload` below. It is different from the ZIP checksum.
4. Select an existing local project directory and run:

```powershell
$trustedPayload = '<payload-tree-sha256-from-release-notes>'
$project = Read-Host 'Existing local project directory'
./Install.ps1 -ProjectPath $project -TrustedPayloadSha256 $trustedPayload -NoTunnel
```

The installer downloads and verifies the pinned Codexless distribution and Node runtime, creates destination-local settings, registers a least-privilege per-user startup task, starts the household and requires Doctor **PASS**. Installation defaults to zero tunnels. Success returns JSON with `state: installed`, `verified: true` and `doctorVerdict: PASS`; errors are visible and an incomplete transaction remains fenced for verified recovery.

## Requirements

- Windows x64, an ordinary interactive user and Windows PowerShell 5.1. Startup runs when that user is logged in; this is not an always-on Windows service.
- Windows security policy must permit the per-user Scheduled Task and qualified executables.
- An existing local project folder, separate from the extracted ZIP and install destination. Reparse traversal, UNC paths, drive roots and overlapping directories are refused.
- HTTPS access to GitHub release assets, nodejs.org and the npm registry. Node **24.12.0** is pinned and verified; a PATH version is not sufficient.
- A supported, connected Codexless Browser backend on the destination computer. Doctor fails visibly if it is missing; the Companion does not copy Browser state or Codex credentials from another machine.

The default destination is `Join-Path $env:LOCALAPPDATA 'CodexlessCompanion'`, with port **7690**. Use `-InstallDirectory` and `-Port` for a separate destination and available port. Do not install over an existing unrelated Codexless household. See [Public installer](docs/PUBLIC-INSTALL.md) for the full contract.

## Verifying with Doctor

After installation, resolve the current immutable generation from its receipt:

```powershell
$root = Join-Path $env:LOCALAPPDATA 'CodexlessCompanion'
$owner = Get-Content (Join-Path $root 'install-owner.json') -Raw | ConvertFrom-Json
if ($owner.generationId -cnotmatch '^[0-9a-f]{32}$') { throw 'Invalid generation' }
$generation = Join-Path (Join-Path $root 'generations') $owner.generationId
& (Join-Path $generation 'Doctor.ps1') -InstallDirectory $root -Json
```

Use your selected destination for `$root` if you changed it. Doctor must return `ok: true` and `verdict: PASS`. It verifies release identity, exact task/owner/listener evidence, Browser connectivity and any enabled tunnel. A disabled tunnel is a nonblocking skip.

## Start / Stop / Restart / Status

Using `$root` and `$generation` above:

```powershell
& (Join-Path $generation 'Status.ps1') -InstallDirectory $root
& (Join-Path $generation 'Stop.ps1') -InstallDirectory $root
& (Join-Path $generation 'Start.ps1') -InstallDirectory $root
& (Join-Path $generation 'Restart.ps1') -InstallDirectory $root
```

Stop is cooperative and verifies exact owned processes. Repeated Start does not create a second owner. Re-resolve `$generation` after an update or rollback.

## Optional tunnel setup

For a fresh install with **one existing OpenAI tunnel**, replace `-NoTunnel` with:

```powershell
./Install.ps1 -ProjectPath $project -TrustedPayloadSha256 $trustedPayload `
    -TunnelId 'tunnel_REPLACE_ME' -TunnelAlias 'default'
```

The installer prompts for that tunnel's **runtime API key** securely. It verifies official tunnel-client **0.0.14** and stores the key on this PC using current-user Windows DPAPI. Never enter an admin key. The Companion does not create or delete remote tunnel objects. To add a tunnel after installation, use Advanced management.

## Advanced multiple tunnels

Each profile has its own local identity, tunnel binding, DPAPI key revision and exact ownership/lifetime evidence. Stop the household before editing:

```powershell
& (Join-Path $generation 'Stop.ps1') -InstallDirectory $root
& (Join-Path $generation 'Tunnels.ps1') -Root $root -Action List
& (Join-Path $generation 'Tunnels.ps1') -Root $root -Action Status
```

Add, Remove and RotateKey are supported through the same installed controller. Add requires the exact qualified tunnel-client executable and prompts securely for the new profile's runtime key. Remove changes local management only; it does not delete the remote tunnel. See [Advanced profile commands](docs/MULTI-TUNNEL-PROFILES.md) for exact parameters, limits and restart instructions. Household Start starts enabled profiles; Stop acts only on exact owned configured tunnels. Credentials are never transferred between machines.

## Updating / rollback

This Preview includes the qualified install/update/rollback transaction engine. It does not include an `Update.ps1` command or a one-click public update flow. Future candidates must have externally accepted payload digests and verified Core distributions before the existing `Invoke-OwnedUpdate` interface can promote them. Do not overwrite generation files or change settings by hand. Failed candidate updates must prove exit and verify the retained previous generation before reporting rollback. See [Transaction contract](docs/INSTALL-TRANSACTIONS.md).

## Uninstall

The existing verified uninstall interface preserves unknown project/root data and removes only exact unchanged owned files and the exact task. It requires the trusted payload digest of the **currently installed release**, taken from its release notes:

```powershell
Import-Module (Join-Path $generation 'CompanionRuntime.psm1') -Force
Import-Module (Join-Path $generation 'NativeTransactionAdapter.psm1') -Force
Import-Module (Join-Path $generation 'InstallTransaction.psm1') -Force
$cfg = Get-CompanionConfig $root
$adapter = New-NativeTransactionAdapter -Root $root -ProjectPath $cfg.projectPath `
    -CodexlessRoot $cfg.codexlessRoot -NodeExe $cfg.nodeExe -Port $cfg.port `
    -TrustedPayloadSha256 @($trustedPayload)
Invoke-OwnedUninstall -Root $root -Adapter $adapter
```

A verified uninstall tombstone permits reinstall. Runtime dependency staging remains beside the destination because settings reference it; uninstall does not authorize deleting unrelated directories. There is no `Uninstall.ps1` script in this Preview.

## Troubleshooting

- **Payload provenance failure:** verify the attached ZIP checksum, extract into an empty folder and use its release-note payload tree digest. Extra or edited files are refused. Do not compute a replacement expected digest from the failing folder.
- **Doctor Browser failure:** connect a supported destination Browser backend and rerun Doctor. Missing connectivity is not accepted as success.
- **Foreign task, listener or owner:** stop and investigate that existing installation through its own supported controller. Companion will not adopt or terminate ambiguous processes.
- **Interrupted install:** keep its evidence. Resume with the same extracted payload, project, port and trusted digest using `./Install.ps1 -Recover -ProjectPath $project -TrustedPayloadSha256 $trustedPayload`. Use the original `-InstallDirectory` if customized. Recovery refuses changed settings or unprovable authority; do not delete receipts to bypass it.
- **Tunnel failure:** check that profile's status and runtime credential. RotateKey changes only the selected profile; never copy DPAPI blobs between users.

## Preview status

The local deterministic, integration and disposable Windows native gates cover installer success/refusal, lifecycle, DPAPI, prior-boot recovery, update rollback, Doctor and independent tunnel profiles. Local native tests isolate task authority and Browser backend; they do not claim live remote credential acceptance.

Clean second-user/machine field validation and live credentialed three-tunnel acceptance remain **pending**. Production installations and credentials are outside these tests.

## Technical / security docs

- [Public installer and recovery](docs/PUBLIC-INSTALL.md)
- [Architecture](docs/ARCHITECTURE.md) and [generation identity](docs/GENERATION-CONTRACT.md)
- [Artifact provenance](docs/ARTIFACT-PROVENANCE.md) and [transaction fences / rollback](docs/INSTALL-TRANSACTIONS.md)
- [Tunnel lifetime](docs/TUNNEL-LIFECYCLE.md) and [Advanced profiles](docs/MULTI-TUNNEL-PROFILES.md)
- [Privacy](docs/PRIVACY.md) and [portability checklist](docs/PORTABILITY-CHECKLIST.md)

The pinned Core is `Waterpark621/Codexless` **0.1.2-preview.1**. Release identity and every manifest-controlled file are verified. The Companion stores destination-local runtime keys with DPAPI, persists no admin key, rejects PID reuse as ownership, and fails closed on foreign or ambiguous task/process state. See the release notes and artifact policy for exact hashes and build/source identity.
