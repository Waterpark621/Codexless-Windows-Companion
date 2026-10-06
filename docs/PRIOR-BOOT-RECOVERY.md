# Verified prior-boot recovery

The Companion distinguishes previous-Windows-boot stale ownership from ambiguous same-boot failures.

## Rule

A new task owner may retire retained ownership evidence only when all of the following are proven:

1. the current Windows boot time is available and stable;
2. the retained owner generation predates that boot;
3. receipt identity matches the current destination user, task, Companion directory, release-derived Codexless launch command, and configured tunnel registration;
4. the configured Codexless listener is absent;
5. configured tunnel status proves no live competing runtime;
6. each recorded PID is absent or belongs to a demonstrably current-boot foreign lifetime, and no relevant competing owner process is present;
7. no legacy Codexless Run owner is present;
8. settings and evidence bytes remain unchanged across repeated observations.

The proof is repeated immediately before retirement. The task owner must already be inside the existing Scheduler ancestry and singleton-owner gate.

If any observation is missing, malformed, changed, same-boot, or ambiguous, recovery remains fenced.

A numeric PID collision alone is not ownership. All receipts must independently pass the prior-boot generation proof first. A reused process must have a typed, specified creation time strictly after the stable boot boundary and no later than the observation time. Duplicate PID observations, Companion-looking names, configured executable paths, relevant commands, and listener conflicts refuse recovery. Protected unrelated processes may omit owner/path/command metadata; recovery never asks for their owner SID, opens a process handle, signals them, or adopts them. Current ownership validation is unchanged.

The exact `Win32_OperatingSystem` query retains its ten-second operation timeout. Only `HRESULT 0x40004,Microsoft.Management.Infrastructure.CimCmdlets.GetCimInstanceCommand` is retried, with at most three attempts and 500 ms between attempts. Partial failed observations are discarded. Exhaustion, other errors, untyped/ambiguous boot values, and a changed final boot observation retain the fence and receipts. No process query or mutation is retried.

Official tunnel-client `started_at` is whole-second metadata publication after readiness, possibly refreshed by Connect reuse. It is not the native process creation time. Recovery requires publication strictly before boot and no earlier than the receipt's creation second (`published + 1 second > created`). Exact receipt/native creation consistency, connect interval, executable digest, registration, generation, and namespace proof remain independent requirements. A stale running projection is accepted only with matching prior-boot metadata and a separately proven current-boot foreign PID lifetime.

## Portable binding

Recovery reads settings.json through CompanionRuntime.psm1. It does not import a machine-specific external launcher script or trust a copied executable hash.

The expected private-console receipt is reconstructed from the selected Codexless release's manifest-verified scripts/launch.mjs entrypoint, selected Node executable, and configured loopback port.

Unlike the older production launcher, Companion isolates tunnel-client state by the owner receipt's generation, PID, creation time, and SID. Recovery validates stale metadata against that exact namespace, profile, command, registration and target. Normal startup publishes a new owner and derives a fresh namespace. The old ledger is inert and remains byte-identical; no shared default ledger reset or installation-specific state-root/hash rule is needed. Retirement stays inside the existing resource mutation lease and Scheduler/owner gates.

Status catches only `PROCESS_OWNER_UNAVAILABLE` at its observation boundary. It returns `observationComplete=false`, unverified ownership/pieces, `cleanupRequired=true`, and a degraded reason. Unobserved presence fields are null. Only a complete read-only prior-boot proof, with the task not Running, may project absence and expose `priorBootRecoveryAvailable`; the controller repeats that proof and Task-Host repeats recovery under its existing gate. Missing owner metadata alone never authorizes startup or shutdown. Status changes no receipts or process state.

## Safety properties

- missing PID alone is never recovery authority;
- no process is force-killed or adopted;
- recovery never runs tunnel connect/stop commands;
- current-boot ambiguous evidence is never auto-cleared;
- retirement uses exact validated receipt paths only;
- interruption during retirement writes a current-boot fence that requires explicit recovery;
- diagnostic output is bounded and excludes command lines, credentials, keys, and raw settings.
