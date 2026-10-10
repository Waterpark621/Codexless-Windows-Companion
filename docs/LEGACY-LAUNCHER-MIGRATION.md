# Moving from the older launcher

The older machine-specific launcher and the public Companion are separate installations. Updating Codexless core or checking out Companion source does not migrate the existing launcher, startup task or command shortcuts.

Companion defaults to `CodexlessCompanion` under the current user's local application-data directory. The older launcher uses `CodexlessLauncher`. Both can use the same per-user task name and loopback port, so an existing owner must be verified and retired through its own controller before installing the replacement. Companion does not adopt the old task or its ownership receipts.

## Verified migration sequence

1. Prepare the exact published Companion payload and its authenticated ZIP and payload-tree digests. Preserve the selected workspace, loopback port, enabled tunnel registrations and a rollback copy of the older launcher's scripts/configuration. Keep all machine data local.
2. Run the older installation's supported Status and Stop controllers. Require verified ownership before Stop and a completed stopped state afterward: no host, listener, tunnel runtime or degraded cleanup evidence. If shutdown is ambiguous, retain the evidence and resolve it before migration.
3. Export and verify the exact old task definition before retiring that stopped task. Do not remove an unrelated task, delete receipts to manufacture absence, or start a second owner.
4. Install Companion from the published payload using the preserved workspace and port. Require Doctor PASS. Recreate tunnel profiles with runtime keys entered securely on the same destination account; never publish keys or move DPAPI ciphertext between accounts or machines.
5. Verify every enabled profile independently. Exercise duplicate Start, Stop then Start and Restart; require verified ownership, exact release readiness, Browser acceptance and no remaining cleanup requirement.
6. Point daily command shortcuts at Companion's verified Launcher controller. Keep the older scripts and task export available for rollback, but leave the retired old startup owner unregistered.
7. Coordinate a real Windows reboot/login and verify the new task, Browser, listener and every enabled tunnel again. Fixture boot tests are not a substitute for this field check.

If replacement installation fails, do not blindly overwrite its task or clear its fence. Prove the replacement stopped and remove it through the applicable verified recovery/uninstall transaction before restoring the exact old task and restarting the old controller. Preserve both sets of evidence if that proof cannot be completed.

There is no automatic legacy migration command in this Preview. The above sequence describes the required ownership and rollback checks for a reviewed destination-local migration. The public installer remains provenance-gated; modified Preview 4 files are not an installable replacement for a published Preview 5 payload.

## Acceptance still needing an external environment

A successful migration and reboot on the existing account qualifies that deployment only. Clean installation under a different Windows user or on a second machine remains a separate acceptance gate. Use a fresh workspace, the published ZIP and destination-local credentials, then record Doctor, lifecycle and reboot results without exporting personal paths, task XML, Browser state or keys.
