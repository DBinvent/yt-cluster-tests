#!/usr/bin/env bash
# What each node says: its state and term, the roster and position rows of its
# config, and its application rows. For a look by hand, and in a failed run's log.
#
#   inspect.sh [node ...]     (default: every node)
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

for n in ${*:-$MIG_NODES $MIG_COPY}; do
	say "== node $n ($(cname "$n"), $(ipn "$n" 2>/dev/null))"
	q "$n" postgres <<'SQL' | sed 's/^/   /'
select 'E ' || name || ' = ' || value from json_to_recordset(yt_info('E')) as x(name text, value text, module text)
 where name in ('self', 'fill', 'term', 'leader', 'state', 'divergent', 'copy_end') or value ~ ', (Leader|Good|Spare|Down|Paused|Na)\M';
select 'o ' || value from json_to_recordset(yt_info('o')) as x(name text, value text, module text);
select 'cfg ' || module || ' ' || name || ' = ' || left(value, 60) from public.yt_config
 where module = 'N' or (module = 'C' and (name in ('min_cluster_size', 'term', 'least', 'leader_uuid', 'cluster') or name like 'copy.%'))
 order by module, name;
SQL
	q "$n" <<'SQL' 2>/dev/null | sed 's/^/   /'
select 'mig_seq ' || node || ': ' || count(*) || ' rows, seq ' || min(seq) || '..' || max(seq) from mig_seq group by node order by node;
select 'mig_local ' || count(*) || ' rows' from mig_local;
select 'mig_hot ' || string_agg(id || '=' || n, ' ' order by id) from mig_hot;
SQL
	xn "$n" sh -c 'test -f /root/mig/writer.log && echo "   writer: $(tail -1 /root/mig/writer.log | cut -c1-120)"' 2>/dev/null
done
