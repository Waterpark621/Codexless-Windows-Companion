# Public install entrypoint

Use Windows PowerShell 5.1, a normal interactive Windows x64 user, and the extracted authenticated Companion release ZIP. Administrator credentials and admin API keys are not part of this flow. Windows security policy must permit the existing least-privilege per-user Scheduled Task and qualified runtime. Doctor requires a supported connected Browser backend; it never treats a missing backend as success.

The published policy pins the supported Codexless 0.1.2-preview.1 Windows x64 release ZIP, filename and SHA-256. Frozen manifest/build/source identity is independently bound. The installer still refuses unpublished or incomplete metadata, including when an offline archive is supplied. It never uses upstream HEAD or a GitHub source archive.

Copy the externally trusted **payload tree SHA-256** from the authenticated Companion release notes. This differs from the ZIP SHA-256: the ZIP checksum validates the downloaded ZIP, and the payload tree digest validates every extracted Companion file before and after staging. Do not compute an expected digest from an untrusted extraction and feed it back as authority. Extra/missing/modified extracted files fail verification.

```powershell
$trustedPayload = '<payload-tree-sha256-from-authenticated-release-notes>'
./Install.ps1 -ProjectPath 'C:/Projects/Example' -TrustedPayloadSha256 $trustedPayload -NoTunnel
```

The destination defaults to `(Join-Path $env:LOCALAPPDATA 'CodexlessCompanion')`. An existing parent and disjoint fully qualified local project/install/payload roots are required; UNC, drive roots, overlaps and reparse traversal are refused. `-InstallDirectory` and `-Port` accept destination-local choices. `-NodeExe` may select only the exact pinned Node executable; the verified official Node archive still supplies npm. `-CodexlessArchivePath` supplies an offline archive with the exact published hash and release identity. `-CodexlessRoot` remains an input only for the non-mutating `-PlanOnly` planner.

With no tunnel inputs, installation uses zero tunnels. For one existing remote tunnel:

