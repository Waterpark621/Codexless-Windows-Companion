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
- [x] `Install.ps1` refuses mutating installation by default with `INSTALL_DISABLED_PUBLIC_PREVIEW`.
- [x] Fully qualified drive paths are required; root-relative, drive-relative and UNC inputs are rejected.
- [x] Existing live tunnel processes require an exact pre-existing Companion ownership receipt; they are never adopted from creation time alone.
- [x] Automatic tunnel connect is disabled pending a positively attributable launch-provenance contract.
- [x] Tunnel-client connect output is suppressed; fixed diagnostics are used instead of persisting raw client/exception text.
- [x] A pre-existing runtime-key environment value is restored after a connect helper call.
- [x] DPAPI destination-local credential storage is fixture-tested, but the preview installer does not collect/store a key.
- [x] Read-only Doctor checks settings, release identity, task/owner state, readiness, and official tunnel status.
- [x] Friendly Start / Stop / Restart / Status development entrypoints exist.
- [x] Doctor directly verifies listener ancestry, exact tunnel ownership receipts, and read-only Browser backend connectivity.

## Required before friend install

- [x] Bind settings + qualified Codexless release/build identity to each owner generation and revalidate it throughout prior-boot recovery.
- [x] Reproduce the qualified Codexless npm production dependency closure from its frozen shrinkwrap and control inherited NODE_OPTIONS.
- [ ] Qualify the distributable Node runtime binary/version and tunnel-client binary/version/provenance.
- [ ] Establish exact tunnel launch provenance before re-enabling automatic `runtimes connect`.
- [ ] Add bounded native tunnel status/connect/stop execution.
- [ ] Add an incomplete-install fence plus ownership-verified repair/uninstall.
- [ ] Add update + rollback transaction: detect -> stage -> verify -> stop -> promote -> restart -> rollback on failure.
- [ ] Add download/provenance flow and archive checksum verification for qualified binaries.
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
