#!/usr/bin/env bash
# Scan one model artifact with the verified Socair binary, write the report
# JSON, and, when the SARIF is to be uploaded, write the SARIF log code
# scanning reads. The action derives nothing of its own: the promotion state
# and every row come from the report Socair wrote.
#
# Environment: SOCAIR (the verified binary), MODEL_PATH, UPLOAD_SARIF,
# CATEGORY, CHECKOUT_PATH, OUTPUT_DIR (the action's inputs), plus the
# runner's GITHUB_OUTPUT, GITHUB_STEP_SUMMARY, RUNNER_TEMP. Any SOCAIR_*
# variable in the environment reaches the engine unchanged.
set -euo pipefail

fail() {
	echo "::error title=Socair scan::$*"
	exit 1
}

# run_socair <stdout file> <socair args...>: run Socair with workflow commands
# paused, so nothing a scanned file puts in Socair's output (a file name in a
# model directory, say) is read by the runner as a workflow command.
run_socair() {
	local stdout="$1" token rc=0
	shift
	token="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
	echo "::stop-commands::$token"
	"${SOCAIR:?}" "$@" >"$stdout" || rc=$?
	echo "::$token::"
	return "$rc"
}

nl=$'\n'
model="${MODEL_PATH:-}"
upload="${UPLOAD_SARIF:-}"
category="${CATEGORY:-}"
checkout="${CHECKOUT_PATH:-}"
out="${OUTPUT_DIR:-}"

[[ -n "$model" ]] || fail "path is required: a model file or a model directory"
for v in "$model" "$category" "$checkout" "$out"; do
	[[ "$v" != *"$nl"* ]] || fail "inputs must not contain a newline"
done
case "$upload" in
true | false) ;;
*) fail "upload-sarif must be true or false, not '$upload'" ;;
esac
[[ -e "$model" ]] || fail "path '$model' does not exist"

# The artifact's absolute path, as written (symbolic links are not resolved,
# so a link committed in the repository keeps its repository path).
if [[ -d "$model" ]]; then
	abs="$(CDPATH='' cd -- "$model" && pwd)"
else
	abs="$(CDPATH='' cd -- "$(dirname -- "$model")" && pwd)/$(basename -- "$model")"
fi

