# Mutation exclusion and delegated host admission

The shared `Global\CodexlessMutation-<rootDigest>` lock now covers transaction exports, direct lifecycle calls, native task helpers, native adapter mutations, prior-boot retirement, console/tunnel mutation, and supervisor startup/shutdown scopes. Read-only Status, Doctor/readiness and CheckOnly recovery remain unlocked.

## Controller and host protocol

The controller holds the root mutex and an exact, no-write/no-delete-sharing durable marker. Nested calls on the same controller thread borrow its in-memory lease. A poisoned controller also refuses direct native and resource mutation callbacks. Another process, another thread, a stale marker, and an abandoned mutex cannot borrow it. Native transaction mutation callbacks additionally require this live controller lease before interpreting transaction fences.

For native Start or Stop the controller opens a private, current-user named pipe and publishes a held delegation record. The record binds the root digest, operation nonce, controller PID and creation time, exact task name, transaction, generation, and Startup or Shutdown phase. The pipe server verifies the connecting process through its kernel-reported PID, held process lifetime, executable, full expected task action, Scheduler service parent, and impersonated SID. The host verifies the pipe server PID and exact creation time; a record on disk alone never authorizes work.

Task-Host admits ownership/recovery startup only after its existing Scheduler/identity gates. Household-Host admits initialization, each mutation cycle, and graceful shutdown separately. During an ordinary autonomous logon or supervision cycle it takes the root mutex itself; an incomplete transaction refuses autonomous admission. During controller-owned transitions it can only borrow the exact matching host phase through the live pipe. Private-console and tunnel wrappers share that admitted scope. The console signal helper remains a child of the already admitted stop operation and retains its exact private-console member/lifetime proof.

At the end of a phase the server stops admitting participants and waits for active work to acknowledge completion before controller mutations resume. Peer interruption or a drain timeout poisons the controller lease and retains durable evidence. Neither case releases uncertain authority for another transaction. Normal marker and delegation-record retirement uses the exact held file handle, preventing path replacement at deletion.

## Audit mapping

| Mutating surface | Enforcement |
| --- | --- |
| Install, Repair, Uninstall, Update, verified incomplete-install recovery | Existing transaction wrapper, now backed by exact native lease/marker; recovery evidence checks remain unchanged. |
| CLI Register/Start/Stop/Restart | Shared root lock; nested lifecycle calls borrow it. |
| Exported lifecycle mutators | Shared root lock; native adapters use explicit Startup/Shutdown delegation and readiness/stop completion. |
| Scheduled Task register/start/unregister | Shared root lock plus existing E5 exact task-file pin/create-only authority. |
| Native adapter register/start/stop/remove/promote | Requires in-memory controller lease, then original fence/generation/config/task authority. |
| Task-Host recovery/owner receipt and completed cleanup | Exact host admission, inside existing Scheduler and singleton gates. |
| Household-Host initialization/runtime/tunnel/stop | Explicit host admission scopes; competing controller phases defer supervision. |
| Exported cleanup-state write and owner-tracking retirement | Resource admission or shared root lock; failed-cleanup no-op stays unchanged. |
| Exported native tunnel command/connect | Resource admission or shared root lock; only exact status argv remain observational. |
| Exported prior-boot recovery | Resource mutation wrapper; CheckOnly remains read-only. |
| Console and tunnel public mutation wrappers | Resource admission or shared root lock; existing exact process/receipt proofs retained. |
| Status, readiness, Doctor observations | No mutation lock required. |

Diagnostic log append/rotation is non-authoritative: logs are neither ownership proof nor transaction-owned payload and are preserved by uninstall. It remains outside the resource mutation protocol. Generic filesystem and bounded-process primitives are not ownership-authorizing entrypoints.

Production keeps its historical singleton namespace. Only the strict transaction-bound `Codexless-NativeAdapter-Test-<GUID>` namespace receives isolated test owner/host mutexes. Disposable settings use a dedicated runtime profile; inherited credential/config environment is removed in the disposable child. The test harness creates project-specific read-only Codex trust only inside that disposable profile and never submits a model call.

## Evidence and limits

- `mutation-exclusion-regression.ps1`: reproduced three missing exclusions before the fix; all three pass afterward; four additional public-helper exclusion cases cover cleanup receipts and native tunnel stop/connect, including a real Scheduler Start attempt under another process's root lock.
- `delegated-host-lease.ps1`: real Scheduler child admitted under controller ownership, wrong phase/generation refused, and controller waits for participant completion.
- `delegated-host-interruption.ps1`: actual Scheduler host and controller self-exits while admitted; both retain a durable fence and refuse later mutation. Test-only teardown occurs after both known participants exit.
- `lease-interruption.ps1`: nested lease, exact marker substitution resistance, ordinary exception cleanup, and poisoned durable-fence behavior.
- `mutation-lock.ps1`: real two-process exclusion, reuse, and deliberate child self-exit/abandoned lock refusal. No force termination.
- Existing receipt, reparse, task-replacement, six-stage recovery, transaction interruption, and process-lifetime suites remain required.

This implementation targets the registered task's Windows PowerShell 5.1 runtime. It does not claim PowerShell 7 qualification or a security boundary against arbitrary code already executing with the same user's full authority.

Genuine separate Windows logon-session execution remains a `SECOND_MACHINE_TEST_ITEM`. Same-session processes and interactive-token Scheduler tests do not prove it. Different-user DPAPI and clean-machine Scheduler/tunnel policy remain separate acceptance items. The current Codexless distribution is published and pinned; unpublished policy fixtures still fail closed.
