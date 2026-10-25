#!/usr/bin/env bash
# A new term once every node has joined, the writers still going: the leader's
# ytserv restarts, the members elect, and the cluster goes on under the new leader
# with the roster the joins built.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

l=$(leader)
[ -n "$l" ] || { bad "no leader before the new term"; finish; }
t0=$(term_of "$l")
say "-- $(now) a new term: node $l, the leader at term $t0, restarts its ytserv"
xn "$l" systemctl restart ytserver || bad "node $l: systemctl restart ytserver"

newer() {
	local n x nl
	nl=$(leader) || return 1
	x=$(term_of "$nl")
	[ -n "$x" ] && [ "$x" -gt "$t0" ] || return 1
	for n in $(members); do [ "$(term_of "$n")" = "$x" ] || return 1; done
}
if wait_for "$MIG_WAIT" newer; then
	nl=$(leader)
	ok "every node is at term $(term_of "$nl"), after $t0, led by node $nl"
else
	bad "no new term every node agrees on within ${MIG_WAIT}s"
	for n in $(members); do say "   ....  node $n: term [$(term_of "$n")] state [$(state_of "$n")]"; done
fi
leaders=0
for n in $(members); do is_state "$n" Leader && leaders=$((leaders + 1)); done
check "one leader" 1 "$leaders"
all_follow() { local n; for n in $(members); do is_state "$n" Leader || follows "$n" || return 1; done; }
wait_for 120 all_follow && ok "every other node follows" \
	|| bad "a node neither leads nor follows: $(for n in $(members); do printf '%s=%s ' "$n" "$(state_of "$n")"; done)"
finish
