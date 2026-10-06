# Generation contract

Each new task-owner receipt contains `generationContract: {version: 1, sha256: ...}`. The digest binds the exact qualified Codexless tuple, settings bytes, selected project/release/Node paths, port, release-derived launch command, tunnel registration/configuration and credential path, and the shipped Companion scripts. Private values are serialized only in memory; the contract persists only its version and SHA-256 digest. It is a consistency binding, not a signature against the same Windows account modifying its own files.

Prior-boot recovery checks the contract before any retirement, on repeated evidence observations, and against a freshly verified configuration before mutation. Runtime owner verification and Host supervision also require the same contract. Exact existing command, lifetime, SID, task, listener and tunnel checks remain mandatory.

Receipts lacking this contract are fenced. There is no automatic migration or retrospective certification of legacy evidence. Changed settings, release, project or Companion scripts require cooperative stop under the unchanged original configuration before replacing a generation; an ambiguous retained generation requires verified manual recovery. This does not provide an update transaction or make the preview installable.

Raw secret contents and Browser state are excluded. Each active profile's stable identity, alias, registration, enabled flag, credential path and encrypted DPAPI file digest participate in the in-memory canonical generation. Credential rotation therefore changes the generation digest without serializing a plaintext key. Rotation does not gain ownership authority; exact process lifetimes and receipts still govern ownership. Destination-local receipts are never publication material.

Advanced profile edits require a clean cooperative stop and the existing verified transaction controller. A settings/credential change outside that path keeps retained evidence fenced. See [Multi-tunnel profiles](MULTI-TUNNEL-PROFILES.md).
