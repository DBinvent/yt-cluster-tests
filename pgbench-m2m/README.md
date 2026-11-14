# pgbench-m2m

Many writers to many copies: six YT Cluster nodes over two docker hosts, every node running
pgbench on its own tables while the cluster replicates every table to the other five - and the
cluster has to heal once the load stops. A nightly suite (`nightly.sh`, `pgbench-m2m`), run last,
once both lanes are done: it takes both docker hosts.

```
pgbench-m2m/run.sh [--deb FILE] [--keep]     about 55 minutes, under the nightly's lock
```

## The matrix

| cell | `cluster_commit` (module A, wal=half) | layout |
|---|---|---|
| 1 | `nodes=0` - the origin alone (`CggSAhACGgIQAQ==`) | a database per node: node i writes `bench<i>` |
| 2 | `nodes=0` | one database `bench`, a schema per node: node i writes `n<i>` (its sessions' `search_path`) |
| 3 | `nodes=2` (`CgoSBAgCEAIaAhAB`) | a database per node |
| 4 | `nodes=2` | a schema per node |

### Backward compatibility

First, before the matrix, a smoke test (owner, 2026-11-13: a basic cluster config and a smoke
test - connected, rows both ways, no errors): one cluster of two builds, nodes 1, 3 and 5 on the
image Docker Hub serves now, `dbinvent/yt:latest` - the last release, with its own package - and
nodes 2, 4 and 6 on the deb under test, so each docker host runs both. It passes when the
cluster comes up and takes its config (`nodes=2`, a schema per node), one transaction written on
each node reaches every other node - the last release's rows on the new build and the new
build's on the last release - and no node logs an error, a panic or a divergence after the
writes. A write refused while the cluster settles, in its first seconds, is tried again for a
minute, the tries said in the log. Not counted, but said with its count: a peer's ask for a sub-term a node's wal-file does
not hold (YT-E460), which 1.20 logs at ERRO in a cluster of one version too, hundreds of
times a cell - on the 1.20 nodes only: 1.21 logs it at debug, so on a 1.21 node it counts. A node that does not come up: the end of its log in
the run's log, every node's log beside it. A few minutes. The run pulls `dbinvent/yt:latest` before it builds either image, and logs
which build each node runs. `M2M_COMPAT=0` leaves it out.

Each cell: a fresh cluster of the deb under test on `dbinvent/yt` (the pgbench tables made and
filled alike on every node before the extension is in their database, `10-m2m.sh`), then 5
minutes of pgbench on every node - 2 clients, TPC-B-like, each sleeping 0-400 ms between
transactions; a run a refused row aborts (55000, a row blocked) starts again - so the load lasts
the 5 minutes whatever its rows meet. Two clients on pgbench's single branch row are concurrent
transactions on one row: a commit mode that waits for no other copy lets the copies diverge.
Since 2026-11-10 the origin refuses such a write when its peers would apply it out of order -
the lower subterm writing the row after the higher one committed it - with `40001`, and
pgbench counts it as a failed transaction (ytserv `[row-inversion]`).

The cell passes when the cluster heals within **100 x the SQL timeout** (`def_sql_timeout_sec`,
1 s by default: 100 s) of the load's end: every node's tables one copy on all six nodes (the
tellers, the branches, the history's row count and the accounts' sum) and no row blocked (no T3
row). A 5-minute cool-down follows and the state at its end is reported too.

`nodes=0` is safe only with one data source - one node writes the table, as here. A row more than
one transaction writes under it (a network split, a retry on another node) has no right copy: the
higher subterm's copy from its source wins, the row is blocked on the cluster's sync until the
copies agree (no new transaction counts as newer meanwhile), and writes of the same term and
subterm are resolved by hand.

## Settings

`yt-cluster-tests/.env` (see `env.example`), a variable already set winning over it:

| variable | default | |
|---|---|---|
| `M2M_HOSTS` | `YX_HOST LANE_HOST` | the two docker hosts (ssh targets, or `local`); one host takes all six nodes |
| `M2M_BUILD_HOST` | `YX_HOST` | where the image is built; carried to the other host by `docker save` / `docker load` |
| `M2M_DEB` | the newest deb a nightly built | the deb under test (`--deb`) |
| `M2M_NODES_SET`, `M2M_LAYOUTS` | `0 2`, `db schema` | the matrix |
| `M2M_COMPAT` | `1` | the backward-compatibility smoke test; `0` leaves it out |
| `M2M_SECONDS`, `M2M_COOL` | 300, 300 | each cell's load and cool-down |
| `M2M_CLIENTS`, `M2M_SLEEP_MS`, `M2M_SCALE` | 2, 200, 1 | pgbench's clients a node, their pause, the scale |
| `M2M_CPUS`, `M2M_MEM` | 2, 2g | each node's limits |
| `YT_BASE_IMAGE` | `dbinvent/yt:latest` | the image the nodes are built on, pulled at the start; the published release of the backward-compatibility smoke test |
| `M2M_OUT` | `pgbench-m2m/logs/<stamp>` | the run's log, `results.tsv` and every node's log (the nightly: its run's logs) |

The nodes are on the hosts' docker swarm overlay network, as `mongodb/` runs them: each its own
container name and address, the stock ports. A swarm the run made is left again at its end.
