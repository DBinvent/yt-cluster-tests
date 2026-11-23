#!/usr/bin/env bash
# [labac] The identity provider's side: the realm, the client the people sign in through, the
# client scope that puts a person's groups into the id_token (FerrisKey says none unless a mapper
# is set: `groups`, each as its path - /dept/sales), the organization with its group tree, and
# the people, each in its groups (LX_GROUPS and LX_PEOPLE of env.sh). Their ids are kept in the
# run's folder for 60_regroup.sh.
cd "$(dirname "$0")"
source ./env.sh
labac_urls
fk_admin

echo "== the realm $LX_REALM =="
# a realm of that name left from before goes first: its people and groups with it
curl -s -m 20 -o /dev/null -X DELETE -H @"$LX_RUN/fk.auth" "$FK_URL/realms/$LX_REALM" || true
fk POST /realms "{\"name\":\"$LX_REALM\"}" >/dev/null
R="/realms/$LX_REALM"

echo "== the client scope groups: a person's groups in its tokens =="
scope="$(fk POST "$R/client-scopes" '{"name":"groups","protocol":"openid-connect","is_default":true}' | jv id)"
fk POST "$R/client-scopes/$scope/protocol-mappers" '{"name":"groups","mapper_type":"oidc-group-membership-mapper",
	"config":{"claim.name":"groups","id.token.claim":"true","access.token.claim":"true"}}' >/dev/null

echo "== the client $LX_CLIENT: public, the password grant on (a script signs in, no browser) =="
client="$(fk POST "$R/clients" "{\"client_id\":\"$LX_CLIENT\",\"name\":\"$LX_CLIENT\",\"client_type\":\"public\",
	\"public_client\":true,\"direct_access_grants_enabled\":true,\"enabled\":true,\"protocol\":\"openid-connect\"}" | jv id)"
# the scope among the client's defaults: asked for or not, its tokens say the groups. A client
# made after a default scope may have it already
curl -s -m 20 -o /dev/null -X PUT -H @"$LX_RUN/fk.auth" "$FK_URL$R/clients/$client/default-client-scopes/$scope" || true

echo "== the organization $LX_ORG and its groups =="
org="$(fk POST "$R/organizations" "{\"alias\":\"$LX_ORG\",\"name\":\"$LX_ORG\"}" | jv id)"
: > "$LX_RUN/fk.ids"
echo "org=$org" >> "$LX_RUN/fk.ids"
declare -A gid
for g in "${LX_GROUPS[@]}"; do
	parent="${g%/*}"; name="${g##*/}"
	if [ "$parent" = "$g" ]; then
		body="{\"name\":\"$name\"}"
	else
		body="{\"name\":\"$name\",\"parent_group_id\":\"${gid[$parent]}\"}"
	fi
	gid[$g]="$(fk POST "$R/organizations/$org/groups" "$body" | jv id)"
	echo "group:$g=${gid[$g]}" >> "$LX_RUN/fk.ids"
done
echo "  ${#gid[@]} groups"

echo "== the people =="
for line in "${LX_PEOPLE[@]}"; do
	read -r user groups <<<"$line"
	uid="$(fk POST "$R/users" "{\"username\":\"$user\",\"email\":\"$user@example.test\",\"email_verified\":true,
		\"firstname\":\"$user\",\"lastname\":\"test\"}" | jv data.id)"
	fk PUT "$R/users/$uid/reset-password" "{\"credential_type\":\"password\",\"temporary\":false,\"value\":\"$LABAC_USER_PW\"}" >/dev/null
	fk POST "$R/organizations/$org/members" "{\"user_id\":\"$uid\"}" >/dev/null
	for g in $groups; do
		fk POST "$R/organizations/$org/groups/${gid[$g]}/members" "{\"user_id\":\"$uid\"}" >/dev/null
	done
	echo "user:$user=$uid" >> "$LX_RUN/fk.ids"
	echo "  $user: ${groups:-no group}"
done

echo "== what FerrisKey says of a person: the id_token's groups =="
got="$(id_token alice | claims | jv groups)"
# a member of a group is said to be in its parents too: signon's rules match the whole path
check "alice's id_token names her groups, each by its path, and their parents" \
	'["/clearance", "/clearance/2", "/dept", "/dept/sales", "/review", "/review/1"]' \
	"$(printf '%s' "$got" | python3 -c 'import json, sys; print(json.dumps(sorted(json.load(sys.stdin))))')"
check "erin, in no group, signs in and has none" '[]' "$(id_token erin | claims | jv groups)"
summary
