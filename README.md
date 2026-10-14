# socair-action

A GitHub Action that scans an open-weight model artifact with
[Socair](https://github.com/defilantech/socair) in a workflow. It downloads a
Socair release binary and verifies it before it runs, scans the model,
uploads the results to GitHub code scanning, and fails the job unless the
report's promotion state is one you allow.

It is a composite action of shell steps plus GitHub's
`github/codeql-action/upload-sarif`, pinned by commit. It runs on Linux and
macOS runners.

## What it claims, and what it does not

The action runs `socair scan`, Socair's Tier 1 static checks, on the bytes in
your workspace. The report answers one question: what was checked in this
exact artifact, what was found, and what was not tested. Each row is PASS,
FAIL, LEAD, or NOT_TESTED, and every report carries one of Socair's fixed
[bounded statements](https://github.com/defilantech/socair/blob/v0.1.0-rc.3/docs/attestation-template.md#7-bounded-statement-fixed).
What the checks cannot see is listed in Socair's
[detection ceiling](https://github.com/defilantech/socair/blob/v0.1.0-rc.3/docs/detection-ceiling.json):
**a report does not certify the absence of unknown backdoors**, and Tier 1
runs no inference, so no model behavior is tested.

- The action derives nothing of its own. The promotion state, the rows, and
  their statuses come from the report Socair wrote.
- A job that passes means the report's promotion state is one `fail-on`
  allows. `authorized` means every check returned PASS within its stated
  scope. It does not mean the model is safe.
- The gate decides the job's exit status only. `fail-on: none` lets a
  withheld model through the job; the report still says withheld.
- The report is unsigned, so it is a claim. A signed attestation
  (`socair sign`) is the proof, and Socair's airlock promotes only that. This
  action does not sign.

## Usage

```yaml
on:
  push:
  pull_request:

permissions:
  contents: read

jobs:
  scan-model:
    runs-on: ubuntu-latest
    permissions:
      contents: read          # actions/checkout
      security-events: write  # the upload to code scanning
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          lfs: true                  # if the model is stored with Git LFS
          persist-credentials: false
      - uses: defilantech/socair-action@<full commit SHA> # <release tag>
        with:
          path: models/example.safetensors
```

Pin the action by its full commit SHA, with the release tag in a comment.
A tag can be moved to other code; a commit cannot. In March 2026 an attacker
force-pushed 76 of 77 version tags of `aquasecurity/trivy-action` to
credential-stealing commits. Workflows that pinned a safe commit, and the one
tag published as an immutable release, were not affected; a commit from before
trivy-action pinned its own dependency still ran a hijacked `setup-trivy`
([GHSA-69fq-xp46-6x23](https://github.com/advisories/GHSA-69fq-xp46-6x23)).
This action pins its one action dependency, `upload-sarif`, by commit.
Where a workflow does not lock its dependencies, GitHub recommends pinning
actions to a full-length commit SHA
([Secure use reference](https://docs.github.com/en/actions/reference/security/secure-use#using-third-party-actions)).

Releases of this action are immutable GitHub releases: once one is published,
its tag and assets cannot change. To find and check the commit of a release:

```
gh release verify <tag> --repo defilantech/socair-action      # it exists and is immutable
gh api repos/defilantech/socair-action/commits/<tag> --jq .sha
```

A pull request from a fork runs with a read-only token, which cannot upload
to code scanning. To scan there without uploading:

```yaml
        with:
          path: models/example.safetensors
          upload-sarif: ${{ github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository }}
```

### Inputs

| Input | Default | Meaning |
|---|---|---|
| `path` | (required) | The model artifact: a GGUF, safetensors, or pickle file, or a model directory (a Hugging Face repository or cache snapshot). Relative to the workspace, or absolute. With `upload-sarif`, it must be under `checkout-path`. |
| `socair-version` | `0.1.0-rc.3` | The Socair release to run, without the leading `v`. The default is the release this version of the action pins by SHA-256. |
| `fail-on` | `withheld authorized_with_conditions escalated` | The promotion states that fail the job, separated by spaces or commas: `withheld`, `authorized_with_conditions`, `escalated`, or `none`. The default fails every state but `authorized`. |
| `upload-sarif` | `true` | `true` uploads the results to code scanning; `false` skips the upload and writes no SARIF file. |
| `category` | `socair:<path from the repository root>` | The code scanning category for this model's results. |
| `checkout-path` | `${{ github.workspace }}` | Where the repository is checked out. SARIF locations are written relative to it. |
| `output-dir` | a new directory under `$RUNNER_TEMP` | Where `report.json` and `report.sarif` are written. It must not already hold either. |

### Outputs

| Output | Holds |
|---|---|
| `promotion-state` | The report's `promotion_authorization.state`. |
| `report` | The path of the report JSON (`socair.report/v1`). |
| `sarif` | The path of the SARIF log that was uploaded; empty when `upload-sarif` is `false`. |
| `artifact-sha256` | The artifact's SHA-256 as the report records it; for a model directory, the digest of its manifest. |
| `category` | The code scanning category the results were uploaded under. |

The outputs are set when the gate fails the job too, so a later step with
`if: always()` can keep the report, for example as a workflow artifact.

### Permissions

| Permission | Needed for |
|---|---|
| `contents: read` | `actions/checkout`, in your workflow. |
| `security-events: write` | The upload to code scanning. Not needed with `upload-sarif: false`. |
| `actions: read` | The upload, in a private repository only ([GitHub's docs](https://docs.github.com/en/code-security/how-tos/scan-code-for-vulnerabilities/integrate-with-existing-tools/uploading-a-sarif-file-to-github)). |

Verifying the binary needs no token and no permission (see below).

## Gating

The last step reads `promotion_authorization.state` from the report JSON, not
from any text output, after the upload, so the results are in code scanning
whichever way the job goes.

| State in the report | Default `fail-on` | Notes |
|---|---|---|
| `authorized` | passes | Never fails the job. |
| `withheld` | fails | Any FAIL or LEAD, or a NOT_TESTED gap nobody accepted. |
| `authorized_with_conditions` | fails | Remove it from `fail-on` to let it pass. In a scan, only `SOCAIR_ACCEPTED_BY` produces it: an acceptance named at scan time, unsigned, which Socair's airlock does not promote. |
| `escalated` | fails | In Socair's schema; nothing produces it. |
| none, or another value | fails | Whatever `fail-on` says. |

A state that passes the gate without being `authorized` raises a warning
annotation. An empty `fail-on`, an unknown value, or `none` with other values
is an error.

## Reference inputs

A bare artifact leaves the trust rows NOT_TESTED, so its promotion is
withheld. Socair moves them with inputs it reads from environment variables
([provenance-bundle.md](https://github.com/defilantech/socair/blob/v0.1.0-rc.3/docs/provenance-bundle.md),
[feed.md](https://github.com/defilantech/socair/blob/v0.1.0-rc.3/docs/feed.md)).
Set them on the action's step with `env:`; they reach the engine unchanged,
and a relative path is read from the workspace.

```yaml
      - uses: defilantech/socair-action@<full commit SHA> # <release tag>
        env:
          SOCAIR_FEED: reference/feed              # a signed reference-data feed
          SOCAIR_FEED_KEYS: reference/feed-signer.pub
          SOCAIR_PROVENANCE: reference/example.provenance.json
        with:
          path: models/example.gguf
```

| Variable (Socair 0.1.0-rc.3) | Moves |
|---|---|
| `SOCAIR_FEED`, `SOCAIR_FEED_KEYS` | A signed feed: denylist, reviewed templates and their texts, canonical tokenizer tables. A feed that does not verify, or has expired, stops the scan. |
| `SOCAIR_DENYLIST` | Known-bad hash match |
| `SOCAIR_PROVENANCE` | Hash, provenance, lineage |
| `SOCAIR_REPO_MIRROR` | File inventory and payloads, for a single file |
| `SOCAIR_PUBLISHER_KEYS`, `SOCAIR_PUBLISHER_ROOTS`, `SOCAIR_OMS_SIGNATURE` | Hash, provenance, lineage, from an OpenSSF Model Signing signature |
| `SOCAIR_TOKENIZER_REFERENCE`, `SOCAIR_TEMPLATE_REFERENCE` | Tokenizer config and Chat template comparisons |
| `SOCAIR_LICENSE_POLICY` | Adds the License policy row |
| `SOCAIR_SCAN_TMP` | Where scan snapshots go. The action sets it to `$RUNNER_TEMP` when unset. |

The report names the reference data it used in `scope.reference_data`. A scan
in this action has no airlock store, so a feed is not checked against the
newest feed a store has used. `SOCAIR_ACCEPTED_BY` records an unsigned
acceptance (see Gating).

## How the binary is verified

Before Socair runs, `scripts/install.sh` downloads the binary for the runner
(`socair_<version>_<os>_<arch>`), the release's `SHA256SUMS`, and its
attestations file `socair_<version>.intoto.jsonl`, and checks, in order:

1. **The pinned SHA-256.** For the default version, the binary's SHA-256
   must equal the value in [`socair-sha256.txt`](socair-sha256.txt). The pins
   were checked against the release's `SHA256SUMS`, the digests GitHub records
   for the release assets, and the subjects of the build-provenance
   attestation; `scripts/check-pins.sh` checks them again in CI.
2. **`SHA256SUMS`.** The binary's SHA-256 must equal its line there. This
   catches a damaged download, not a tampered release: whoever can replace
   the binary can replace `SHA256SUMS`
   ([Socair's verify-release.md](https://github.com/defilantech/socair/blob/v0.1.0-rc.3/docs/verify-release.md#1-checksums)).
3. **Build provenance.**

   ```
   gh attestation verify <binary> --bundle socair_<version>.intoto.jsonl \
     --repo defilantech/socair \
     --signer-workflow defilantech/socair/.github/workflows/release.yml \
     --source-ref refs/tags/v<version> --deny-self-hosted-runners
   ```

   The attestation must be signed through Sigstore for the binary's digest,
   by Socair's `release.yml`, for the tag of the version asked for, on a
   GitHub-hosted runner. What makes it count is the signing certificate,
   which GitHub's OIDC token fills in, not where the file came from; read from
   `--bundle`, it needs no GitHub token. `gh` fetches the Sigstore trust root
   over the network.

The binary is made executable only after all three pass, and its
`socair version` must name the version asked for. A failed check stops the
action before any scan and deletes the download.

What each check adds: the attestation ties the bytes to a run of Socair's
release workflow for that tag. The pin ties them to the exact bytes this
action's release was checked against, so it also refuses bytes that workflow
attested afterwards, for example if the workflow or one of its dependencies
were compromised. That is how Trivy v0.69.4 was published: an attacker pushed
a commit and a tag that ran Trivy's own release pipeline (same advisory).
A `socair-version` other than the default has no pin: it is checked against
`SHA256SUMS` and its build provenance only, and the action says so in a
notice.

The test workflow shows each check stops the action: a copy of the action
with the pins replaced by zeros, and a copy that checks the attestation
against another of Socair's workflows, both fail before the scan step, and
no report exists.

## SARIF and code scanning

`socair render <path> --sarif` writes one result per check row. The action
uploads that log with two changes:

- **Locations.** Socair writes the artifact's file name; code scanning reads
  a relative URI from the repository root. Each location becomes the path
  from `checkout-path`, percent-encoded per segment. Socair writes no line
  region, since a model file has no lines; code scanning shows the alert at
  line 1.
- **PASS rows are left out.** Code scanning documents the levels `note`,
  `warning`, and `error`, and does not list `kind` among the result
  properties it reads
  ([SARIF support](https://docs.github.com/en/code-security/reference/code-scanning/sarif-files/sarif-support)),
  so a PASS would be listed as an alert. A FAIL is
  an `error`, a LEAD a `warning`, and a NOT_TESTED a `note`, which keeps an
  untested surface visible. The report JSON keeps every row.

`socair render` takes an artifact, not a report, so the SARIF comes from a
second scan of the same bytes. The action uploads nothing unless that log
names the same artifact SHA-256 and promotion state as the report. The cost
is a second snapshot of the artifact: time, and temporary disk equal to its
size.

The default category is `socair:<path from the repository root>`: one per
model, and the same across revisions, so the analysis of a new revision closes
the alerts the last one raised. Two scans in one job need different paths or
categories; `upload-sarif` refuses a second upload of one category in a job.

**Fingerprints.** Code scanning matches results across runs by
`partialFingerprints.primaryLocationLineHash`, and GitHub says results
uploaded without one may show up as duplicate alerts. Socair 0.1.0-rc.3
writes none, and the action raises a warning when it uploads results without
one. Socair's main branch gives every result a fingerprint of its finding
([sarif.md](https://github.com/defilantech/socair/blob/5b31d918a74ebb589db749847e34d17790f41f79/docs/sarif.md#fingerprints),
defilantech/socair#231). The location rewrite does not touch them, so a
release that carries them needs only a new `socair-version` default and pins
here.

## What is not covered

- **Windows.** Socair publishes no Windows binary; the action stops with an
  error on a Windows runner.
- **A Hugging Face repository at a commit.** The action scans a path in the
  workspace. Fetch the model in an earlier step; Socair's own `airlock pull`
  is not wired in here.
- **Signing the report**, or publishing it as an attestation with
  `actions/attest`. The report the action writes is unsigned.
- **Tier 2**, which runs the model on your own GPUs, and the airlock store and
  its promotion.
- **Self-hosted and air-gapped runners.** The tests run on GitHub-hosted
  Linux and macOS runners. Verification needs `gh` with
  `gh attestation verify --source-ref`, `jq`, `curl`, and network access to
  github.com and the Sigstore trust root.
- **A model outside the checkout** cannot be uploaded to code scanning, which
  places results by repository path; with `upload-sarif: false` it can be
  scanned.

## Development

`.github/workflows/test.yml` runs the action from the commit under test, on
one runner per release binary (Linux and macOS, amd64 and arm64), against a
safetensors file written by [`test/fixtures.sh`](test/fixtures.sh), never a
downloaded model. It checks the outputs, that a withheld model fails the job
under the default `fail-on` and passes when `fail-on` allows it, that the same
bytes with reference inputs are authorized, and the falsification runs above.
Every action it uses is pinned by commit.

Releasing a new Socair version here means updating the `socair-version`
default in `action.yml` and its four lines in `socair-sha256.txt`, after
verifying the release as [Socair's verify-release.md](https://github.com/defilantech/socair/blob/v0.1.0-rc.3/docs/verify-release.md)
describes. `scripts/check-pins.sh` fails until the two agree with the release.

See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).

## License

Apache License 2.0. See [LICENSE](LICENSE).
