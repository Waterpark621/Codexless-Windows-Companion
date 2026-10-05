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
- [x] Launch Codexless directly through scripts/launch.mjs http.
- [x] Bind readiness to /readyz, release version, and public surface.
- [x] Preserve same-boot fail-closed and verified prior-boot recovery.

## Implemented but not yet clean-machine qualified

- [x] Fresh-install-only installer accepts explicit Codexless release, Node/project path, port, and optional tunnel-client inputs.
- [x] Runtime API key is entered on the destination PC and stored only as current-user Windows DPAPI ciphertext.
- [x] Installer stages and validates its payload before promoting the Companion directory.
- [x] Installer refuses an existing task/non-empty install instead of adopting or overwriting it.
- [x] Read-only Doctor checks settings, release identity, task/owner state, readiness, and official tunnel status.
- [x] Friendly Start / Stop / Restart / Status entrypoints added.
- [ ] Add Browser-backend connectivity probe to Doctor.

## Required before friend install

- [ ] Add download/provenance flow for a qualified Codexless fork release and tunnel-client binary.
- [ ] Add uninstall / repair commands with one rollback generation.
- [ ] Add update transaction: detect -> stage -> verify -> stop -> promote -> restart -> rollback on failure.
- [ ] Qualify one tagged Waterpark621/Codexless release and one tunnel-client generation.
- [ ] Validate archive provenance/checksum before installing a downloaded release.
- [ ] Test clean installation under a different Windows user and different paths.
- [ ] Test duplicate Start, Stop -> Start, Desktop close/reopen, and full Windows reboot recovery.
- [ ] Test interrupted install/update and rollback.
- [ ] Run privacy scan and release-archive content scan before GitHub publication.

## Deferred from v0

- multiple tunnel aliases in default UX;
- generic Windows service/daemon framework;
- arbitrary Browser/Computer Use fallbacks;
- macOS/Linux Companion;
- copying Browser/native-host caches;
- automatic repair of ambiguous same-boot orphan trees.
