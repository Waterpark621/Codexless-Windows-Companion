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
