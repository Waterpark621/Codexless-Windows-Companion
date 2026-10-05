# Generation contract

Each new task-owner receipt contains `generationContract: {version: 1, sha256: ...}`. The digest binds the exact qualified Codexless tuple, settings bytes, selected project/release/Node paths, port, release-derived launch command, tunnel registration/configuration and credential path, and the shipped Companion scripts. Private values are serialized only in memory; the contract persists only its version and SHA-256 digest. It is a consistency binding, not a signature against the same Windows account modifying its own files.

Prior-boot recovery checks the contract before any retirement, on repeated evidence observations, and against a freshly verified configuration before mutation. Runtime owner verification and Host supervision also require the same contract. Exact existing command, lifetime, SID, task, listener and tunnel checks remain mandatory.

Receipts lacking this contract are fenced. There is no automatic migration or retrospective certification of legacy evidence. Changed settings, release, project or Companion scripts require cooperative stop under the unchanged original configuration before replacing a generation; an ambiguous retained generation requires verified manual recovery. This does not provide an update transaction or make the preview installable.

Secret contents and Browser state are excluded. Credential rotation does not gain ownership authority; tunnel identity, key location, exact process lifetime and existing receipts still govern ownership. Destination-local receipts are never publication material.
