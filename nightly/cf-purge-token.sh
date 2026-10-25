#!/usr/bin/env bash
# One time: the Cloudflare token the nightly purges the apt host's edge copies with
# (nightly.sh purge_edge), written into ../.env as CF_ZONE_ID and CF_PURGE_TOKEN.
#
#   nightly/cf-purge-token.sh            # cf, the Cloudflare CLI: sign in, create it, write it
#   nightly/cf-purge-token.sh --paste    # one made in the dashboard: the steps, then paste it
#
# The token: an account API token, "yt-cluster nightly purge", with one permission -
# Zone, Cache Purge, Purge - on one zone (CF_ZONE, default dbinvent.com). It is
# checked by a purge of a URL nothing is cached under before anything is written.
# It is never printed and never on a command line, and .env stays mode 600.
# cf: `npm install --global cf`, else npx runs the version this was written against.
# More than one account: CLOUDFLARE_ACCOUNT_ID=<id> picks the zone's.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
ENV="$(cd "$HERE/.." && pwd)/.env"
ZONE_NAME="${CF_ZONE:-dbinvent.com}"
TOKEN_NAME="yt-cluster nightly purge"
CHECK_URL="https://apt.$ZONE_NAME/cf-purge-token.check"
CF_API="${CF_API:-https://api.cloudflare.com/client/v4}"
PASTE=0
case "${1:-}" in
	--paste) PASTE=1 ;;
	"") ;;
	*) sed -n '2,13p' "$0"; exit 2 ;;
esac
die() { echo "ERROR: $*" >&2; exit 1; }

# pick <named NAME | value> < cf output: the id of the first object named NAME (and,
# for a zone, its account's id after it), or the first "value" - whatever wraps them
pick() {
	python3 -Ic '
import json, sys
mode, arg, t = sys.argv[1], (sys.argv[2:] or [None])[0], sys.stdin.read()
d = None
for i, ch in enumerate(t):
    if ch in "[{":
        try:
            d = json.JSONDecoder().raw_decode(t[i:])[0]; break
        except ValueError:
            pass
def walk(x):
    if isinstance(x, dict):
        yield x
        for v in x.values(): yield from walk(v)
    elif isinstance(x, list):
        for v in x: yield from walk(v)
for o in walk(d):
    if mode == "named" and o.get("name") == arg and isinstance(o.get("id"), str):
        print(o["id"], (o.get("account") or {}).get("id", "")); sys.exit(0)
    if mode == "value" and isinstance(o.get("value"), str):
        print(o["value"]); sys.exit(0)
sys.exit(1)' "$@"
}

# check: a purge with the token, of a URL nothing is cached under - it can, or it is not written
check() {
	local r
	r="$(printf 'header = "Authorization: Bearer %s"\n' "$CF_PURGE_TOKEN" \
		| curl -sS -m 20 -K - -X POST -H 'Content-Type: application/json' \
			--data "{\"files\": [\"$CHECK_URL\"]}" "$CF_API/zones/$CF_ZONE_ID/purge_cache" 2>&1)"
	grep -q '"success": *true' <<< "$r" && return 0
	echo "the check purge failed: $(tr -d '\n' <<< "$r" | cut -c1-300)" >&2
	return 1
}

# write: CF_ZONE_ID and CF_PURGE_TOKEN into .env, each in place of its line or
# appended; the values go by the environment, not argv
write() {
	CF_ZONE_ID="$CF_ZONE_ID" CF_PURGE_TOKEN="$CF_PURGE_TOKEN" python3 -I - "$ENV" <<'EOF'
import os, sys, tempfile
p = sys.argv[1]
want = {k: os.environ[k] for k in ("CF_ZONE_ID", "CF_PURGE_TOKEN")}
lines = open(p).read().splitlines() if os.path.exists(p) else []
out, seen = [], set()
for l in lines:
    k = l.split("=", 1)[0].strip()
    if k in want:
        if k not in seen:
            out.append(f"{k}={want[k]}"); seen.add(k)
        continue
    out.append(l)
missing = [k for k in want if k not in seen]
if missing:
    out += ["", "# the nightly's purge of the apt host's edge copies (nightly/cf-purge-token.sh)"]
    out += [f"{k}={want[k]}" for k in missing]
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(p), prefix=".env.")
with os.fdopen(fd, "w") as f:
    f.write("\n".join(out) + "\n")
