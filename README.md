# Codexless Windows Companion

Status: **non-mutating public-preview preparation. Not ready for friend installation.**

Codexless Windows Companion is a small per-user Windows supervisor for a qualified Codexless release. It provides one verified interactive-session owner, duplicate prevention, cooperative shutdown, tunnel lifecycle, verified prior-boot recovery, rollback boundaries, and health checks.

The Companion is intentionally separate from Codexless core:

- **Codexless fork** owns MCP/runtime/Browser behavior and the lifecycle/release contract.
- **Windows Companion** owns Windows startup, supervision, tunnel lifetime, and recovery.

## Portable runtime contract

The old machine-certified launcher adapter has been removed from this public tree.

The Companion now binds to an explicit destination-machine settings file and a qualified Codexless release:

- settings.json provides the selected project directory, Codexless release root, Node executable/port, and optional local tunnel configuration.
- config/release-manifest.json inside the selected Codexless release supplies product/version/build/host-contract identity.
- critical launch/runtime files are checked against that manifest before use.
- Codexless starts directly through its supported scripts/launch.mjs http entrypoint.
- readiness is checked through /readyz and must match the expected Codexless version and public surface.
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

`Install.ps1` is intentionally **plan-only in this public preview**. `-PlanOnly` validates the proposed destination and selected dependencies; invoking it without `-PlanOnly` fails before any file, task, process, or credential mutation. Automatic tunnel connect is also disabled until exact launch provenance is qualified. The DPAPI credential design remains fixture-tested, but the preview installer does not collect or store a runtime key. `Doctor.ps1` now requires direct listener ancestry, exact tunnel ownership receipts when a tunnel is configured, Codexless `/readyz` release identity, and a read-only `codex.browser_status` MCP probe with at least one supported connected Browser backend. Required checks no longer pass as `PENDING`; Doctor returns `PASS`, `DEGRADED`, or `FAIL`. Qualified release/build binding, repair/update/uninstall, provenance, and clean-machine acceptance remain release gates.

## Development rule

Keep the ownership/security mechanisms; remove machine assumptions.

Before any push or release, run `tools/Test-PublicTree.ps1`, scan the complete Git history with private needles, and inspect the exact release archive contents. Runtime tunnel profiles and Browser/cache directories must never be packaged.

See docs/ARCHITECTURE.md, docs/PORTABILITY-CHECKLIST.md, and docs/PRIVACY.md.