rel=""
if [[ "$upload" == true ]]; then
	co="$(CDPATH='' cd -- "$checkout" 2>/dev/null && pwd)" || fail "checkout-path '$checkout' is not a directory"
	[[ "$abs" != "$co" ]] || fail "path is the checkout root; point it at the model file or the model directory"
	case "$abs" in
	"$co"/*) rel="${abs#"$co"/}" ;;
	*) fail "path '$model' is outside the checkout ($co). Code scanning places a result at a path relative to the repository root, so the artifact must be under it: put the model below the workspace, or set upload-sarif: false" ;;
	esac
	[[ -n "$category" ]] || category="socair:$rel"
fi

if [[ -z "$out" ]]; then
	out="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/socair.XXXXXX")"
else
	mkdir -p -- "$out"
	out="$(CDPATH='' cd -- "$out" && pwd)"
fi
report="$out/report.json"
sarif="$out/report.sarif"
for f in "$report" "$sarif"; do
	[[ ! -e "$f" ]] || fail "$f already exists; name an output-dir without one, so an earlier report is never read as this scan's"
done

# Scan snapshots go to the runner's temporary directory unless the workflow
# says otherwise; a snapshot needs the artifact's size free.
export SOCAIR_SCAN_TMP="${SOCAIR_SCAN_TMP:-${RUNNER_TEMP:-}}"

rc=0
run_socair "$report.partial" scan "$abs" || rc=$?
if ((rc != 0)); then
	rm -f -- "$report.partial"
	fail "socair scan exited with status $rc; its message is above"
fi
mv -- "$report.partial" "$report"

jq -e '(.artifact.sha256 | type) == "string" and (.promotion_authorization | type) == "object"' "$report" >/dev/null ||
	fail "socair scan did not write a report document"
state="$(jq -r '.promotion_authorization.state // ""' "$report")"
sha="$(jq -r '.artifact.sha256' "$report")"
echo "report: $report"
echo "artifact sha256 $sha, promotion state '${state}'"

if [[ "$upload" == true ]]; then
	# socair render takes an artifact, not a report, so the SARIF comes from a
	# second scan of the same bytes. It must describe the same artifact and
	# reach the same promotion state as the report, or nothing is uploaded.
	rendered="$out/socair.sarif.partial"
	rc=0
	run_socair /dev/null render "$abs" --sarif "$rendered" || rc=$?
	if ((rc != 0)); then
		rm -f -- "$rendered"
		fail "socair render exited with status $rc; its message is above"
	fi
	jq -e '(.runs | length) == 1' "$rendered" >/dev/null || fail "the SARIF log Socair wrote does not hold exactly one run"
	s_sha="$(jq -r '.runs[0].properties.socairArtifactSHA256 // ""' "$rendered")"
	s_state="$(jq -r '.runs[0].properties.socairPromotionState // ""' "$rendered")"
	if [[ "$s_sha" != "$sha" || "$s_state" != "$state" ]]; then
		fail "the SARIF log (artifact '$s_sha', state '$s_state') does not describe the scan in the report (artifact '$sha', state '$state'); nothing is uploaded"
	fi

	# Two changes, nothing else:
	# - Each location becomes the artifact's path from the repository root,
	#   percent-encoded per segment. Socair writes the file name alone, and
	#   code scanning reads a relative URI from the repository root.
	# - PASS results are left out (kind "pass", or level "none", which Socair
	#   writes only for a PASS). Code scanning documents the levels note,
	#   warning, and error and does not read kind, so a PASS would be listed
	#   as an alert. FAIL (error), LEAD (warning), and NOT_TESTED (note) stay.
	jq --arg rel "$rel" '
		($rel | split("/") | map(@uri) | join("/")) as $uri
		| def pass: (.kind // "fail") == "pass" or (.level // "warning") == "none";
		.runs[0].results |= map(
			select(pass | not)
			| if (.locations | type) == "array" and (.locations | length) > 0
			  then .locations |= map(
				.physicalLocation.artifactLocation.uri = $uri
				| del(.physicalLocation.artifactLocation.uriBaseId))
			  else .locations = [{physicalLocation: {artifactLocation: {uri: $uri}}}]
			  end)
	' "$rendered" >"$sarif.partial"
	passes="$(jq '[.runs[0].results[] | select((.kind // "fail") == "pass" or (.level // "warning") == "none")] | length' "$rendered")"
	rm -f -- "$rendered"
	mv -- "$sarif.partial" "$sarif"
	kept="$(jq '.runs[0].results | length' "$sarif")"
	echo "SARIF: $sarif (results: $kept, at $rel, category $category; PASS results left out: $passes)"

	unprinted="$(jq '[.runs[0].results[] | select((.partialFingerprints.primaryLocationLineHash // "") == "")] | length' "$sarif")"
	if ((unprinted > 0)); then
		echo "::warning title=Socair SARIF::$unprinted of $kept results carry no fingerprint, so code scanning cannot match them across runs and may show duplicate alerts. Socair 0.1.0-rc.3 and earlier write none; Socair's SARIF fingerprints (defilantech/socair#231) postdate that release."
	fi
else
	sarif=""
fi

# Outputs. The state is written only when it is a plain word; the gate reads
# the report itself either way.
[[ "$state" =~ ^[a-z_]+$ ]] || state=""
{
	echo "promotion-state=$state"
	echo "report=$report"
	echo "sarif=$sarif"
	echo "artifact-sha256=$sha"
	echo "category=$category"
} >>"${GITHUB_OUTPUT:?}"

# A job summary from the report's own fields: its rows and statuses as Socair
# wrote them, the promotion state and conditions, and the bounded statement.
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
	jq -r '
		def cell: tostring | gsub("[\r\n]+"; " ") | gsub("\\|"; "\\|") | gsub("<"; "&lt;") | gsub(">"; "&gt;") | gsub("`"; "'"'"'");
		"### Socair scan: `\(.artifact.file_name | cell)`",
		"",
		"| | |",
		"|---|---|",
		"| SHA-256 | `\(.artifact.sha256 | cell)` |",
		"| Format | \(.artifact.format // "" | cell) |",
		"| Promotion state | **\(.promotion_authorization.state // "none recorded" | cell)** |",
		"| Socair | \(.scope.tool_versions // "" | cell), check set \(.scope.check_set_version // "" | cell) |",
		"",
		"| Check | Result |",
		"|---|---|",
		(.checks[] | "| \(.name | cell) | \(.status | cell) |"),
		"",
		(.promotion_authorization.conditions // empty | cell),
		"",
		"> \(.bounded_statement // "" | cell)",
		""
	' "$report" >>"$GITHUB_STEP_SUMMARY"
fi