os.chmod(tmp, 0o600)
os.replace(tmp, p)
EOF
}

steps() {
	cat <<EOF

In the Cloudflare dashboard (dash.cloudflare.com, signed in):

 1. Open this link - the token form, its name and permission filled in:
    https://dash.cloudflare.com/?to=/:account/api-tokens&permissionGroupKeys=%5B%7B%22key%22%3A%22cache%22%2C%22type%22%3A%22purge%22%7D%5D&name=yt-cluster%20nightly%20purge
    It is Manage account > Account API tokens > Create Token > Create Custom Token.
    Several accounts: pick the one $ZONE_NAME is in.
 2. Permission policies: Zone, Cache Purge, Purge (add it if the link did not).
    Nothing else.
 3. Resources: Specific zone, $ZONE_NAME.
 4. Continue to summary (or Review token), then Create Token.
 5. Copy the token: it is shown once.
 6. The zone ID: Account home > $ZONE_NAME > Overview, the API box at the right
    (or the "..." menu next to the zone in the list: Copy zone ID).

EOF
}

if [ "$PASTE" = 0 ]; then
	if command -v cf >/dev/null 2>&1; then CF=(cf); else CF=(npx --yes cf@1.0.0-beta.18); fi
	# a scratch directory: cf reads a .env where it runs, and keeps its cache there
	WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
	cd "$WORK" || die "no scratch directory"
	unset CLOUDFLARE_API_TOKEN   # it would take the place of the sign-in
	echo "== cf auth login: approve in the browser"
	"${CF[@]}" auth login || die "cf auth login failed - or run: $0 --paste"
	read -r CF_ZONE_ID ACCOUNT <<< "$("${CF[@]}" zones list --name "$ZONE_NAME" 2>/dev/null | pick named "$ZONE_NAME")"
	[ -n "${CF_ZONE_ID:-}" ] || die "no zone $ZONE_NAME in what cf signed in to - or run: $0 --paste"
	export CLOUDFLARE_ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-$ACCOUNT}"
	echo "   zone $ZONE_NAME: $CF_ZONE_ID (account ${CLOUDFLARE_ACCOUNT_ID:-?})"
	read -r GROUP _ <<< "$("${CF[@]}" accounts tokens permission-groups list --name "Cache Purge" 2>/dev/null | pick named "Cache Purge")"
	[ -n "${GROUP:-}" ] || die "no Cache Purge permission group listed - or run: $0 --paste"
	BODY="{\"name\": \"$TOKEN_NAME\", \"policies\": [{\"effect\": \"allow\", \"resources\": {\"com.cloudflare.api.account.zone.$CF_ZONE_ID\": \"*\"}, \"permission_groups\": [{\"id\": \"$GROUP\"}]}]}"
	echo "== creating the token \"$TOKEN_NAME\": Cache Purge on $ZONE_NAME"
	CF_PURGE_TOKEN="$("${CF[@]}" accounts tokens create --body "$BODY" 2>/dev/null | pick value)" \
		|| die "no token in cf's answer - if the dashboard lists \"$TOKEN_NAME\", delete it; then: $0 --paste"
else
	steps
	read -r -p "Zone ID of $ZONE_NAME: " CF_ZONE_ID
	read -r -s -p "Token (not shown): " CF_PURGE_TOKEN; echo
	[ -n "$CF_ZONE_ID" ] && [ -n "$CF_PURGE_TOKEN" ] || die "both are needed"
fi

echo "== checking it: a purge of $CHECK_URL"
check || die "nothing written - the token stays in the dashboard; delete it there if it is no use"
write || die "could not write $ENV"
echo "== written to $ENV: CF_ZONE_ID=$CF_ZONE_ID, CF_PURGE_TOKEN (not shown)"
