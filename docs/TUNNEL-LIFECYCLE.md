# Qualified managed tunnel lifecycle

Only the pinned official full client v0.0.14 Windows amd64 is supported. Every CLI invocation uses the bounded native runner, exact executable hash, explicit argv, fixed output ceiling and deadline. Child state/profile roots are bound to the exact task-owner generation and never resolve ambient vendor state. Connect receives only a child-local environment key reference; Companion never persists raw CLI stdout/stderr.

A fresh generation may connect once, after exact owned Codexless listener/readiness proof. An existing full client blocks launch. A create-new namespace and incomplete connect intent fence precede native mutation. Every failure retains that fence. Connect exit success alone is insufficient: immediate status must be healthy, ready and running with the exact registration. Native process identity must match the connect parent's PID and creation/exit interval, current SID, pinned executable and exact managed profile argv. Only then is a v2 generation/hash/namespace/native-lifetime receipt written. Existing ready clients require that exact receipt; alive degraded clients are left to official recovery. No replacement is launched in an existing generation.

Stop holds a synchronize/query process handle through the official command and exact exit proof. It supplies a fresh isolated vendor input snapshot containing only the proven PID and registration rather than a mutable ambient process table. Stop is bounded; no Companion force termination exists. All receipt bytes must remain unchanged before removal. Unknown status, timeout, overflow, failed native command, changed identity or receipt retains evidence and blocks replacement. Windows policy refusal is sanitized and must never be bypassed.

Holding a Windows process handle retains the process object and prevents that PID from being reused until all handles close. See the Microsoft PROCESS_INFORMATION contract. This mechanism does not defend against a malicious process already running as the same Windows account; that account already controls its runtime credentials and install files.

The installer remains plan-only. Clean-machine security-policy acceptance, transactional install/repair/uninstall and update/rollback remain separate gates. Deterministic tests use mocks and private disposable fixture state; no production key or alias is required.

The official stop CLI is created suspended with an explicit inherited stdio handle list. Before its first instruction, Companion duplicates the exact managed lifetime query/synchronize handle into that process, then resumes it. The stop child keeps that guard until it exits, even if the caller times out or dies. A failed guard transfer never resumes the child and reports a fenced suspended lifetime; no process is force-killed. This avoids releasing the PID pin while an indeterminate stop command could still act.

Receipt retirement opens the exact file object without write/delete sharing, compares all saved bytes, then applies delete disposition to that same handle. A changed or substituted file cannot be removed after the comparison.

Windows lifetime reference: https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/ns-processthreadsapi-process_information
