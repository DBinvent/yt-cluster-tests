#!/usr/bin/env bash
# [bson] The extension's BSON functions on a running node: yt_diff_apply_bson,
# yt_bson_to_json, yt_bson_from_json - a DocumentDB / MongoDB document as bytea, patched
# by a diff-doc-rs diff, its types beyond JSON's as extended JSON. Their own assertions
# are YT Cluster's ytpgc/test_bson.sql (each SELECT one `t`); this runs that file as the
# package installed it, in the node's database.
#
# Written 2026-10-29 without a run (no e2e on the shared lab hosts that day); its first
# run is the next nightly.
#
#   B1  the three functions are in the node's extension
#   B2  every assertion of test_bson.sql is true: the mapping both ways, two disjoint
#       patches in either order to the same bytes, a patch in place by an UPDATE, the
#       errors - and the file ran to its end, no error
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== bson: the extension's BSON functions on a node =="

SQL="$LITE_ROOT/ytpgc/test_bson.sql"
[ -f "$SQL" ] || { bad "no $SQL (is the extension's source next to the tests?)"; summary; }
N="${NODES[0]}"

check "B1 the BSON functions are in the extension on $N" "3" \
	"$(q "$N" "select count(*) from pg_proc where proname in ('yt_diff_apply_bson', 'yt_bson_to_json', 'yt_bson_from_json')")"

want="$(grep -c "AS bson_" "$SQL")"
# -q: no command tags; -tA: each assertion's `t` alone on its line; ON_ERROR_STOP: an
# error ends the file - it never reaches its last \echo
out="$(rh "docker exec -i -u postgres $N psql -X -q -tA -v ON_ERROR_STOP=1 -d $YX_DB" < "$SQL" 2>&1 || true)"
check "B2 the file ran to its end" "1" "$(printf '%s\n' "$out" | grep -c '^=== done ===$')"
check "B2 every assertion is true ($want of them)" "$want" "$(printf '%s\n' "$out" | grep -cx 't')"
falses="$(printf '%s\n' "$out" | grep -cx 'f' || true)"
check "B2 none is false" "0" "$falses"
if [ "$falses" != "0" ] || ! printf '%s\n' "$out" | grep -q '^=== done ===$'; then
	printf '%s\n' "$out" | grep -v '^t$' | head -20 | sed 's/^/     /'
fi

summary
