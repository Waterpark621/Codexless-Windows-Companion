# Verified prior-boot recovery

The Companion distinguishes previous-Windows-boot stale ownership from ambiguous same-boot failures.

## Rule

A new task owner may retire retained ownership evidence only when all of the following are proven:

1. the current Windows boot time is available and stable;
2. the retained owner generation predates that boot;
3. receipt identity matches the current destination user, task, Companion directory, release-derived Codexless launch command, and configured tunnel registration;
4. the configured Codexless listener is absent;
5. configured tunnel status proves no live competing runtime;
6. no recorded/reused PID or relevant foreign owner process is present;
7. no legacy Codexless Run owner is present;
8. settings and evidence bytes remain unchanged across repeated observations.

The proof is repeated immediately before retirement. The task owner must already be inside the existing Scheduler ancestry and singleton-owner gate.

If any observation is missing, malformed, changed, same-boot, or ambiguous, recovery remains fenced.

## Portable binding

Recovery reads settings.json through CompanionRuntime.psm1. It does not import a machine-specific external launcher script or trust a copied executable hash.

The expected private-console receipt is reconstructed from the selected Codexless release's manifest-verified scripts/launch.mjs entrypoint, selected Node executable, and configured loopback port.

## Safety properties

- missing PID alone is never recovery authority;
- no process is force-killed or adopted;
- recovery never runs tunnel connect/stop commands;
- current-boot ambiguous evidence is never auto-cleared;
- retirement uses exact validated receipt paths only;
- interruption during retirement writes a current-boot fence that requires explicit recovery;
- diagnostic output is bounded and excludes command lines, credentials, keys, and raw settings.
