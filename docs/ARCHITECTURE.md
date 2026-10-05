# Architecture boundary

## Codexless fork

The Codexless fork owns application behavior and the supported lifecycle contract used by the Companion:

- launch the HTTP MCP server;
- report readiness/health and release identity;
- expose the supported MCP/Browser surface;
- cleanly stop on the documented cooperative shutdown path;
- own Browser dependency qualification.

The fork should remain mergeable with upstream. Windows persistence is not implemented inside Codexless core.

## Windows Companion

The Companion owns Windows session lifecycle:

- one interactive-user, least-privilege Scheduled Task;
- exact owner/process identity receipts;
- duplicate-owner prevention;
- private-console cooperative stop;
- tunnel-client lifetime/status management;
- prior-boot stale-evidence reconciliation;
- one rollback generation;
- install/update transaction fencing.

## Hard safety rules

- Unknown ownership fails closed.
- Missing PID alone never authorizes cleanup.
- Same-boot ambiguous ownership stays fenced.
- Prior-boot evidence may be retired only after boot provenance and current non-occupancy are verified.
- No blind process killing or process adoption.
- Credentials are generated/imported on the destination machine and never shipped in the repository.
- Browser/native-host caches are dependencies, not distributable Companion assets.
