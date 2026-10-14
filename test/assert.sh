#!/usr/bin/env bash
# Assertions for .github/workflows/test.yml, sourced by its check steps. Each
# prints what it checked, and on a mismatch what it expected, then fails.

# eq <what> <got> <want>
eq() {
	if [[ "$2" != "$3" ]]; then
		echo "::error::$1: got '$2', want '$3'"
		exit 1
	fi
	echo "ok: $1 is '$3'"
}

# absent <path>
absent() {
	if [[ -e "$1" ]]; then
		echo "::error::$1 exists and must not"
		exit 1
	fi
	echo "ok: $1 does not exist"
}

# present <path>
present() {
	if [[ ! -f "$1" ]]; then
		echo "::error::$1 is not a file"
		exit 1
	fi
	echo "ok: $1 exists"
}
