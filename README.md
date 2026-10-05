# Codexless Windows Companion

Status: portability preparation. **Not ready for public installation yet.**

This project is a small per-user Windows supervisor for a qualified Codexless release. Its job is lifecycle reliability: one verified interactive-session owner, duplicate prevention, cooperative shutdown, tunnel lifecycle, reboot recovery, rollback, and health checks.

The Companion is intentionally separate from Codexless core. Codexless owns the MCP/runtime/Browser implementation; the Companion owns Windows startup and supervision.

## Privacy / distribution boundary

A public release must never contain machine-specific runtime state or personal deployment evidence. In particular, do not commit:

- user profile names or absolute per-user paths;
- real Windows SIDs, PIDs, task receipts, timestamps, or recovery dumps;
- tunnel aliases/account identifiers from a real deployment;
- DPAPI blobs, tunnel keys, credentials, tokens, cookies, or browser profile data;
- Browser snapshot/cache directories copied from an installed machine;
- machine certification baselines or local rollback archives.

Installation identity is generated on the destination PC. Runtime identity checks (SID, PID + creation time, process ancestry, listener ownership) remain required; they are discovered dynamically and are not pre-baked into the package.

## Current validated owner source

This sanitized tree is derived from validated household-owner source commit:

37686a932ff0c355d363cd4dc3bbf1a9c3a46dc1

That lineage includes verified prior-boot stale-ownership reconciliation and the nonfunctional PowerShell module-warning cleanup.

The current source still includes a legacy certified-installation adapter (Start-VerifiedHousehold.ps1 and related config assumptions). That adapter is **not portable** and is the next component to replace. Do not use this repository as a friend installer yet.

## Target install experience

The intended supported flow is:

1. verify Windows and required prerequisites;
2. install/select one qualified Codexless release;
3. ask for the project/context directory explicitly;
4. configure tunnel credentials locally on this PC;
5. create one least-privilege per-user Scheduled Task;
6. start and verify the Codexless listener;
7. start and verify the tunnel;
8. verify Browser capability when enabled;
9. retain one rollback generation;
10. survive Desktop close/reopen and Windows reboot within the supported logged-in-user model.

No copied SID, hard-coded user profile, private key, snapshot ID, or local recovery receipt is part of that flow.

## Development rule

Keep the security mechanisms; remove machine assumptions.

See docs/ARCHITECTURE.md, docs/PORTABILITY-CHECKLIST.md, and docs/PRIVACY.md.
