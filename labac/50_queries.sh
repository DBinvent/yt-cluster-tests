#!/usr/bin/env bash
# [labac] Every person against every table, through ytproxy in both modes: the same statement
# gives the same rows whether ytproxy rewrote it (lsr, over app_lsr) or PostgreSQL's row-level
# security filtered it (rls, over app_rls). The expected rows are worked out by hand from
# data.sql, signon.json and the people's groups (env.sh):
#
#   alice  sales (select, insert, update, soft delete), sal 2, review 1
#   bob    eng (the same),                               sal 4, review 2
#   carol  every department (select only),               sal 3, review 3
#   dave   sales (to soft delete) and hr (to delete),    sal 1, no review level
#   frank  sales,                                        no level
#
# The rules they show:
# - a row's department must be one of the person's for the statement's action;
# - a table that declares a level is reached at that level or higher - a row with no level counts
#   as 0, a person with no level reaches none of it;
# - a hidden parent denies: a row that follows a path through another covered table (a task, its
#   project) is reached only when that table's row is read - also by the levels the row's own
#   table does not declare.
# A write that is let is rolled back: every run and both modes see the same rows. Needs
# 40_login.sh's tokens.
cd "$(dirname "$0")"
source ./env.sh
for p in alice bob carol dave frank bob-l1; do
	[ -s "$LX_RUN/$p.token" ] || { echo "no token of $p - run 40_login.sh" >&2; exit 1; }
done

# q <person> <sql>: the statement as that person, through the ytproxy of $mode
q() { sqlp "$mode" "$LX_RUN/$1.token" <<<"$2"; }
# rows <description> <expected> <person> <sql>
rows() { check "$mode $3: $1" "$2" "$(q "$3" "$4")"; }
REFUSED="ERROR: 42501"

