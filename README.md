# Codexless Windows Companion

Status: **public installer implemented; exact Codexless distribution publication is still required before friend installation.**

Codexless Windows Companion is a small per-user Windows supervisor for a qualified Codexless release. It provides one verified interactive-session owner, duplicate prevention, cooperative shutdown, tunnel lifecycle, verified prior-boot recovery, rollback boundaries, and health checks.

The Companion is intentionally separate from Codexless core:

- **Codexless fork** owns MCP/runtime/Browser behavior and the lifecycle/release contract.
- **Windows Companion** owns Windows startup, supervision, tunnel lifetime, and recovery.

## Portable runtime contract

The old machine-certified launcher adapter has been removed from this public tree.

The Companion now binds to an explicit destination-machine settings file and a qualified Codexless release:

- settings.json provides the selected project directory, Codexless release root, Node executable/port, and optional local tunnel configuration.
- config/release-manifest.json inside the selected Codexless release supplies product/version/build/source/host-contract identity.
- this preview is pinned to Waterpark621/Codexless 0.1.2-preview.1, build 15a17579c9c78448bbbd9af5a6589b1817dbf2fbae968cea7ff16a2fe4837898, source af80d290a265b414de9792b1b53600180be4c0e2.
- the exact qualified manifest bytes and every manifest-controlled release file are hash-checked before use.
- Codexless starts directly through its supported scripts/launch.mjs http entrypoint after the Companion removes inherited NODE_OPTIONS from the child environment; the qualified Codexless launcher independently rejects non-empty NODE_OPTIONS.
- readiness is checked through /readyz and must match the exact expected version, public surface, build ID, and source revision; readiness containing defaultCwd is rejected.
- settings and selected release build are immutable for one running owner generation; updates stop the owner first.

No external Core.ps1, Host.ps1, AST-derived working directory, copied runtime quartet, or machine-specific Browser snapshot ID is part of this public contract.

## Privacy / distribution boundary

A public release must never contain machine-specific runtime state or personal deployment evidence. Do not commit:

- user profile names or absolute per-user paths;
- real Windows SIDs, PIDs, owner receipts, timestamps, task exports, or recovery dumps;
- real tunnel aliases/account identifiers from a deployment;
- DPAPI blobs, tunnel keys, credentials, tokens, cookies, or browser profile data;
- copied Browser/native-host snapshots or cache directories;
- local rollback archives or machine certification baselines.

Installation identity is generated on the destination PC. Runtime identity safeguards still use the destination user's SID, exact PID creation times, ancestry, listener ownership, and tunnel receipts at runtime.

## Current validated lineage

The owner/recovery mechanisms were brought forward from internally validated source lineage ending at:

37686a932ff0c355d363cd4dc3bbf1a9c3a46dc1

The public tree has a fresh Git history so older machine-specific development history is not publishable by accident.

## Target install experience

The intended supported flow is:

1. verify Windows and prerequisites;
2. install or select one qualified Waterpark621/Codexless release;
3. select the project/context directory;
4. configure tunnel credentials locally on this PC;
5. create one least-privilege per-user Scheduled Task;
6. start and verify Codexless;
7. start and verify the optional tunnel;
8. verify Browser capability when enabled;
9. retain one rollback generation;
10. survive Desktop close/reopen and Windows reboot in the supported logged-in-user model.

`Install.ps1` now stages the exact pinned Codexless distribution and official dependencies, accepts destination-local configuration, and invokes the existing native transaction engine. The simple flow defaults to zero tunnels; supplying a tunnel ID enables one tunnel and prompts for a runtime key as a SecureString. The native adapter writes current-user DPAPI state inside the destination transaction fence. An externally trusted Companion payload tree digest is required; the installer never derives its own trust from the current files. Current `unpublished` distribution metadata still refuses before destination, task, process, or credential mutation. No public archive URL or checksum is invented.

Success requires exact owner/listener readiness followed by Doctor `PASS`, including a supported connected Browser backend. Failure retains the existing interrupted-install fence; `-Recover` resumes only a verified transaction with the same payload/settings binding. Updates retain the existing stop, promote and verified rollback contract. See [Public installer](docs/PUBLIC-INSTALL.md) for commands and publication fields. Different-user/machine and live credentialed tunnel acceptance remain pending external acceptance; they do not disable the implemented entrypoint.

## Development rule

Local engineering includes digest-only owner/recovery generation binding, pinned official Node 24.12.0 Windows x64 and OpenAI tunnel-client v0.0.14 full client archives, bounded managed tunnel lifecycle with native lifetime guards, staged install/repair/uninstall/update/rollback transaction engines, and a real Windows transaction adapter. `NativeTransactionAdapter.psm1` accepts only externally trusted payload tree digests, creates destination-local settings and DPAPI state after the transaction fence exists, and binds the exact immutable generation to a least-privilege per-user Scheduled Task without force termination or foreign-state adoption. Codexless remote distribution binding is implemented but intentionally fail-closed as `unpublished` because the qualified candidate has not been published. The frozen release identity, manifest digest, host contract, archive format, bounds, and payload shape are already bound; publication must supply only `state=published`, the immutable HTTPS archive URL, exact archive filename, and exact archive SHA-256. `Stage-QualifiedCodexlessDistribution` is the download-to-qualified-staged-root integration interface. Install.ps1 wires that interface to the existing native transaction engine. See docs/GENERATION-CONTRACT.md, docs/ARTIFACT-PROVENANCE.md, docs/TUNNEL-LIFECYCLE.md and docs/INSTALL-TRANSACTIONS.md for exact boundaries.

Keep the ownership/security mechanisms; remove machine assumptions.

Before any push or release, run `tools/Test-PublicTree.ps1`, scan the complete Git history with private needles, and inspect the exact release archive contents. Runtime tunnel profiles and Browser/cache directories must never be packaged.

See docs/ARCHITECTURE.md, docs/PORTABILITY-CHECKLIST.md, and docs/PRIVACY.md.

Advanced destination-local multi-tunnel management is described in [Multi-tunnel profiles](docs/MULTI-TUNNEL-PROFILES.md). The simple installer retains its zero-or-one default tunnel flow. Published artifact binding is required; external acceptance remains pending.
