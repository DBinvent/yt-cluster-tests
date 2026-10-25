# Migration test: a running database into a YT Cluster, node by node

An ordinary PostgreSQL server with an application writing to it becomes node 1
of a YT Cluster; three more nodes then join it one at a time, each from a dump
of the node that joined before it, while every node already in the cluster
keeps writing. At the end, with the traffic stopped, every node's database is
compared with every other's.

It follows the operator's procedure step by step (yt-cluster `migration.md`), with
the real package, `ytctl --batch`, systemd and a real PostgreSQL restart, in LXC
containers.

## What runs

| step | script | what |
|---|---|---|
| boxes | `00_create.sh` | `ubuntu:24.04` with PostgreSQL 18 from apt.postgresql.org, nothing of YT Cluster; copied into `ytmig-1` ... `ytmig-4` |
| the application | `10_app.sh` | on node 1: the role `app`, the database `appdb`, its tables, and node 1's writer, on plain PostgreSQL |
| step 1 | `20_first.sh` | node 1: the package, `ytctl --batch --peers <itself> --config-trigger --users-db appdb --tables public.mig_seq`, which restarts PostgreSQL once (`max_prepared_transactions` 0 -> 100, `shared_preload_libraries`); then the backup, `pg_dump -Fc` and `pg_dumpall --roles-only`, under load |
| step 2, per node | `30_join.sh <n>` | the dump of node n-1 (node 1's backup for node 2), carried over; the package and `ytctl --batch --peers <members and itself> --cluster <uuid> --config-trigger` - its ytserv starts and waits, as nobody knows it yet; the roles and the database restored, and the database registered; the node's N row written on the leader; it follows, then starts its own writer |
| a new term | `40_term.sh` | the leader's ytserv restarts; every node agrees on the next term and its leader |
| the end | `50_compare.sh` | every writer finished; every node's `mig_seq` the same (count and an md5 of every row's values), `mig_local` the same, every node in every roster, one term; `verify.py` holds each writer's log against the rows |

The load: on every node, `writer.sh` inserts the rows `(its yt.node, 1)`,
`(its yt.node, 2)` ... into `mig_seq`, one plain `BEGIN / INSERT / COMMIT` a second
over TCP with a password, as an application sends them - nothing of YT Cluster in
it. Node 1's starts before YT Cluster is installed and goes on through the restart;
a new node's starts once it follows. Each logs what it was told: `OK`, `ERR` (a
clean error: nothing committed), `NOC` (no connection: nothing sent) or `UNK` (the
connection broke mid-transaction: either way, but the same on every node).

The checks, at the end - and at each join, that it refused no application write on
any node (no new `ERR` in any writer's log):

- every `OK` row is on every node; no `ERR` or `NOC` row is anywhere;
- every node holds exactly the same `mig_seq` rows with the same values, and the
  same `mig_local` - a table never put on the cluster, which reaches a new node in
  the dump alone;
- every node's roster holds every node; they are at one term, with one leader.

## Run it

On a host with LXD (`lxd init --auto`) and python3, with a yt-cluster package for
PostgreSQL 18 (`cargo deb -p ytctl --variant pg18 --no-build` in yt-cluster):

```
MIG_DEB=/path/to/yt-cluster_<v>_amd64-pg18.deb ./run_all.sh
```

About 30 minutes with the defaults: each writer's loop is `MIG_LOOP` rows (1500),
one a second (`MIG_PAUSE`). `MIG_LOOP=200` makes a short run. `MIG_KEEP=1` keeps the
containers; `./inspect.sh [node ...]` shows each node's state, term, roster and rows.

The containers fetch PostgreSQL from apt.postgresql.org. Where Docker runs on the
same host its FORWARD policy drops the LXD bridge's traffic (see `../lxc/README.md`):
`MIG_NIC=macvlan` gives each container its own address on the uplink instead. The
scripts reach the containers with `lxc exec` only.

| setting | default | |
|---|---|---|
| `MIG_DEB` (or `YT_CLUSTER_DEB`) | | the package |
| `MIG_NODES` | `1 2 3 4` | the servers; the first is the application's |
| `MIG_LOOP`, `MIG_PAUSE` | `1500`, `1` | each writer's rows, and seconds between them |
| `MIG_WAIT` | `300` | seconds a node gets to follow, and the nodes to agree |
| `MIG_NIC` | `bridge` | `macvlan` where Docker drops the bridge's forwarding |
| `MIG_PREFIX` | `ytmig` | the containers' names |
| `MIG_KEEP` | `0` | `1`: leave the containers |

`run/` holds what one script hands the next (the addresses, the uuids, the dumps,
`ytctl`'s output and the writers' logs).
