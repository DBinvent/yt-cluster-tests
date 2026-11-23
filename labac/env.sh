#!/usr/bin/env bash
# [labac] Shared settings of the labac login environment. Source, do not execute.
#
# People sign in at an identity provider (FerrisKey, OIDC), which says the groups each is in;
# signon's labac maps the groups to what a person may reach; ytproxy lets each person see the
# rows that follows from - by rewriting the SQL (lsr) or by PostgreSQL's row-level security
# (rls). Everything runs in containers on the docker host (YX_HOST of ../.env):
#
#   labac-pg     PostgreSQL: the databases of FerrisKey and signon, and the test schema twice -
#                app_lsr (deployed under lsr) and app_rls (under rls)
#   labac-fk     FerrisKey, its API published on LABAC_FK_PORT
#   labac-etcd   etcd: the schema map ytproxy reads the covered tables and their keys from
#   labac-host   host/ - signon behind the provider's sign-in, published on LABAC_HOST_PORT
#   labac-lsr    ytproxy, [security] mode = "lsr", over app_lsr
#   labac-rls    ytproxy, [security] mode = "rls", over app_rls
set -euo pipefail

LABAC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$LABAC_ROOT/.." && pwd)"
# Settings: yt-cluster-tests/.env (not committed, see env.example). A variable already set in
# the environment wins over it.
if [ -f "$TESTS_ROOT/.env" ]; then
	_yx_keep="$(export -p)"; set -a; . "$TESTS_ROOT/.env"; set +a; eval "$_yx_keep"; unset _yx_keep
fi
YX_HOST="${YX_HOST:-local}"          # where the containers run: an ssh target, or local

# The checkouts the binaries are built from, here: ytproxy (YTPROXY, or a sibling of this
# repository) and host/ (its signon and schema_guard come from crates.io, or - until the
# versions it needs are published - from the siblings a local host/.cargo/config.toml names).
YTPROXY_ROOT="${YTPROXY:-$(cd "$TESTS_ROOT/.." && pwd)/ytproxy}"
LX_YTPROXY_BIN="$YTPROXY_ROOT/target/release/ytproxy"
LX_HOST_BIN="$LABAC_ROOT/host/target/release/labac-host"

LX_NET="${LABAC_NET:-yxlabac}"
LX_PG=labac-pg; LX_FK=labac-fk; LX_ETCD=labac-etcd; LX_HOSTC=labac-host; LX_LSR=labac-lsr; LX_RLS=labac-rls
LX_ALL=("$LX_LSR" "$LX_RLS" "$LX_HOSTC" "$LX_ETCD" "$LX_FK" "$LX_PG")
LABAC_PG_IMAGE="${LABAC_PG_IMAGE:-postgres:18.2}"
# FerrisKey: tested with 0.10.0
LABAC_FK_IMAGE="${LABAC_FK_IMAGE:-ghcr.io/ferriskey/ferriskey-api:latest}"
LABAC_ETCD_IMAGE="${LABAC_ETCD_IMAGE:-quay.io/coreos/etcd:v3.5.21}"
# what ytproxy and labac-host run in: the release of the machine that builds them (their libc)
LABAC_BASE_IMAGE="${LABAC_BASE_IMAGE:-ubuntu:24.04}"
# the ports published on the docker host
LABAC_FK_PORT="${LABAC_FK_PORT:-13333}"
LABAC_HOST_PORT="${LABAC_HOST_PORT:-13380}"

# The fixture's names and its throwaway passwords: of containers that live for one run.
LX_REALM=labac
LX_CLIENT=labac-env
LX_ORG=acme
LABAC_USER_PW="${LABAC_USER_PW:-Labac-env-2026-pass!}"     # every test person's, at FerrisKey
LX_PG_PW=labac-pg-pw            # postgres, the superuser of labac-pg
LX_APP_USER=app                 # the application's login at ytproxy and at the node
LX_APP_PW=labac-app-pw
LX_STAFF_ROLE=labac_staff       # the PostgreSQL role signon's rules give a person
LX_STAFF_PW=labac-staff-pw
LX_CLUSTER=7a1c0000-0000-5000-8000-0000000000ac   # the schema map's cluster id

