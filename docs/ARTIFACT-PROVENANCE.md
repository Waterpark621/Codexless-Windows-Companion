# Artifact provenance

Codexless package provenance, Node executable provenance and tunnel-client provenance are distinct gates. Manifest verification binds the qualified Codexless source payload; it does not certify a Node or tunnel executable.

`ARTIFACT-POLICY.json` pins the Windows x64 ZIP for the already-qualified Node 24.12.0 version to the official `nodejs.org` distribution and SHA-256 from its official SHASUMS256.txt. This is a reviewed checksum pin obtained through HTTPS, not a claim that OpenPGP signature verification was performed. Other architectures require their own explicit qualification.

`Save-QualifiedArtifact` permits only the exact policy URL, HTTPS, HTTP 200, no redirect, explicit deadline and byte limit, and a fresh staging directory. Partial failures remain staged and are never promoted or executed. `Expand-QualifiedArtifact` hashes and extracts through one locked archive stream, preflights every entry for traversal, aliases, case-insensitive collisions, links and size/count limits, and refuses an existing destination. It does not register tasks, start executables or promote an installation.

Codexless download policy remains unbound pending an actual published artifact and its reviewed archive checksum. The local qualified release identity remains authoritative for local validation. Tunnel policy remains unbound: the project has not selected a portable client version/distribution/checksum. Both unbound roles refuse before download or staging mutation. There is no current-machine binary copying or download-time trust-on-first-use.

Automatic installer mutation and tunnel connect remain disabled. A pinned archive is only one prerequisite for transactional promotion; it does not establish a generation, process lifetime, update/rollback or second-machine acceptance.

The approved tunnel distribution is the official OpenAI v0.0.14 Windows amd64 full client. Both archive and extracted executable hashes are pinned. The pinned GitHub asset may redirect once to the HTTPS official release asset CDN; Node redirects and further redirects remain forbidden. Signed CDN URLs stay in memory; no origin credentials or cookies are forwarded. Unsigned executable policy compatibility remains a clean-machine acceptance gate. Security controls must never be bypassed. Qualification alone does not enable automatic connect.
