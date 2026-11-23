#!/usr/bin/env bash
# [labac] The sign-in, person by person: at FerrisKey for an id_token, then at the host program,
# which checks it, maps the person's groups by signon's rules and answers its labac token. What
# the rules made of each person is checked here; the tokens are kept in the run's folder for
# 50_queries.sh.
cd "$(dirname "$0")"
source ./env.sh
labac_urls

# said <token file or -> : the host's answer on stdin, "<status> <body>", as one line -
# "<status> <groups> <pg roles> <levels> <tops>", the token saved - or "<status> <error>"
said() {
	python3 -c 'import json, sys
status, _, body = sys.stdin.read().partition(" ")
try:
    d = json.loads(body)
except ValueError:
    d = {}
if "token" in d:
    if sys.argv[1] != "-":
        open(sys.argv[1], "w").write(d["token"])
    print(status, ",".join(sorted(d["groups"])) or "-", ",".join(d["pg_roles"]) or "-",
          json.dumps(d["levels"], sort_keys=True), json.dumps(d["tops"], sort_keys=True))
else:
    print(status, d.get("error", body.strip()))' "$1"
}

echo "== each person signs in: FerrisKey's groups to signon's subject =="
check "alice: a member of sales, cleared for 2, review 1" \
	'200 dept-sales labac_staff {"review": 1, "sal": 2} {}' "$(login alice | said "$LX_RUN/alice.token")"
check "bob: a member of eng, cleared for 4, review 2" \
	'200 dept-eng labac_staff {"review": 2, "sal": 4} {}' "$(login bob | said "$LX_RUN/bob.token")"
check "carol: a reviewer, cleared for 3, review 3" \
	'200 reviewers labac_staff {"review": 3, "sal": 3} {}' "$(login carol | said "$LX_RUN/carol.token")"
check "dave: a member of sales and of hr, cleared for 1" \
	'200 dept-hr,dept-sales labac_staff {"sal": 1} {}' "$(login dave | said "$LX_RUN/dave.token")"
check "frank: a member of sales, no level" \
	'200 dept-sales labac_staff {} {}' "$(login frank | said "$LX_RUN/frank.token")"
check "erin, in no group: signed in at FerrisKey, no way in here" '403 no_subject' "$(login erin | said -)"

echo "== a token for a level =="
check "bob asks a token for the level 1: its top" \
	'200 dept-eng labac_staff {"review": 2, "sal": 4} {"sal": 1}' "$(login bob level=1 | said "$LX_RUN/bob-l1.token")"
check "by name: review 1" \
	'200 dept-eng labac_staff {"review": 2, "sal": 4} {"review": 1}' "$(login bob level.review=1 | said -)"
check "alice asks above her own: refused" '403 level' "$(login alice level=3 | said -)"
check "a level of a name he has none of: refused" '403 level' "$(login frank level=1 | said -)"

echo "== what is no id_token of this realm's client =="
post() { # post <file>: its text to the host's /login
	curl -sS -m 20 -o "$LX_RUN/login.out" -w '%{http_code}' -X POST -H 'Content-Type: text/plain' --data-binary @"$1" "$HOST_URL/login"
	echo " $(cat "$LX_RUN/login.out")"
}
printf 'not.a.token' > "$LX_RUN/bad.token"
check "a text that is no token" '401 id_token' "$(post "$LX_RUN/bad.token" | said -)"
# FerrisKey's own administrator, of its master realm: a good token of another issuer
curl -sS -m 20 -X POST "$FK_URL/realms/master/protocol/openid-connect/token" -d grant_type=password -d client_id=admin-cli \
	-d username=admin -d password=admin | jv id_token > "$LX_RUN/bad.token"
check "an id_token of another realm" '401 id_token' "$(post "$LX_RUN/bad.token" | said -)"
# alice's own, one character of its signature changed
id_token alice | python3 -c 'import sys
t = sys.stdin.read().strip()
print(t[:-3] + ("A" if t[-3] != "A" else "B") + t[-2:], end="")' > "$LX_RUN/bad.token"
check "an id_token with another signature" '401 id_token' "$(post "$LX_RUN/bad.token" | said -)"
rm -f "$LX_RUN/bad.token"
summary
