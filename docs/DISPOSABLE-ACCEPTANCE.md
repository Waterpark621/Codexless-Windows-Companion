# Same-machine disposable acceptance

Run the integrated harness in Windows PowerShell 5.1 with the exact qualified local Codexless candidate and independently acquired pinned tunnel binary:

```powershell
powershell.exe -NoProfile -File .\test\disposable-acceptance.ps1 -LocalCandidateRoot <qualified-candidate-root> -QualifiedTunnelExe <pinned-tunnel-client.exe> -ReportPath <local-report.json>
```

The candidate must match the policy's exact release-manifest digest. This local test does not supply or invent a public download artifact. The report always preserves `BLOCKED_UNPUBLISHED_ARTIFACT` for published distribution acceptance.

## Native execution

The main harness invokes `native-disposable-acceptance.ps1` in a separate Windows PowerShell process and merges its sanitized result rows. The native runner uses the real `NativeTransactionAdapter`, transaction engines, Scheduler, Task-Host, Household-Host, private console, exact Node executable, qualified Codexless launch, and loopback readiness checks. It does not invoke a model.

Each run creates GUID-specific installation and project roots under the ignored `test/.fixtures` directory, a strict transaction-bound `Codexless-NativeAdapter-Test-<GUID>` task, dynamic loopback port, and isolated runtime profile. The child clears inherited credential/config environment. Only the disposable project receives read-only project trust inside its disposable profile. Production task, singleton, configuration, profile, project, and tunnel identities are never used as fallback values.

Native cases cover install and duplicate refusal; Start/duplicate Start/status/readiness/Stop/Stop-to-Start/Restart; repair; update; injected candidate-start failure and real rollback; exact-owned uninstall, project preservation and reinstall; verified incomplete-install recovery; interrupted update and rollback fences; foreign tasks/listeners; changed generations; malformed receipts; and missing/invalid fixture credentials. Deterministic callback failures inject interruption at known transaction boundaries; `transaction-chaos.ps1` separately proves actual controller process exits. These are reported as different forms of evidence.

The main harness also retains contract-level malformed cleanup-state and lifecycle checks. It runs the real task-file replacement race, real NTFS reparse/junction race, and real tunnel/native lifetime suites. The pinned official tunnel client performs bounded version and isolated synthetic-status checks without backend credentials. Remote connect acceptance is the only `SKIP_EXTERNAL` row: it requires a separately provisioned disposable backend and nonproduction credentials that are not available to this run.

## Evidence and teardown

Native fixture evidence is retained locally under ignored paths, including exact interrupted fences and any failure diagnostics. Cleanup uses only the exact GUID task definition and cooperative process shutdown. It never forces termination or deletes uncertain process evidence. Contract-only temporary fixtures are removed after bounded cleanup. Reports contain fixed names, statuses and reason codes; raw process output, SIDs, credentials and machine paths do not enter portable reports or Git.

Keep production source unchanged while native acceptance is running. Its installed payload and controller must use the same generation contract; editing generation-bound source mid-run correctly invalidates ownership/readiness proof.

## Remaining boundary

Same-session Scheduler and two-process tests do not prove a separate Windows logon session. Genuine cross-session mutex behavior, different-user DPAPI, clean-machine Scheduler/security policy, Desktop close/reopen, reboot recovery and credentialed disposable backend acceptance remain second-machine work. The qualified public Codexless artifact and its exact publication metadata are still required before distribution acceptance. `friendInstallReady` remains false.
