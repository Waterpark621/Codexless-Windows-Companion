# Privacy and no-dox policy

This repository is intended to be safe to publish.

## Never commit

- a real Windows username or home-directory path;
- a real machine/user SID;
- live process IDs, owner receipts, cleanup/recovery dumps, or task exports from a personal machine;
- real tunnel aliases, account IDs, keys, credential files, tokens, or DPAPI ciphertext;
- browser profiles, cookies, history, native-host registration dumps, or copied dependency caches;
- screenshots/logs containing personal applications, tabs, URLs, or account data;
- absolute source-worktree or rollback paths from a developer PC.

Use placeholders such as <USER>, <SID>, <PROJECT_PATH>, and <TUNNEL_ALIAS> in documentation.

## Allowed machine-specific data at runtime

The installed Companion may record the minimum identity data needed to prove ownership on that destination PC (for example current SID and exact process lifetime). That runtime state lives outside the source repository and must never be packaged into a release archive.

## Before any push or release

Run:

powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/Test-PublicTree.ps1

Also:

- pass a private newline-delimited needle file with `-PrivateNeedlesPath` for current-machine identifiers;
- scan **every reachable Git commit/blob**, not only the current worktree;
- inspect commit metadata for accidental identifying information;
- inspect the exact release archive before publication;
- confirm tunnel profiles, Browser/native-host caches, logs, keys, receipts, recovery evidence and generated runtime directories are absent.

The checker reports only file/line/category, not the private value. The repository-level scanner is one gate, not a substitute for history/archive review.