# The groups at FerrisKey, as paths - a parent before its children - and the people in them.
# dept/<d>: a department's member; clearance/<n>: the security access level (sal) <n>;
# review/<n>: the level `review` <n>; reviewers: reads every department.
LX_GROUPS=(dept dept/sales dept/eng dept/hr clearance clearance/1 clearance/2 clearance/3 clearance/4
	review review/1 review/2 review/3 reviewers)
LX_PEOPLE=(
	"alice dept/sales clearance/2 review/1"
	"bob dept/eng clearance/4 review/2"
	"carol reviewers clearance/3 review/3"
	"dave dept/sales dept/hr clearance/1"
	"erin"
	"frank dept/sales"
)

# This run's files - the keys, the tokens, FerrisKey's ids: nothing of them is kept.
LX_RUN="${LABAC_RUN:-${TMPDIR:-/tmp}/yxlabac-$(id -un)}"
mkdir -p "$LX_RUN"; chmod 700 "$LX_RUN"

# ssh to the docker host over one shared connection (as ../topology/env.sh).
YX_SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8)
if [ "${YX_SSH_MUX:-1}" = 1 ]; then
	YX_SSH+=(-o ControlMaster=auto -o "ControlPath=${XDG_RUNTIME_DIR:-/tmp}/yx-ssh-%C"
		-o ControlPersist=120 -o ServerAliveInterval=30)
fi
# Run a command on the docker host.
rh() {
	if [ "$YX_HOST" = "local" ]; then bash -c "$*"; else
		"${YX_SSH[@]}" "$YX_HOST" "$*"; fi
}
# rhi <command>: the same, named for the calls whose stdin is the command's (a file, SQL)
rhi() { rh "$@"; }

# The docker host's address as this machine reaches its published ports: LABAC_ADDR, else the
# loopback for a local host, else the first address the host says of itself.
labac_addr() {
	if [ -z "${LABAC_ADDR:-}" ]; then
		if [ "$YX_HOST" = "local" ]; then LABAC_ADDR=127.0.0.1; else
			LABAC_ADDR="$(rh "hostname -I" | awk '{print $1}')"; fi
		[ -n "$LABAC_ADDR" ] || { echo "labac: no address of the docker host - set LABAC_ADDR" >&2; return 1; }
	fi
	echo "$LABAC_ADDR"
}
# FerrisKey's and the host program's URLs from here, and the realm's issuer: what FerrisKey
# writes into a token is the URL it was asked at, so every sign-in goes through this one.
labac_urls() {
	local a; a="$(labac_addr)"
	FK_URL="http://$a:$LABAC_FK_PORT"
	HOST_URL="http://$a:$LABAC_HOST_PORT"
	LX_ISSUER="$FK_URL/realms/$LX_REALM"
}

# put_file <container> <file> <directory in it>: the file into a container, created or running
put_file() {
	tar -C "$(dirname "$2")" -cf - "$(basename "$2")" | rhi "docker cp - $1:$3"
}

# pg <db> : SQL from stdin on labac-pg as its superuser - the setup's own; -tA, stops at an error
pg() {
	rhi "docker exec -i -e PGPASSWORD=$LX_PG_PW $LX_PG psql -U postgres -h 127.0.0.1 -d $1 -tAq -v ON_ERROR_STOP=1"
}

# jv <a.b.0.c>: that value of the JSON on stdin
jv() {
	python3 -c 'import json, sys
d = json.load(sys.stdin)
for k in sys.argv[1].split("."):
    d = d[int(k)] if isinstance(d, list) else d[k]
print(d if not isinstance(d, (dict, list)) else json.dumps(d, sort_keys=True))' "$1"
}

