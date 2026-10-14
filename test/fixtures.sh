#!/usr/bin/env bash
# Write the test fixtures. Nothing is downloaded: the model is a safetensors
# file of one 2x2 F32 tensor, written here.
#
#   <models>/withheld/tiny.safetensors     the model, scanned with no inputs
#   <models>/authorized/tiny.safetensors   the same bytes, scanned with <refs>
#   <models>/conditions/                   a model directory of the same bytes
#   <refs>/                                reference inputs that move every row
#                                          of the authorized scan to PASS, as
#                                          Socair's docs/provenance-bundle.md
#                                          describes: a repository mirror, a
#                                          denylist that does not list the
#                                          model, and a provenance manifest
#                                          bound to its hash
#
#   test/fixtures.sh <models> <refs>
set -euo pipefail

models="${1:?usage: test/fixtures.sh <models> <refs>}"
refs="${2:?usage: test/fixtures.sh <models> <refs>}"
mkdir -p "$models/withheld" "$models/authorized" "$models/conditions" "$refs/mirror"

python3 - "$models/withheld/tiny.safetensors" <<'EOF'
import json, struct, sys

# An 8-byte little-endian header length, the JSON header padded with spaces
# to a multiple of 8 bytes, then the tensor's 16 bytes of data.
header = json.dumps(
    {"weight": {"dtype": "F32", "shape": [2, 2], "data_offsets": [0, 16]}},
    separators=(",", ":"),
).encode()
header += b" " * (-len(header) % 8)
with open(sys.argv[1], "wb") as f:
    f.write(struct.pack("<Q", len(header)))
    f.write(header)
    f.write(struct.pack("<4f", 1.0, 2.0, 3.0, 4.0))
EOF

cp "$models/withheld/tiny.safetensors" "$models/authorized/tiny.safetensors"
cp "$models/withheld/tiny.safetensors" "$models/conditions/model.safetensors"
printf '{"architectures": ["Test"]}\n' >"$models/conditions/config.json"

sha="$(python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$models/authorized/tiny.safetensors")"

cp "$models/authorized/tiny.safetensors" "$refs/mirror/"
printf '{"architectures": ["Test"]}\n' >"$refs/mirror/config.json"
printf '# no entry here is the fixture\n%s  unrelated-entry\n' \
	0000000000000000000000000000000000000000000000000000000000000000 >"$refs/denylist.txt"
cat >"$refs/provenance.json" <<EOF
{
  "artifact_sha256": "$sha",
  "publisher": "socair-action-test",
  "signing_status": "unsigned",
  "repo_url": "https://example.invalid/socair-action-test/tiny",
  "commit_or_tag": "main",
  "commit_sha": "0123456789abcdef0123456789abcdef01234567"
}
EOF

echo "wrote the fixtures; the model's sha256 is $sha"