for mode in lsr rls; do
	echo "== $mode: what each person reads =="
	rows "projects - her department's, at her level"            "1"                   alice "SELECT id FROM projects ORDER BY 1"
	rows "projects - his department's, every level"             "3 4"                 bob   "SELECT id FROM projects ORDER BY 1"
	rows "projects - every department, below the top secret"    "1 2 3 5 6"           carol "SELECT id FROM projects ORDER BY 1"
	rows "projects - both his departments', at his level"       "1 5 6"               dave  "SELECT id FROM projects ORDER BY 1"
	rows "projects - his department's, but no level: none"      ""                    frank "SELECT id FROM projects ORDER BY 1"
	rows "docs - the project's department and level, her review level" "10"           alice "SELECT id FROM docs ORDER BY 1"
	rows "docs"                                                 "30 40"               bob   "SELECT id FROM docs ORDER BY 1"
	rows "docs - 40 is of a top secret project"                 "10 11 20 30 50 60"   carol "SELECT id FROM docs ORDER BY 1"
	rows "docs - no review level: none"                         ""                    dave  "SELECT id FROM docs ORDER BY 1"
	rows "docs"                                                 ""                    frank "SELECT id FROM docs ORDER BY 1"
	rows "tasks - 101 is of a project above her level: a hidden parent denies" "100"   alice "SELECT id FROM tasks ORDER BY 1"
	rows "tasks"                                                "102 105"             bob   "SELECT id FROM tasks ORDER BY 1"
	rows "tasks - 101 is of the project above his level"        "100 103 104"         dave  "SELECT id FROM tasks ORDER BY 1"
	rows "tasks - he reads no project, so none of their tasks"  ""                    frank "SELECT id FROM tasks ORDER BY 1"
	rows "notices - by level alone"                             "1 2 5"               alice "SELECT id FROM notices ORDER BY 1"
	rows "notices"                                              "1 2 3 4 5"           bob   "SELECT id FROM notices ORDER BY 1"
	rows "notices"                                              "1 2 3 5"             carol "SELECT id FROM notices ORDER BY 1"
	rows "notices"                                              "1 5"                 dave  "SELECT id FROM notices ORDER BY 1"
	rows "notices"                                              ""                    frank "SELECT id FROM notices ORDER BY 1"
	# select on every department leaves the department's compare out, not the path: the project
	# is still read, so 105 - of the top secret project carol does not read - is hidden from her too
	rows "tasks - every department, and a hidden parent denies"  "100 101 102 103 104" carol "SELECT id FROM tasks ORDER BY 1"

	echo "== $mode: in a join, a subquery, an aggregate, a union =="
	rows "a join of two covered tables"   "10"    alice "SELECT d.id FROM docs d JOIN projects p ON p.id = d.project_id ORDER BY 1"
	rows "a subquery"                     "102"   bob   "SELECT id FROM tasks WHERE project_id IN (SELECT id FROM projects WHERE sal < 4) ORDER BY 1"
	rows "a count"                        "6"     carol "SELECT count(*) FROM docs"
	rows "a union"                        "1 5 6 100 103 104" dave "SELECT id FROM tasks UNION SELECT id FROM projects ORDER BY 1"

	echo "== $mode: writes, by the action's level =="
	rows "an insert into her department, at her level" "7" alice \
		"BEGIN; INSERT INTO projects (id, dept, sal, name) VALUES (7, 'sales', 2, 'new') RETURNING id; ROLLBACK;"
	rows "into another department: refused" "$REFUSED" alice \
		"INSERT INTO projects (id, dept, sal, name) VALUES (7, 'eng', 1, 'new') RETURNING id"
	rows "above her level: refused" "$REFUSED" alice \
		"INSERT INTO projects (id, dept, sal, name) VALUES (7, 'sales', 3, 'new') RETURNING id"
	rows "an update reaches her rows only" "1" alice \
		"BEGIN; UPDATE projects SET name = 'renamed' WHERE id IN (1, 2, 3) RETURNING id; ROLLBACK;"
	rows "a row is not raised above her level" "$REFUSED" alice \
		"UPDATE projects SET sal = 3 WHERE id = 1 RETURNING id"
	rows "a reviewer reads, and updates nothing" "" carol \
		"BEGIN; UPDATE projects SET name = 'renamed' RETURNING id; ROLLBACK;"
	rows "a soft delete, with the soft delete level" "10" alice \
		"BEGIN; UPDATE docs SET deleted_at = now() WHERE id = 10 RETURNING id; ROLLBACK;"
	rows "a soft delete, by a reviewer: nothing" "" carol \
		"BEGIN; UPDATE docs SET deleted_at = now() WHERE id = 10 RETURNING id; ROLLBACK;"
	rows "a delete needs the delete level: sales gives her none" "" alice \
		"BEGIN; DELETE FROM tasks WHERE id = 100 RETURNING id; ROLLBACK;"
	rows "hr gives him the delete level, sales does not" "103" dave \
		"BEGIN; DELETE FROM tasks WHERE id IN (100, 103) RETURNING id; ROLLBACK;"
	# The one place the modes answer differently: a statement refused inside an open transaction.
	# Under rls the database refuses it - an ERROR, the transaction is aborted, the session goes
	# on. Under lsr ytproxy refuses it, and a refusal of its own inside a transaction ends the
	# session (FATAL). Refused, with 42501, in both.
	got="$(q alice "BEGIN; INSERT INTO projects (id, dept, sal, name) VALUES (7, 'eng', 1, 'new') RETURNING id; ROLLBACK;")"
	if [ "$mode" = lsr ]; then
		check "lsr alice: refused inside a transaction - the session ends with it" "FATAL: 42501" "${got:0:12}"
	else
		check "rls alice: refused inside a transaction - the transaction ends with it" "$REFUSED" "$got"
	fi

	echo "== $mode: the level a session works at =="
	rows "a token for the level 1: its top"         "1 5"       bob-l1 "SELECT id FROM notices ORDER BY 1"
	rows "the session asks lower"                   "1 2 5"     bob    "SET labac.level = 2; SELECT id FROM notices ORDER BY 1"
	rows "and back to his own"                      "1 2 3 4 5" bob    "SET labac.level = 2; RESET labac.level; SELECT id FROM notices ORDER BY 1"
	rows "by name: the review level"                "30"        bob    "SET labac.level.review = 1; SELECT id FROM docs ORDER BY 1"
	rows "lower hides the tasks of the projects above" "102"    bob    "SET labac.level = 2; SELECT id FROM tasks ORDER BY 1"
	rows "above his own: refused, his own stands"   "$REFUSED 1 2 3 4 5" bob "SET labac.level = 5; SELECT id FROM notices ORDER BY 1"
	rows "above the token's top: refused"           "$REFUSED 1 5" bob-l1 "SET labac.level = 3; SELECT id FROM notices ORDER BY 1"

	echo "== $mode: no person, no row =="
	check "$mode: the application's login alone, no token entered" "$REFUSED" "$(echo "SELECT id FROM projects" | sqlp "$mode" -)"
	printf 'not.a.token' > "$LX_RUN/none.token"
	check "$mode: a text that is no token is refused, and nothing is read after it" "refused" \
		"$(q none "SELECT id FROM projects" | grep -q '^ERROR: [0-9A-Z]\{5\} ERROR: [0-9A-Z]\{5\}$' && echo refused || q none "SELECT id FROM projects")"
	rm -f "$LX_RUN/none.token"
done
summary
