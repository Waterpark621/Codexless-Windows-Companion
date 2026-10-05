# Same-machine disposable acceptance harness

`test/disposable-acceptance.ps1` is a bounded, same-machine acceptance harness. It is deliberately **not** clean-machine, different-user, or second-machine acceptance.

## Safety envelope

Every run creates a GUID-scoped temporary root under the Windows temporary directory. The project, transaction destination, state, profile, key, tunnel-fixture, and Scheduler-fixture locations live below that root. Ports are selected by binding loopback port 0. The Scheduler probe uses a GUID-scoped `Codexless-Acceptance-...` task with no trigger, a harmless PowerShell host, IgnoreNew duplicate suppression, cooperative stop, and bounded automatic exit. It never names, opens, starts, stops, exports, or unregisters the production `Codexless-Household-<SID>` task.

The tunnel fixture is local-only and uses the literal in-memory value `fixture-only-not-a-real-credential`. It makes no network connection. A supplied v0.0.14 tunnel client is only executed after its SHA-256 matches the already-qualified pin; the full native lifetime check remains delegated to the existing qualified disposable test.

The persisted JSON report contains only fixed test names, verdicts, and reason codes. It does not contain user SIDs, PIDs, host paths, ports, task XML, timestamps, credentials, release roots, process output, or exception text. Temporary runtime material is deleted after the run.

## Current-base coverage

The harness directly exercises the stable `InstallTransaction.psm1` adapter contract and current lifecycle/config APIs for:

- fresh install and duplicate-install refusal;
- repair;
- uninstall and reinstall;
- successful update;
- failed update with verified rollback;
- interrupted install/update fencing;
- foreign task refusal;
- changed generation refusal;
- malformed owner/cleanup state refusal;
- Start, duplicate Start, Status, Stop, Stop -> Start, and Restart contract behavior;
- a real disposable Scheduler duplicate-start/cooperative-stop probe;
- a real loopback foreign-listener fixture;
- missing credential refusal;
- changed/unqualified release settings refusal;
- harmless isolated tunnel-client status behavior.

Verified incomplete-install recovery is reported `SKIP_EXTERNAL` because the current transaction engine intentionally retains the fence and has no production recovery authority surface. Real Codexless install/Start/status/Doctor is reported `BLOCKED_UNPUBLISHED_ARTIFACT` until the qualified Codexless artifact is available.

## Worker A integration touch point

The transaction engine authority boundary is the existing adapter hashtable. A real adapter used by the integrated harness must provide scriptblocks named:

`Validate`, `VerifyStage`, `GetTask`, `RegisterTask`, `AssertTask`, `Start`, `VerifyReady`, `Stop`, `VerifyStopped`, and `RemoveTask`; update additionally requires `Promote`.

The harness accepts `-NativeAdapterModule <path>` and `-NativeAdapterFactory <function>`. The module path must stay inside the repository. On the Worker D branch this is intentionally only a discovery/binding check because Worker A is absent; Worker A integration must bind that factory exclusively to the harness-provided disposable install root, project root, GUID task name, dynamic port, isolated state/profile/key roots, and fixture-only credential. It must not derive or fall back to the production task/config/tunnel identity.

The coordinator should not remove the `SKIP_EXTERNAL` result for verified recovery or native adapter execution until those exact disposable bindings are implemented and independently proven. A factory name/path difference is an integration mapping issue, not a reason to weaken the adapter contract.

## Bounded command

From the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\test\disposable-acceptance.ps1 -ReportPath .\test\.fixtures\disposable-acceptance-report.json
```

After Worker A is cherry-picked, add its exact module/factory binding:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\test\disposable-acceptance.ps1 -NativeAdapterModule .\<worker-a-module>.psm1 -NativeAdapterFactory <worker-a-factory> -ReportPath .\test\.fixtures\disposable-acceptance-report.json
```

If a qualified published Codexless root later exists, pass `-PublishedCodexlessRoot`; if the independently acquired pinned v0.0.14 tunnel binary is available, pass `-QualifiedTunnelExe`. Neither parameter is required for the current-base self-test.
