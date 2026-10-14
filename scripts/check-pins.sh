#!/usr/bin/env bash
# Hold socair-sha256.txt to the Socair releases it pins:
#
# - action.yml's default socair-version is pinned, for all four platforms;
# - each pinned version's release is published and immutable;
# - each pinned SHA-256 equals the digest GitHub records for that release
#   asset and the asset's line in the release's SHA256SUMS.
#
# Needs gh with a token that can read public repositories (GH_TOKEN).
#
#   scripts/check-pins.sh
set -euo pipefail

repo="defilantech/socair"
root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
pins="$root/socair-sha256.txt"
platforms="linux_amd64 linux_arm64 darwin_amd64 darwin_arm64"

problems=0
problem() {
	echo "::error file=socair-sha256.txt::$*"
	problems=1
}

# The default of the socair-version input in action.yml.
default="$(awk '
	/^  socair-version:/ { f = 1; next }
	f && /^    default:/ { v = $2; gsub(/["'\'']/, "", v); print v; exit }
	f && /^  [^ ]/ { exit }
' "$root/action.yml")"
[[ -n "$default" ]] || {
	echo "::error file=action.yml::no default for the socair-version input"
	exit 1
}

entries="$(grep -v -e '^#' -e '^[[:space:]]*$' "$pins")"
while IFS= read -r line; do
	[[ "$line" =~ ^[0-9a-f]{64}\ \ socair_[0-9A-Za-z.-]+_(linux|darwin)_(amd64|arm64)$ ]] ||
		problem "not a '<sha256>  socair_<version>_<os>_<arch>' line: $line"
done <<<"$entries"

versions="$(awk '{ print $2 }' <<<"$entries" | sed -E 's/^socair_(.*)_(linux|darwin)_(amd64|arm64)$/\1/' | sort -u)"
grep -qxF -- "$default" <<<"$versions" || problem "action.yml's default socair-version $default has no pinned SHA-256"

for v in $versions; do
	tag="v$v"
	release="$(gh release view "$tag" --repo "$repo" --json isDraft,isImmutable,assets)" || {
		problem "$repo has no release $tag"
		continue
	}
	[[ "$(jq -r .isDraft <<<"$release")" == false ]] || problem "$tag is a draft"
	[[ "$(jq -r .isImmutable <<<"$release")" == true ]] || problem "$tag is not an immutable release"
	sums="$(gh release download "$tag" --repo "$repo" --pattern SHA256SUMS --output -)"
	for p in $platforms; do
		asset="socair_${v}_${p}"
		pinned="$(awk -v a="$asset" '$2 == a { print $1 }' <<<"$entries")"
		if [[ "$(wc -l <<<"$pinned" | tr -d ' ')" != 1 || -z "$pinned" ]]; then
			problem "$asset needs exactly one pinned SHA-256"
			continue
		fi
		recorded="$(jq -r --arg a "$asset" '.assets[] | select(.name == $a) | .digest' <<<"$release")"
		[[ "$recorded" == "sha256:$pinned" ]] || problem "$asset is pinned at $pinned; GitHub records '$recorded' for the release asset"
		listed="$(awk -v a="$asset" '$2 == a { print $1 }' <<<"$sums")"
		[[ "$listed" == "$pinned" ]] || problem "$asset is pinned at $pinned; the release's SHA256SUMS lists '$listed'"
	done
	echo "$tag: checked the pins against the release's asset digests and SHA256SUMS"
done

exit "$problems"
