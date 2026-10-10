# Codexless Windows Companion

Install and run Codexless on Windows with automatic startup, recovery, Browser health checks and optional OpenAI tunnels.

**Preview — locally qualified; external clean-machine validation pending.**

Preview 5 adds verified recovery for stopped tunnel records that omit their PID and sanitized recovery reason codes in Status, Start and the task-owner log. A prior-boot stopped record still requires the full namespace, generation, process and listener proof. See [Recovery details](docs/PRIOR-BOOT-RECOVERY.md).

Preview 7 fixes fresh-process Doctor module visibility and binds the Browser helper command to the installed generation so source controllers and the running task agree on ownership. It also refuses packaged-app AppData installation before mutation; use Explorer for the default location or a custom location outside AppData. See the [install guide](docs/PUBLIC-INSTALL.md).

Preview 8 anchors the guarded native command's managed process handle before resuming it. Successful tunnel stop commands retain their exit code, output and exact lifetime proof even after the command exits quickly. Failures, timeouts and uncertain lifetimes still retain recovery evidence.

## Quick Start

1. Download the attached Preview ZIP from [Releases](https://github.com/Waterpark621/Codexless-Windows-Companion/releases) and extract it into a new folder.
2. Double-click **INSTALL.cmd**.
3. Choose your **Codexless workspace folder**.
4. Optionally configure one tunnel.
5. Run **DOCTOR.cmd** and require **PASS**.

If you choose a tunnel, enter its existing tunnel ID and runtime API key when prompted. The key prompt is secure, and the key stays on your PC using Windows DPAPI. Never enter an admin key. You can add tunnels later.

Installation needs Internet access and the exact published Preview ZIP; GitHub's source-code ZIP is not the installer. Modified, incomplete or unpublished payloads are refused. Verify the downloaded ZIP against the checksum in the release notes.

Requirements: Windows x64, a normal logged-in user, an existing local workspace folder and a supported connected Codexless Browser backend. Windows security policy must permit the per-user startup task and qualified executables. No administrator account is required. The household runs while you are logged in.

## Choosing a workspace

Your **Codexless workspace folder** is the folder Codexless uses for its work. If you have one project, choose that project's directory directly, for example `D:\MyGame`.

If you work on several projects, create one dedicated parent workspace and keep your projects inside it:

```text
D:\Codexless Work\
├── MyGame\
├── Website\
├── BotProject\
└── Experiments\
```

Then select **`D:\Codexless Work\`** during installation. The folder must already exist. Choose only the projects you intend Codexless to work with; do not select a whole drive, your user profile root or an unnecessarily broad folder. Keep the extracted Companion ZIP folder and installation destination separate from your workspace.

Companion stores Codexless's verified Browser dependency snapshots in `.codexless-browser-runtime-v1\snapshots` inside this selected workspace and starts its Browser worker from the same workspace. On Windows, copying Node into a private home-folder cache can lose the original runtime's sandbox execute access. The cache grants the current user and SYSTEM full access, and `CodexSandboxUsers` read/execute access only, keeping copied trusted files outside sandbox workspace write access. Unexpected cache permissions are refused. Codex's permission profile and workspace roots remain unchanged. Keep the generated cache folder out of project commits.

The Browser health check allows up to 30 seconds for a cold Browser status request, with a 40-second overall probe deadline. Transport setup retains its four-second request limit. Missing connectivity and stalled responses still fail visibly.

### Changing workspace later

This Preview has no in-place workspace switch. Run **STOP.cmd**, then follow the [verified uninstall and reinstall workflow](docs/PUBLIC-INSTALL.md#changing-workspace-after-installation). Reinstall from the verified release ZIP, choose the new workspace and run **DOCTOR.cmd**; require **PASS**. Your project files are preserved. Configure any optional tunnels again during or after reinstall.

## Daily use

Double-click the corresponding file in your extracted Companion folder:

| File | What it does |
| --- | --- |
| **START.cmd** | Starts the installed household; a second Start does not create another owner. |
| **STOP.cmd** | Stops the exact owned household safely. |
| **RESTART.cmd** | Stops, then starts the household. |
| **STATUS.cmd** | Shows current household status. |
| **DOCTOR.cmd** | Checks health, ownership, Browser connectivity and enabled tunnels. Require PASS. |
| **TUNNELS.cmd** | Opens the tunnel profile menu. |

Daily controls do not need to download release notes. Keep the extracted launcher folder intact. Each window remains open so you can read its result.

## Tunnels

**TUNNELS.cmd** offers a numbered menu: **List / Add / Remove / Rotate key / Status**.

Run **STOP.cmd** before adding, removing or rotating a profile, then **START.cmd** afterward. Choose a local profile name when adding a tunnel. Use List to find the profile name/ID for Remove or Rotate key. Add and Rotate key prompt securely for that profile's runtime key. Adding your first tunnel downloads and verifies the official client automatically.

Each profile has its own credential binding. Removing a profile changes local management only; it does **not** delete the remote OpenAI tunnel. The Companion does not create remote tunnels or persist admin keys. Never copy encrypted keys between users or machines.

## If something fails

Read the displayed error and run **DOCTOR.cmd**. Missing Browser connectivity, foreign owners/tasks, changed files or interrupted transactions are refused visibly. Do not delete ownership receipts or edit installed generation files to bypass a refusal.

For an interrupted install, recovery, a custom destination/port, verified uninstall or update/rollback, use the [technical install and maintenance guide](docs/PUBLIC-INSTALL.md). This Preview retains the existing transaction engine; it does not add a new updater or supervisor.

## Preview and technical information

Clean second-user/machine acceptance and live credentialed three-tunnel acceptance remain **pending**. Local qualification uses disposable fixtures and never production credentials or Browser state.

- [Install, maintenance and manual PowerShell reference](docs/PUBLIC-INSTALL.md)
- [Moving from the older launcher](docs/LEGACY-LAUNCHER-MIGRATION.md)
- [Advanced tunnel profiles](docs/MULTI-TUNNEL-PROFILES.md)
- [Artifact provenance](docs/ARTIFACT-PROVENANCE.md)
- [Architecture](docs/ARCHITECTURE.md), [generation identity](docs/GENERATION-CONTRACT.md) and [transactions / rollback](docs/INSTALL-TRANSACTIONS.md)
- [Privacy](docs/PRIVACY.md)
