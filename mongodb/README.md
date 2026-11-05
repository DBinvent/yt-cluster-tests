# mongodb/ - one document, every node writing it: MongoDB and YT Cluster with DocumentDB

Concurrent writes of ONE document on a cluster of 4 or 6 nodes - two docker hosts, 2 or 3
CPU-limited nodes on each - every node's writer incrementing its own path of it at once,
the same hosts, limits and load for each phase, one phase after the other:

| phase | cluster | a write commits |
|---|---|---|
| `mongo` | a MongoDB replica set (`mongo:7.0`) | through the primary, `w=majority, j=true`: every writer's write on one node |
| `yt` | YT Cluster + DocumentDB (PostgreSQL 18, ytserv, DocumentDB 1.0 and its gateway on every node) | 2PC: its party with it; the document a merge table's, merged path by path (ytserv `merge.md` 2.4) |
| `yt1` | the same | `cluster_commit=nodes>=1`: its node and one more; the others merge it in |
| `yt2` | the same | `merge_async` (`merge.md` 2.5): on its own node at once, checked in after; every other node merges it in |

**The document.** Database `perf`, collection `doc`, `_id` `doc`: a `profile` and a counter
`{n: 0}` at each of `education`, `jobs`, `achievement`, `awards`; `social` and `hobby` are
empty lists. Node i's writer increments path i's `n` (`$inc`) - on 6 nodes nodes 5 and 6
make `social` and `hobby` counters first; on 4 they stay `[]`.

**The writers** (`writer/doc.py`, pymongo): one beside each node, its own CPU limit, writing
to its own node (MongoDB: the replica set, so the primary), the run's length, 4 threads
each. A refused increment is tried again after a short random pause until it commits. Each
reports the increments committed, the retries, ops/s, and the average, 95th and 99th
percentile latency of a committed increment, its retries included.

**The check.** After the writes, every node's copy of the document must hold, at every path,
that path's writer's committed increments: read on every node until it does or about 90
seconds pass. `counters_match_on_every_node` says whether it did; `converged_after_s`, how
long after the writes it took.

## Run

```bash
../nightly/locked.sh ./run.sh                          # mongo and yt
../nightly/locked.sh ./run.sh mongo yt yt1 yt2         # every phase
PERF_PER_HOST=3 ../nightly/locked.sh ./run.sh mongo yt yt1 yt2   # 6 nodes
```

Under the nightly's lock: the hosts are the nightly's docker hosts. The images are built
on the first (`YX_HOST`) and carried to the other, never built there. The two hosts are
joined as a docker swarm for the run's overlay network - a container reaches any other by
its name - and leave it after, when the run made it.

Settings (`../.env`, or the environment):

| variable | default | |
|---|---|---|
| `PERF_HOSTS` | `YX_HOST LANE_HOST` | the two docker hosts, ssh targets; one takes every node |
| `PERF_BUILD_HOST` | `YX_HOST` | where the images are built |
| `PERF_DEB` | the newest a nightly built | the yt-cluster deb under test |
| `PERF_PER_HOST` | 2 | nodes on each host: 2 - a cluster of 4, 3 - of 6 |
| `PERF_CPUS`, `PERF_MEM` | 2, 2g | each database node |
| `PERF_YCSB_CPUS` | 1 | each writer |
| `PERF_SECONDS`, `PERF_THREADS` | 120, 4 | each phase's writes, each writer's threads |
| `PERF_KEEP`, `PERF_KEEP_ALL` | 0 | keep a failed phase's containers, or every phase's, for a look |
| `PERF_DEBUG` | 0 | ytserv's debug log on every node |
| `MONGO_IMAGE`, `YT_BASE_IMAGE`, `DOCDB_IMAGE` | `mongo:7.0`, `dbinvent/yt:latest`, DocumentDB's `documentdb-local:pg18-1.0.0` | |

## Results

`results.yaml`, an entry a run: the limits, the load, and per phase each writer's numbers,
their total, every node's counters and the check. The run's logs are under `logs/` (not
committed).

## Files

| file | |
|---|---|
| `run.sh`, `env.sh` | the run, its settings and helpers |
| `writer/` | the writer image: `doc.py` - the document made, read, and written |
| `ytdoc/` | the YT Cluster + DocumentDB node image: the yt image, the deb under test over its package, DocumentDB, its gateway (`docdb-gateway.sh`, beside the yt entrypoint) |
| `ycsb/` | a YCSB 0.17.0 image with its MongoDB binding - the first load, which `run.sh` no longer uses: YCSB's update is a `$set` of a field, not an increment of a counter every node can check |
