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

## Required before friend install

- [ ] Implement installer discovery/selection for the qualified Codexless fork release, Node, project path, and tunnel client.
- [ ] Implement local tunnel credential setup without copying credentials from another PC.
- [ ] Add install / uninstall / repair commands with one rollback generation.
- [ ] Add a Doctor command that checks owner, listener, release identity, tunnel, and Browser readiness.
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
