# Advanced destination-local tunnel profiles

The simple install plan still describes zero tunnels or one default tunnel. Advanced management extends that default into a collection of up to 64 profiles. It uses the same Scheduled Task, household supervisor, mutation lock, generation contract, per-alias namespaces, official client and exact lifetime receipts.

Run `Tunnels.ps1` from the **current installed generation**, with an explicit destination `-Root`. The public installer uses the existing transaction engine; these Advanced operations require an already verified transactional install. Published artifact binding is required. Clean second-machine acceptance remains pending.

Examples below use a PowerShell variable `$installedGeneration` for the current Companion generation directory and `$destination` for its install root.

```powershell
& "$installedGeneration\Tunnels.ps1" -Root $destination -Action List
& "$installedGeneration\Tunnels.ps1" -Root $destination -Action Status

# Stop cleanly through the installed controller before changing profiles.
# Add prompts securely for this profile's runtime key when RuntimeApiKey is omitted.
& "$installedGeneration\Tunnels.ps1" -Root $destination -Action Add `
    -ProfileId office -Alias office -TunnelId tunnel_REPLACE_ME `
    -TunnelClientExe $qualifiedTunnelClient

& "$installedGeneration\Tunnels.ps1" -Root $destination -Action RotateKey -ProfileId office
& "$installedGeneration\Tunnels.ps1" -Root $destination -Action Remove -ProfileId office
# Start normally through the installed controller after a successful edit.
```

`Add -Disabled` creates a configured profile excluded from startup. List and Status include disabled profiles. Stop and recovery examine all configured profiles. Omitting ProfileId for Add creates a stable local random identity. The default tunnel keeps its alias as its profile identity when first migrated. Removing the default leaves the other profiles unchanged; the simple installer UX remains separate from Advanced management.

Every profile binds a unique local identity, alias, remote tunnel ID and destination-local DPAPI credential revision. Duplicate identities, aliases, remote IDs and credential paths fail closed. Shared credentials are not offered by this interface: each Add/RotateKey supplies its own runtime key. Keys are entered as SecureString, encrypted using current-user Windows DPAPI, and passed only through the existing bounded connect child's environment reference. No admin-key argument exists. Status, Doctor, logs and generation/recovery digests never contain plaintext keys. No remote tunnel create/delete/rotate operation is performed.

Profile mutation requires a clean stopped household, exact installed payload/owner/task proof and the existing root mutation lock. The existing `incomplete-install.json` fence carries the previous settings and owner receipt plus next-state hashes. A failure rolls the edit back; interruption retains the fence and verified Repair restores the previous binding before startup. Recovery refuses changed or foreign files and a running household. The task definition and install generation are unchanged by profile edits.

Credential rotation creates a new encrypted revision instead of overwriting another profile's key. Retired encrypted revisions remain destination-local, are excluded from active profiles, and remain hash-owned by the native adapter for rollback and exact uninstall. Remove changes only local management; it does not delete the remote tunnel or stop a sibling. Existing receipt-size bounds also apply to profile edits (32 KiB transaction evidence and at most 128 owned encrypted revisions); an edit exceeding them refuses before fencing or mutation.

Start attempts each enabled profile. Credential/connect errors retain that profile's fence and do not abort other profile attempts. An exact launched process can be owned while unhealthy: ownership still requires the pinned executable, same SID, exact profile argv, connect-parent interval and native creation time. Ready remains a separate status condition. A foreign or ambiguous full client prevents further connects; it is never adopted. Stop attempts every configured profile with its exact lifetime guard and an isolated official-stop snapshot containing only that profile's registration and PID. Any unproven stop retains evidence and prevents household completion.

Profile configuration and encrypted active credential digests participate in generation identity. Settings or key changes outside the verified edit path invalidate the immutable running/recovery generation. Use clean stop, Advanced edit, then normal start. Restart preserves each profile-to-key binding.

Deterministic regressions cover collection parsing, real local DPAPI, three independent profiles, exact sibling admission, failure isolation, foreign/ambiguous clients, PID reuse, per-profile stop, transactional edits/rollback, changed configuration and multiple prior-boot receipts. Live three-tunnel operation with independent destination credentials remains a second-machine acceptance case; deterministic mocks do not claim remote credential acceptance.

An Advanced collection cannot be updated or rolled back into a payload that lacks the collection parser. Stage validation refuses that incompatibility before stopping the current household. Compatible candidate updates and rollback retain the profile settings and each credential revision binding.
