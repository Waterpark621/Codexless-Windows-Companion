# Portability checklist

## Completed baseline work

- [x] Fresh public Git history; no machine-bound ancestor commits.
- [x] Current validated prior-boot recovery source imported.
- [x] Generated test/recovery state excluded from Git.
- [x] Public-tree privacy scanner added.
- [x] No shipped credential/key material.
- [x] No copied Browser snapshot/cache.

## Required before friend install

- [ ] Replace the external Core.ps1 / Host.ps1 exact-hash adapter.
- [ ] Remove AST-derived legacy working-directory authority.
- [ ] Replace verified-codex-runtime.json / pinned local binary binding with the Codexless fork lifecycle contract.
- [ ] Define an explicit versioned Companion settings schema.
- [ ] Implement destination-machine discovery for install path, current SID, project/context path, endpoint and tunnel executable.
- [ ] Implement local tunnel credential setup without copying credentials from another PC.
- [ ] Add install / uninstall / repair commands with one rollback generation.
- [ ] Add a Doctor command that checks owner, listener, tunnel and Browser readiness.
- [ ] Add update transaction: detect -> stage -> verify -> stop -> promote -> restart -> rollback on failure.
- [ ] Qualify one tagged Codexless fork release and one tunnel-client generation.
- [ ] Test clean installation under a different Windows user/path.
- [ ] Test duplicate Start, Stop -> Start, Desktop close/reopen, and full Windows reboot recovery.
- [ ] Run privacy scan and archive-content scan before GitHub release.

## Deferred from v0

- multiple tunnel aliases;
- generic Windows service/daemon framework;
- arbitrary Browser/Computer Use fallbacks;
- macOS/Linux;
- copying Browser/native-host caches;
- automatic repair of ambiguous same-boot orphan trees.
