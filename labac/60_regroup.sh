#!/usr/bin/env bash
# [labac] A person's groups change at the identity provider. signon hears of it at the person's
# next sign-in: the rules map the new groups, the subject's version moves, a new token is for
# the new access - and the token from before is of an older subject: refused. Needs
# 40_login.sh's tokens.
cd "$(dirname "$0")"
source ./env.sh
labac_urls
fk_admin
id_of() { sed -n "s|^$1=||p" "$LX_RUN/fk.ids"; }
R="/realms/$LX_REALM/organizations/$(id_of org)/groups"
said() { python3 -c 'import json, sys
status, _, body = sys.stdin.read().partition(" ")
d = json.loads(body)
open(sys.argv[1], "w").write(d.get("token", ""))
print(status, json.dumps(d.get("levels"), sort_keys=True), ",".join(sorted(d.get("groups", []))))' "$1"; }
q() { sqlp "$1" "$LX_RUN/$2.token" <<<"$3"; }
# stale <mode> <person>: the token's statement is refused for its subject (28000), nothing read
stale() { q "$1" "$2" "SELECT id FROM projects ORDER BY 1" | grep -q '28000' && echo refused || q "$1" "$2" "SELECT id FROM projects ORDER BY 1"; }

echo "== alice is cleared higher: from clearance/2 to clearance/3 =="
alice="$(id_of user:alice)"
fk DELETE "$R/$(id_of group:clearance/2)/members/$alice" >/dev/null
fk POST "$R/$(id_of group:clearance/3)/members" "{\"user_id\":\"$alice\"}" >/dev/null
for mode in lsr rls; do
	check "$mode: until she signs in again her token is the access she signed in with" "1" "$(q "$mode" alice "SELECT id FROM projects ORDER BY 1")"
done
cp "$LX_RUN/alice.token" "$LX_RUN/alice-before.token"
check "she signs in again: the level 3" '200 {"review": 1, "sal": 3} dept-sales' "$(login alice | said "$LX_RUN/alice.token")"
for mode in lsr rls; do
	check "$mode: the new token reaches the secret project" "1 2" "$(q "$mode" alice "SELECT id FROM projects ORDER BY 1")"
done
sleep 5   # ytproxy reads signon again every refresh_sec (2)
for mode in lsr rls; do
	check "$mode: the token from before is of an older subject" "refused" "$(stale "$mode" alice-before)"
done

echo "== dave leaves hr =="
dave="$(id_of user:dave)"
fk DELETE "$R/$(id_of group:dept/hr)/members/$dave" >/dev/null
cp "$LX_RUN/dave.token" "$LX_RUN/dave-before.token"
check "he signs in again: sales alone" '200 {"sal": 1} dept-sales' "$(login dave | said "$LX_RUN/dave.token")"
for mode in lsr rls; do
	check "$mode: hr's tasks are his no more" "100" "$(q "$mode" dave "SELECT id FROM tasks ORDER BY 1")"
done
sleep 5
for mode in lsr rls; do
	check "$mode: nor through the token from before" "refused" "$(stale "$mode" dave-before)"
done

echo "== carol leaves every group =="
carol="$(id_of user:carol)"
for g in reviewers clearance/3 review/3; do fk DELETE "$R/$(id_of "group:$g")/members/$carol" >/dev/null; done
cp "$LX_RUN/carol.token" "$LX_RUN/carol-before.token"
check "she signs in again: no way in" "403 no_subject" \
	"$(login carol | python3 -c 'import json, sys
status, _, body = sys.stdin.read().partition(" ")
print(status, json.loads(body).get("error"))')"
sleep 5
for mode in lsr rls; do
	check "$mode: her token from before is refused" "refused" "$(stale "$mode" carol-before)"
done
summary
