#!/usr/bin/env bash
# Download the Socair release binary for this runner and verify it before it
# can run. Every check must pass, in this order, or the action stops here and
# no scan runs:
#
#   1. For a version this action pins (socair-sha256.txt), the binary's
#      SHA-256 equals the pinned value.
#   2. The binary's SHA-256 equals its line in the release's SHA256SUMS.
#   3. Its build-provenance attestation verifies: signed through Sigstore by
#      defilantech/socair's release.yml, for the tag v<version>, on a
#      GitHub-hosted runner (gh attestation verify).
#
# The binary is made executable only after all three pass.
#
# Environment: VERSION_INPUT (the socair-version input), plus the runner's
# GITHUB_ACTION_PATH, GITHUB_OUTPUT, RUNNER_OS, RUNNER_ARCH, RUNNER_TEMP.
# The pinned-checksum and signer-workflow values below are what the
# falsification tests in .github/workflows/test.yml change to prove a failed
# check stops the action.
set -euo pipefail

repo="defilantech/socair"
signer_workflow="defilantech/socair/.github/workflows/release.yml"
pins="${GITHUB_ACTION_PATH:?}/socair-sha256.txt"

fail() {
	echo "::error title=Socair binary not verified::$*"
	exit 1
}

sha256() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d ' ' -f 1
	else
		shasum -a 256 "$1" | cut -d ' ' -f 1
	fi
}

# lookup <sums file> <asset name>: print the one SHA-256 listed for the asset,
# or fail if it is listed zero times or more than once.
lookup() {
	awk -v name="$2" '$2 == name { print $1; n++ } END { exit (n == 1 ? 0 : 1) }' "$1"
}

version="${VERSION_INPUT:-}"
version="${version#v}"
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
	fail "socair-version must be a release version such as 0.1.0-rc.3, not '${VERSION_INPUT:-}'"
fi

case "${RUNNER_OS:-}" in
Linux) os=linux ;;
macOS) os=darwin ;;
*) fail "Socair publishes binaries for Linux and macOS only; this runner is '${RUNNER_OS:-unknown}'" ;;
esac
case "${RUNNER_ARCH:-}" in
X64) arch=amd64 ;;
ARM64) arch=arm64 ;;
*) fail "Socair publishes binaries for amd64 and arm64 only; this runner is '${RUNNER_ARCH:-unknown}'" ;;
esac

for tool in curl gh awk; do
	command -v "$tool" >/dev/null 2>&1 || fail "$tool is required and was not found on this runner (GitHub-hosted runners have it)"
done
command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 ||
	fail "sha256sum or shasum is required and neither was found on this runner"

asset="socair_${version}_${os}_${arch}"
bundle="socair_${version}.intoto.jsonl"
base="https://github.com/${repo}/releases/download/v${version}"
dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/socair-bin.XXXXXX")"
# A download that fails a check is deleted, so no later step can run it.
trap 'rc=$?; if ((rc != 0)); then rm -rf -- "$dir"; fi' EXIT

fetch() {
	curl --fail --silent --show-error --location \
		--proto '=https' --proto-redir '=https' --tlsv1.2 \
		--retry 3 --retry-delay 2 \
		--output "$dir/$1" "$base/$1" ||
		fail "could not download $1 from $base"
}
fetch "$asset"
fetch SHA256SUMS
fetch "$bundle"

got="$(sha256 "$dir/$asset")"
echo "downloaded $asset, sha256 $got"

# 1. The pin this action carries for its default version.
if awk -v p="socair_${version}_" 'index($2, p) == 1 { found = 1 } END { exit !found }' "$pins"; then
	pinned="$(lookup "$pins" "$asset")" || fail "this action pins Socair $version but lists no single SHA-256 for $asset"
	[[ "$got" == "$pinned" ]] || fail "$asset has sha256 $got, but this action pins $pinned"
	echo "matches the SHA-256 this action pins for $asset"
else
	pinned=""
	echo "::notice title=Socair binary::This action pins no SHA-256 for Socair $version; the binary is checked against the release's SHA256SUMS and its build provenance only."
fi

# 2. The release's SHA256SUMS.
listed="$(lookup "$dir/SHA256SUMS" "$asset")" || fail "the release's SHA256SUMS lists no single SHA-256 for $asset"
[[ "$got" == "$listed" ]] || fail "$asset has sha256 $got, but the release's SHA256SUMS lists $listed"
echo "matches the release's SHA256SUMS"

# 3. Build provenance. The attestations come from the release's attestations
# file; what makes one count is its Sigstore signature, whose certificate
# names the repository, the workflow, and the tag that built the binary, not
# where the file was downloaded from. --bundle reads it without a GitHub token.
if ! gh attestation verify "$dir/$asset" \
	--hostname github.com \
	--bundle "$dir/$bundle" \
	--repo "$repo" \
	--signer-workflow "$signer_workflow" \
	--source-ref "refs/tags/v${version}" \
	--deny-self-hosted-runners >/dev/null; then
	fail "the build-provenance attestation of $asset did not verify against $signer_workflow at refs/tags/v${version}"
fi
echo "build provenance verified: built by $signer_workflow at refs/tags/v${version} on a GitHub-hosted runner"

bin="$dir/socair"
mv "$dir/$asset" "$bin"
chmod 0755 "$bin"
reported="$("$bin" version)"
[[ "$reported" == "socair $version" ]] || fail "the verified binary reports '$reported', not 'socair $version'"

{
	echo "socair=$bin"
	echo "version=$version"
	echo "pinned=$([[ -n "$pinned" ]] && echo true || echo false)"
} >>"${GITHUB_OUTPUT:?}"
