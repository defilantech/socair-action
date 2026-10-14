#!/usr/bin/env bash
# Fail the job according to fail-on, from the promotion state in the report
# JSON Socair wrote (promotion_authorization.state), never from text output.
#
# fail-on lists the promotion states that fail the job, separated by spaces,
# commas, or newlines: withheld, authorized_with_conditions, escalated, or
# none alone. authorized never fails the job. A state this action does not
# know, or a report with no state, fails the job whatever fail-on says.
# The gate decides only the job's exit status: the report's promotion state
# is what Socair wrote, and nothing here changes it.
#
# Environment: FAIL_ON (the fail-on input), REPORT (the report JSON path).
set -euo pipefail

error() {
	echo "::error title=Socair promotion gate::$*"
	exit 1
}

report="${REPORT:-}"
[[ -n "$report" && -f "$report" ]] || error "no report to read the promotion state from"

read -r -a states <<<"$(printf '%s' "${FAIL_ON:-}" | tr ',\r\n\t' '    ')"
((${#states[@]} > 0)) || error "fail-on is empty: list the promotion states that fail the job (withheld, authorized_with_conditions, escalated), or none"
for s in "${states[@]}"; do
	case "$s" in
	withheld | authorized_with_conditions | escalated) ;;
	none) ((${#states[@]} == 1)) || error "fail-on: none cannot be combined with other states" ;;
	*) error "fail-on: '$s' is not one of withheld, authorized_with_conditions, escalated, or none" ;;
	esac
done

state="$(jq -r '.promotion_authorization.state // ""' "$report")"
case "$state" in
authorized)
	echo "Promotion state: authorized"
	;;
withheld | authorized_with_conditions | escalated)
	for s in "${states[@]}"; do
		[[ "$s" != "$state" ]] || error "Promotion state is $state, and fail-on includes $state. The report says why: $report"
	done
	echo "::warning title=Socair promotion gate::Promotion state is $state. fail-on does not include it, so the job continues; the report's state is unchanged."
	;;
*)
	error "The report records no promotion state this action knows ('${state}'), so the job fails whatever fail-on says"
	;;
esac
