# Portability checklist

## Completed baseline work

- [x] Fresh public Git history; no machine-bound ancestor commits.
- [x] Current validated prior-boot recovery source imported.
- [x] Generated test/recovery state excluded from Git.
- [x] Public-tree privacy scanner added.
- [x] No shipped credential/key material.
- [x] No copied Browser/native-host snapshot/cache.
- [x] Replaced external Core/Host exact-hash adapter.
- [x] Removed AST-derived legacy working-directory authority.
- [x] Removed verified local runtime/binary wrapper binding.
- [x] Added explicit destination-machine settings schema.
- [x] Added release-manifest/host-contract validation.
- [x] Bind Companion to one exact qualified Codexless version/build/source plus exact manifest bytes and every manifest-controlled file hash.
- [x] Launch Codexless directly through scripts/launch.mjs http after removing inherited NODE_OPTIONS.
- [x] Bind readiness to /readyz exact version, public surface, build ID and source revision; reject defaultCwd metadata.
- [x] Preserve same-boot fail-closed and verified prior-boot recovery.

## Public-preview safety gate

- [x] `Install.ps1 -PlanOnly` validates the proposed release, project, Node, port and optional tunnel inputs without mutation.
- [x] `Install.ps1` refuses unpublished or incomplete distribution metadata before mutation; published policy dispatches to the existing transaction engine.
- [x] Fully qualified drive paths are required; root-relative, drive-relative and UNC inputs are rejected.
- [x] Existing live tunnel processes require an exact pre-existing Companion ownership receipt; they are never adopted from creation time alone.
- [x] Automatic tunnel connect requires exact generation and process provenance; foreign or ambiguous processes are never adopted.
- [x] Tunnel-client connect output is suppressed; fixed diagnostics are used instead of persisting raw client/exception text.
- [x] A pre-existing runtime-key environment value is restored after a connect helper call.
- [x] The installer accepts/prompts for a SecureString runtime key and the existing native adapter stores it using destination-local current-user DPAPI.
- [x] Read-only Doctor checks settings, release identity, task/owner state, readiness, and official tunnel status.
- [x] Friendly Start / Stop / Restart / Status development entrypoints exist.
- [x] Doctor directly verifies listener ancestry, exact tunnel ownership receipts, and read-only Browser backend connectivity.

## Required before friend install

- [x] Bind settings + qualified Codexless release/build identity to each owner generation and revalidate it throughout prior-boot recovery.
- [x] Reproduce the qualified Codexless npm production dependency closure from its frozen shrinkwrap and control inherited NODE_OPTIONS.
- [x] Qualify the pinned Node executable and official tunnel-client version/provenance locally.
- [x] Pin the official Node 24.12.0 Windows x64 archive and implement verified, bounded staging with safe ZIP extraction.
- [x] Select and qualify the portable tunnel-client distribution/version/archive checksum.
- [x] Bind the exact published Codexless download artifact, including release identity and archive SHA-256.
- [x] Qualify exact fresh-generation managed tunnel launch, bounded status and guarded official stop.
- [x] Add bounded native tunnel status/connect/stop execution.
- [x] Add internal staged transaction engines, incomplete fences and ownership-verified adapter contracts.
- [x] Add a same-machine disposable acceptance harness with unique roots, ports and task identity plus sanitized machine-readable reporting; this is not different-machine acceptance.
- [x] Wire the real package/task/provenance adapter into isolated native acceptance using the exact qualified published distribution.
- [ ] Publish and bind the exact Codexless archive before distributing the friend installer. External acceptance remains pending separately.
- [x] Add update + rollback transaction: detect -> stage -> verify -> stop -> promote -> restart -> rollback on failure.
- [x] Add download/provenance flow and archive checksum verification for qualified binaries.
- [ ] Test clean installation under a different Windows user and different paths.
- [ ] Test concurrency, interruption, duplicate Start, Stop -> Start, Desktop close/reopen, shutdown and full Windows reboot recovery.
- [ ] Run current-tree, complete-history and release-archive privacy scans before friend distribution.

## Deferred from v0

- multiple tunnel aliases in default UX;
- generic Windows service/daemon framework;
- arbitrary Browser/Computer Use fallbacks;
- macOS/Linux Companion;
- copying Browser/native-host caches;
- automatic repair of ambiguous same-boot orphan trees.