# fk <METHOD> <path> [json]: a call of FerrisKey's API as its administrator (fk_admin first):
# the answer's body; a status that is no 2xx fails, saying what FerrisKey said
fk() {
	local method="$1" path="$2" out="$LX_RUN/fk.out" code
	if [ $# -ge 3 ]; then
		code="$(curl -sS -m 20 -o "$out" -w '%{http_code}' -X "$method" -H @"$LX_RUN/fk.auth" \
			-H 'Content-Type: application/json' --data-binary "$3" "$FK_URL$path")"
	else
		code="$(curl -sS -m 20 -o "$out" -w '%{http_code}' -X "$method" -H @"$LX_RUN/fk.auth" "$FK_URL$path")"
	fi
	case "$code" in
		2*) cat "$out" ;;
		*) echo "FerrisKey $method $path: $code $(head -c 400 "$out")" >&2; return 1 ;;
	esac
}
# the administrator's token (the master realm's first account), good for five minutes
fk_admin() {
	local t
	t="$(curl -sS -m 20 -X POST "$FK_URL/realms/master/protocol/openid-connect/token" \
		-d grant_type=password -d client_id=admin-cli -d username=admin -d password=admin | jv access_token)"
	[ -n "$t" ] || { echo "FerrisKey: no administrator token" >&2; return 1; }
	( umask 077; printf 'Authorization: Bearer %s\n' "$t" > "$LX_RUN/fk.auth" )
}

# id_token <user>: the person signs in at FerrisKey (the OIDC password grant: a script has no
# browser) - its id_token, or nothing
id_token() {
	curl -sS -m 20 -X POST "$LX_ISSUER/protocol/openid-connect/token" \
		-d grant_type=password -d "client_id=$LX_CLIENT" -d "username=$1" \
		--data-urlencode "password=$LABAC_USER_PW" -d 'scope=openid profile email' \
		| python3 -c 'import json, sys; print(json.load(sys.stdin).get("id_token", ""))'
}
# claims: the payload of the JWT on stdin, as JSON
claims() {
	python3 -c 'import base64, sys
p = sys.stdin.read().strip().split(".")[1]
print(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)).decode())'
}
# login <user> [query]: the id_token to the host program - "<status> <body>" of its answer
login() {
	local t; t="$(id_token "$1")"
	[ -n "$t" ] || { echo "000 no id_token"; return 0; }
	printf '%s' "$t" > "$LX_RUN/id.token"
	curl -sS -m 20 -o "$LX_RUN/login.out" -w '%{http_code}' -X POST -H 'Content-Type: text/plain' \
		--data-binary @"$LX_RUN/id.token" "$HOST_URL/login${2:+?$2}"
	echo " $(cat "$LX_RUN/login.out")"
}

# sqlp <lsr|rls> <token file or -> : SQL from stdin through that ytproxy, as the application's
# login, the person's token entered first (-: none). Rows as psql -tA prints them, on one line;
# an error as its SQLSTATE.
sqlp() {
	local mode="$1" token="$2" proxy db
	if [ "$mode" = lsr ]; then proxy="$LX_LSR"; db=app_lsr; else proxy="$LX_RLS"; db=app_rls; fi
	local out
	out="$({
		# psql says this once it is connected and reads the script: without it nothing ran - ssh, docker
		# or the proxy failed - and that is no empty result
		echo '\echo labac-ran'
		echo '\set VERBOSITY sqlstate'
		[ "$token" = - ] || echo "SET labac.token = '$(cat "$token")';"
		cat
	} | rhi "docker exec -i -e PGPASSWORD=$LX_APP_PW $LX_PG psql -h $proxy -p 6432 -U $LX_APP_USER -d $db -tAq 2>&1" \
		| grep -v '^SET$' | paste -sd' ' - | tr -s ' ')" || true
	case "$out" in
		labac-ran) echo "" ;;
		"labac-ran "*) echo "${out#labac-ran }" ;;
		*) echo "NOT RUN: $out" ;;
	esac
}

pass=0; fail=0
ok()   { echo "  OK   $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL $1"; fail=$((fail+1)); }
# check <description> <expected> <actual>
check() {
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 - expected [$2] got [$3]"; fi
}
summary() {
	echo "  ---- $pass passed, $fail failed ----"
	[ "$fail" -eq 0 ] || exit 1
}
