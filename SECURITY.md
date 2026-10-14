# Security policy

This action downloads Socair and runs it in workflows that hold tokens and
secrets. These are vulnerabilities, and we want to hear about them privately
first:

- the action runs a Socair binary that did not pass its checks (the pinned
  SHA-256, `SHA256SUMS`, and the build-provenance attestation);
- a job passes that `fail-on` should fail, or the action reports a promotion
  state the report does not hold;
- an input, or a file in a scanned model, runs commands or workflow commands
  on the runner;
- the action exposes a token or a secret.

## Reporting a vulnerability

Report it as [Socair's security policy](https://github.com/defilantech/socair/blob/main/SECURITY.md)
describes: through GitHub's private vulnerability reporting on the
[Socair repository](https://github.com/defilantech/socair/security), or by
email to **security@socair.ai**. Say that it concerns `socair-action`, and
include the action's commit, the workflow or inputs that reproduce it, what
you expected, and what happened. Please do not open a public issue, pull
request, or discussion for a suspected vulnerability.

A vulnerability in Socair itself, such as a file that earns a PASS it should
not, goes the same way; Socair's policy says what is in scope.

## Supported versions

Security fixes go to the latest release. Pin the action by commit, as the
README describes, and update the pin to take a fix.