```powershell
$key = Read-Host 'Runtime API key' -AsSecureString
try {
  ./Install.ps1 -ProjectPath 'C:/Projects/Example' -TrustedPayloadSha256 $trustedPayload `
    -TunnelId 'tunnel_example' -TunnelAlias 'default' -TunnelRuntimeKey $key
} finally { $key.Dispose(); $key = $null }
```

Omitting `-TunnelRuntimeKey` with a configured tunnel prompts securely. The official client is downloaded/verified unless the exact pinned executable is selected with `-TunnelClientExe`. Only a runtime key belongs here; remote tunnel creation/deletion and admin keys are out of scope. Multiple profiles use the existing [Advanced management](MULTI-TUNNEL-PROFILES.md) after install. Never copy DPAPI state between users/machines.

The flow holds the existing mutation lease around staging and the existing fenced native transaction. Codexless is extracted through the exact distribution verifier. Locked production dependencies are provisioned using npm from the verified Node archive with lifecycle scripts disabled and inherited `NODE_OPTIONS` removed. The native adapter creates settings/DPAPI state after the fence, creates the exact immutable-generation task, starts that owner, and verifies readiness. Doctor must then return `PASS` before an installed success receipt is finalized. CLI success is sanitized JSON; failures are visible errors, never false success.

Installation failures before destination mutation leave no installed owner. A failure after fencing retains exact interrupted-install evidence and refuses ordinary reinstall; it does not blindly delete state or stop ambiguous processes. Resume the same extracted payload and settings with `Install.ps1 -Recover -ProjectPath ... -TrustedPayloadSha256 ...`, preserving the original port/Node choice. Recovery uses existing destination-local credentials, does not rotate a supplied key, and refuses unprovable task/state authority. The existing transaction engine governs repair, uninstall/reinstall and update rollback. Failed candidate updates must prove exit and verify the prior generation before reporting rollback.

Dependency staging is retained in a sibling `.companion-dependencies-<generation>` directory because destination settings reference that verified runtime. Do not delete it while installed. Failed staging is not an installed household and is not automatically removed by an unverified recursive cleanup.

Scripts live in the immutable generation; state lives in the destination root. Resolve the installed generation from its receipt before invoking supported lifecycle/Doctor commands:

```powershell
$root = Join-Path $env:LOCALAPPDATA 'CodexlessCompanion'
$owner = Get-Content (Join-Path $root 'install-owner.json') -Raw | ConvertFrom-Json
if ($owner.generationId -cnotmatch '^[0-9a-f]{32}$') { throw 'Invalid generation' }
$generation = Join-Path (Join-Path $root 'generations') $owner.generationId
& (Join-Path $generation 'Status.ps1') -InstallDirectory $root
& (Join-Path $generation 'Stop.ps1') -InstallDirectory $root
& (Join-Path $generation 'Start.ps1') -InstallDirectory $root
& (Join-Path $generation 'Restart.ps1') -InstallDirectory $root
& (Join-Path $generation 'Doctor.ps1') -InstallDirectory $root -Json
```

The restricted GUID task-name parameter on lifecycle/Doctor scripts exists only for the existing isolated native acceptance namespace. The public installer exposes no policy, adapter, task-name or verifier override. Default installation uses the existing per-user task identity and fail-closed checks.


## Simple CMD launchers

The seven CMD files invoke only Windows PowerShell 5.1 and Launcher.ps1. The UI does not replace installation, ownership, recovery or tunnel engines. It calls the selected directory the **Codexless workspace folder** and passes it unchanged as the existing `ProjectPath` parameter to Install.ps1. It supplies the optional tunnel ID and delegates runtime-key entry to the existing SecureString prompt. CMD files never carry credentials or runtime configuration.

INSTALL resolves the externally expected payload tree digest from the HTTPS GitHub release notes for the exact VERSION tag in Waterpark621/Codexless-Windows-Companion. It refuses unpublished/draft releases, moving commit identities, missing/duplicate digests, wrong asset identity and altered extracted payloads. It never computes its own expected authority from the local files. The bounded request uses no credentials/cookies or redirects. Every publication must bind its exact version, attached ZIP and existing release-note payload-digest field; an edited local payload is not interchangeable with the published ZIP.

Daily controls resolve the installed generation using the existing destination-owned receipt and Get-OwnedInstall/native authority verification, including payload/provenance and exact task identity. They use the same receipt trust already used by installed Tunnels.ps1 and do not require an online release-note fetch. An incomplete, changed, foreign or ambiguous installation remains refused. They do not fall back to an arbitrary source script or legacy host.

TUNNELS uses the installed Tunnels.ps1 List/Add/Remove/RotateKey/Status interfaces. Profile edits retain the existing stopped-only contract; STOP.cmd and START.cmd remain explicit user actions. A chosen local name is passed as the stable profile ID and alias. The first Add reuses existing Save-QualifiedArtifact/Expand-QualifiedArtifact staging for the official pinned client; existing clients use their canonical configured path. Secure key entry/DPAPI, profile transactions and lifetime checks remain in the backend.

Launcher.ps1 accepts -InstallDirectory for a custom installed destination and -NoPause for automation. These parameters are not exposed by the fixed double-click CMD calls. Backend errors and nonzero Doctor verdicts are preserved; interactive windows pause for their results. No installer policy, adapter, verifier or task-name override is exposed.

## Manual PowerShell reference

The following reference retains the previous manual commands for advanced use. Ordinary use is documented through the CMD files in README.md.

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

## Changing workspace after installation

There is no qualified in-place `ProjectPath` reconfiguration command and no `CHANGE-WORKSPACE.cmd`. The native adapter binds the workspace path to the verified settings/owner state; update and repair retain that binding. The stopped-only profile transaction changes tunnel profiles, not the workspace. Do not hand-edit settings, immutable generation files or receipts.

Use the existing verified uninstall/reinstall contract:

1. Run `STOP.cmd` from the extracted release folder for the current installation.
2. Resolve the current installed generation as shown above, use the trusted payload digest from that installed release's notes, and run the **Uninstall** block above. Keep its adapter bound to `$cfg.projectPath`, the original workspace. Require `state: uninstalled` and `verified: true`; an incomplete or ambiguous uninstall must be recovered through the existing verified path before proceeding.
3. Reinstall from an intact verified release ZIP using `INSTALL.cmd`, choosing the new existing workspace. For a custom destination, use the manual install reference with the same `-InstallDirectory` and the new `-ProjectPath`; retain the original port choice if customized. The verified uninstall tombstone allows this reinstall into the retained destination.
4. Configure optional tunnel profiles through the normal install/Advanced flow with destination-local runtime keys, then run `DOCTOR.cmd` and require PASS.

Verified uninstall preserves workspace/project data and unknown root data. It removes only unchanged owned payload/state/credential files and the exact owned task. Reinstall creates fresh verified settings/ownership and fresh destination-local DPAPI state when a tunnel is configured. Do not copy or hand-edit the retired settings or credential files, and do not delete receipts or dependency directories to bypass a refusal.

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
