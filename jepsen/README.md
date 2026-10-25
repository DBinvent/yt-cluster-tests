# jepsen/ - Jepsen against YT Cluster, by hand and in the nightly

[Jepsen](https://jepsen.io) is the industry standard for testing data consistency in a cluster, designed to compromise data integrity on purpose: very picky
and very aggressive, its synthetic faults force the very rare cases a production
cluster is very unlikely to meet. [Jepsen](https://github.com/jepsen-io/jepsen) writes to every node at once while a
nemesis injects faults, records every operation's start and end, and has checkers
judge the whole history. Here the workloads are
[jepsen-io/sql](https://github.com/jepsen-io/sql)'s - Jepsen's own SQL workloads
over JDBC - and the judge is Elle, which finds transactional anomalies (G0, G1a-c,
G-single, G2, lost updates) and names the consistency models a history rules out.
The topology suites check end states (`29_concurrent.sh`); this checks histories.

**By hand, and four cases in the nightly.** `run.sh` takes the nightly's lock, so
a run by hand and a nightly never meet. The nightly runs the four cases that found
most of the findings as a suite of its own, `jepsen` (`nightly_cases.sh`, about 20
minutes): case 2 (sequential `rw`, partition + kill + pause, 60 s), case 20 (`half`,
node bouncing), case 24 (as case 2, 300 s) and case 25 (sequential + recon, every
fault and packet, 300 s), each judged as the retests were - `OK` or `FAIL` a case,
a failed run's store kept with the run's logs. By hand: `jepsen/nightly_cases.sh`.

**The findings:** 51, every one fixed and retested - none critical, from the first
run on. [findings.md](findings.md): every finding in one list by severity, then
each in full with its retests; one by one, by severity, in
[findings.html](findings.html) - a copy of
[the page shared on 2026-10-23](https://claude.ai/artifact/Dtu2vx8WUyNm19J8NBjRFH),
brought up to date (to view it: [dbinvent.com](https://www.dbinvent.com/cluster/articles/jepsen-findings)).

```sh
jepsen/run.sh                        # 5 nodes, append, partition,kill,pause, 300 s
jepsen/run.sh -- --workload rw --nemesis partition --time-limit 120
jepsen/run.sh --nodes 7 --keep -- --isolation repeatable-read --delta
```

## What it does

`run.sh` builds two images on the docker host (`YX_HOST` in `../.env`, as for
`topology/`) and starts, every run from nothing, on a network of their own:

| container | what |
|---|---|
| `yt-jepsen-n1` ... `n5` | a YT Cluster node as [dbinvent/yt](https://hub.docker.com/r/dbinvent/yt) runs one - PostgreSQL 18 and ytserv, set up by its own entrypoint (`YT_PEERS` the nodes, database `app`) - plus sshd, sudo, iptables, tc. By default the newest deb of the yt-pgxt checkout (`target/debian`) replaces the image's package: the build under test (`--deb FILE`, `--deb none`, `--base IMAGE`) |
| `yt-jepsen-control` | the Jepsen control node: JDK 21, Leiningen 2.12.0 (checksum-pinned), graphviz, git (a test's start logs its revision), this test, its dependencies fetched and compiled at build |

Then `lein run test` in the control node: the workload's clients on every node,
the nemesis, then a heal, a recovery pause, the final reads, and the checkers.
Afterwards the store comes here, the containers go (`--keep` leaves them).

The test (`src/jepsen/ytcluster.clj`):

- **db**: waits for each node's ytserv to name a leader (`yt_info('o')`), then
  sets the cluster as Jepsen expects a consistent database to behave: the leader
  writes three catalog C rows, which reach every node, and every node waits until
  it runs with them (`yt_info('c:<name>')`). Never fewer than half the nodes:
  - `def_cluster_commit` - `all` (`--commit`): the strict refusal. Under `half` a
    conflict with a node outside the commit's party is only reported after the
    commit (ytserv `config.md`). `all` is every node online: a node gone off takes
    no part - the cluster runs smaller, never below a majority - and catches up
    when it is back;
  - `min_cluster_size` - a majority: a cold-start election, a pause and a split
    need that many nodes (an ordinary election takes a majority anyway). The
    image set every node, which held all three off while one node was down; it
    and `ytctl --batch` now set a majority;
  - `def_sql_timeout_sec` - 5 s (`--sql-timeout`), static, well inside the
    client's 30 s socket timeout: the cluster answers - definite - before the
    client gives up and leaves the operation indeterminate.

  `kill!` and `pause!` act on ytserv - SIGKILL, SIGSTOP/SIGCONT. PostgreSQL stays
  up: its exit ends the container. The entrypoint starts a killed ytserv again 5 s
  later; `start!` waits for the process, not for a leader - the nemesis is one
  worker, and a node still paused would hold the election, and so its own resume,
  off.
  The signal is the test's own `pgrep | kill`: Jepsen 0.3.14's `grepkill!` sends
  none (its command sits inside its timeout form), so the first runs' kills and
  pauses did nothing.
- **nemesis**: Jepsen's packages for the faults offered - partition, packet, db -
  not all of `nemesis-package`, which sets up every fault whether asked or not:
  file corruption fetches bitflip from GitHub on each node, the clock one builds
  its tools there and resets the clock.
- **client**: jepsen.sql's, wrapped. DDL does not replicate, so every node makes the
  workload's tables - jepsen.sql makes them on the primary only - and puts them on
  the cluster (`yt_setup`). Its teardown drops nothing: the containers go with the
  tables, a `--keep` run leaves them to look at, and a DROP would wait behind any
  write the cluster never finished.
- **tables** (`--sc`, the default): every workload table configured before the
  workload, as ytserv `serializable.md` has it - once every
  node has made them (a barrier), the leader sets each one's row to
  `sequential_consistency` 1 and `cluster_commit` `all` (`--commit`), a write
  that reaches every node and applies at once, and each node waits until
  `yt_info('a:<table>')` shows both. Each party member runs the transaction at
  its origin's SERIALIZABLE. `--no-sc` leaves the tables to the database's
  defaults - `def_cluster_commit` (`--commit`), the strong case. `--recon` sets
  each row's reconciliation to repair as well: a copy that differs is overwritten
  from a strict majority, a row with none is blocked - the self-healing.
- **errors**: definite (the transaction left nothing, a `:fail`) only for what
  ytserv refused before a commit was decided - 40001, 55409, 55000, 40P01, 57P03
  (the cluster cannot take the write now) - and a
  duplicate key or a statement in an aborted transaction. Anything else - a lost
  connection, a timeout, 08006 - may have committed: indeterminate (`:info`), as
  Elle must treat it.
- **checkers**: the workload's (Elle), op counts, unhandled exceptions, the HTML
  timeline. No performance graphs: no `checker/perf`, no gnuplot.

## Options

`run.sh [--nodes N] [--base IMAGE] [--deb FILE|none] [--keep] [-- TEST OPTIONS]`;
`YT_LOG_LEVEL=debug` (by hand) sets ytserv's log level on every node before the
test, `CONVERGE_WAIT` (60) how long the copies get to become equal.
TEST OPTIONS are `lein run test`'s (`docker exec yt-jepsen-control lein run test
--help` on a kept run lists them all); the ones that matter most:

| option | default | what |
|---|---|---|
| `--workload` | `append` | `append`: lists of integers, values comma-separated `text` - Elle infers the most from it; `rw`: registers |
| `--nemesis` | `partition,kill,pause` | any of `partition` (iptables), `packet` (tc: delay, loss), `kill`, `pause`, or `none` |
| `--isolation` | `serializable` | the transactions' level, on every node |
| `--expected-consistency-model` | `cursor-stability` (`run.sh`) | what Elle holds the history to - the goal, strong writes and eventually consistent reads: G0, G1, lost update, incompatible order prohibited; G-single and G2 (stale reads) allowed |
| `--commit` | `all` | how many nodes a commit takes (`def_cluster_commit`): `all` - every case runs it; `half`, rounded up, is kept for a node-bouncing case only |
| `--sql-timeout` | 5 | seconds a node may take on a statement before it refuses (`def_sql_timeout_sec`), 1 to 20 |
| `--sc` | on | every workload table configured before the workload: `sequential_consistency` 1 and `cluster_commit` `all` (`--commit`), each party member at the transaction's isolation level, as ytserv `serializable.md` has it; `--no-sc` leaves them to the database's defaults |
| `--recon` | off | every workload table reconciles its rows (recon repair, a round per 20 changed rows or 2 s): a differing copy repaired from the majority, or the row blocked - the self-healing |
| `--delta` | off | every session sets `yt_cluster.delta`: a conflicting row is retryable (40001) rather than refused (55409) |
| `--time-limit` | 300 | seconds of workload, setup and checking aside |
| `--rate` | 50 | operations per second, every client together |
| `--concurrency` | `2n` | clients: 2 per node |
| `--nemesis-interval` | 5 | seconds between faults |
| `--key-count`, `--max-txn-length`, `--max-writes-per-key` | 10, 4, 256 | Elle's keys and transactions |

## Results

The latest run only - no history: each run replaces both.

- `findings.md` - every finding in one list by severity, then a short summary per
  session, appended: what the runs found and what was fixed. Kept in git.
- `results.yaml` - the run: when, the build, nodes, options, the verdict
  (`valid`, `invalid`, `unknown`), the anomalies and the models ruled out, and
  three counts of YT's own: `stuck`, the sessions still holding a transaction a
  minute or more at the end (all nodes; a write the cluster never finished holds
  its row locks); `divergence`, ytserv's `CLUSTER DIVERGENCE` log lines (all
  nodes); `leaderless`, the nodes naming no leader after the heal and the
  recovery time; `converged`, whether every node holds the same copy of each of
  the workload's tables then (a checksum each, `docker/<node>.sums.txt`) - given
  up to `CONVERGE_WAIT` seconds (60) to get there, eventually, the wait recorded;
  when they do not, every node's rows (`docker/<node>.rows.txt`) and its data
  version - per term the subterms it holds and the ones it misses
  (`docker/<node>.dv.txt`); `recon`, the rows recon repaired and the rows it holds blocked (all nodes). Kept
  in git.

Every case runs `all`: `--commit half` is kept for a node-bouncing
case only, and is not one of the suite's runs.

Exit status: Jepsen's - 0 valid, 1 invalid, 2 unknown, 254 bad options, 255 the
test crashed; 75 when another run holds the lock.

## Findings

51 findings, every one fixed and retested - none critical, from the first run on:
24 severe, 21 warnings and 6 low. Most of the fixes improve usability: they remove
the need for workaround solutions, to meet the expectation of a high level of
user-friendly experience. Every finding in one list by severity, then each in full
with its retests: [findings.md](findings.md); one by one, by severity:
[findings.html](findings.html).

On build 1.20.1 every run was invalid - lost updates, incompatible list orders,
divergence. With the fixes (YT Cluster 1.20) and every table configured as the test
sets it (sequential consistency, `all`, the isolation level carried to every party
member - ytserv `serializable.md`), the runs hold the goal: **strong writes,
eventually consistent reads** - no write lost or applied twice, of two conflicting
writes one refused, the copies equal at the end, nothing stuck, a leader on every
node. Elle judges `cursor-stability`; the histories in fact hold snapshot isolation,
and miss serializable only by write skew between nodes (G2-item) - stale reads,
allowed: a serializable read over the whole cluster is not the goal.

The night of 2026-10-23 ran every case - sequential, strong and `half` (node
bouncing only), each with `--recon` too, 26 cases - and the retests ran them again
on seven builds with fixes, 2026-10-23 to 25: 397 runs, each failure a finding fixed
before the next build, and the last build passed all 49 of its runs. The nightly of
2026-10-25 found two more (rmc and topology), fixed the same day; four of the cases
run in the nightly since, as the suite `jepsen`.

We continue improving and monitoring YT Cluster as new features come, and this
Jepsen test project is updated with them.

Jepsen's own, handled in the test: 0.3.14's `grepkill!` sends no signal,
`nemesis-package` sets up every fault whether asked or not, and a test's start
needs git on the control node.

## The docker host

One docker host is enough: five node containers and the control node, about 3 GB
for the nodes and 6 GB for the control node's JVM (`project.clj`). Every fault
works in containers but the clock: containers share their host's clock, so a
clock fault would set the docker host's own - it is not offered. Clock skew needs
nodes with a kernel each (VMs, or machines). A run holds the nightly's lock for
its whole length: keep it clear of the nightly's start (05:00 UTC), or that night's
run is skipped.

The [community Docker setup](https://github.com/nurturenature/jepsen-docker)
(Jepsen itself supports none) was consulted, not used: these images are built from
dbinvent/yt and Debian here, with nothing pulled from a third party's registry.
