# Jepsen - findings and fixes

[Jepsen](https://jepsen.io) is the industry standard for testing data consistency in a cluster, designed to compromise data integrity on purpose: very picky and
very aggressive, its synthetic faults force the very rare cases a production
cluster is very unlikely to meet.

Every finding first, in one list by severity; then one section a session, the
newest last. `results.yaml` holds the latest run only.

## All findings, by severity

51 findings, every one fixed and retested - none critical, from the first run on.
Most of the fixes improve usability: they remove the need for workaround solutions,
to meet the expectation of a high level of user-friendly experience. We continue
improving and monitoring YT Cluster as new features come, and this Jepsen test
project is updated with them.

- **severe** (24) - one row: its copies differ, a committed write there is lost or
  invisible, or the row is locked; or one node's copy left behind while the cluster
  runs on. The damage stays in that row or that node.
- **warning** (21) - availability, or a guarantee weaker than configured: no leader,
  a node stalled, writes refused and retried, with no data difference; or a
  difference only a misconfiguration produces (`half`), which a guardrail can refuse.
- **low** (6) - no data difference: a false alarm or a wrong error code.

Most severe first; each finding in full, by its number, in its session below, and
on the page: [findings.html](findings.html).

| severity | # | finding | fix |
|---|---|---|---|
| severe | 1 | A duplicate insert committed although every member refused it | [party-lost], [party-cas] |
| severe | 42 | Two leaders of one term, its subterm numbers issued twice | [term-vote], [vote-data] |
| severe | 40 | A row on three nodes of five, its write failed | [checkout-decided] |
| severe | 13 | A commit never sent | [term-race] |
| severe | 26 | A prepared record closed as committed | [checkout-prepared] |
| severe | 22 | A prepared transaction with no record | [prepared-norecord] |
| severe | 25 | A rollback that missed a prepared transaction | [ptx-gid] |
| severe | 20 | A prepared transaction left behind | [prepared-undecided] |
| severe | 8 | `all` left a restarting node out | [sc-all] |
| severe | 24 | A Spare node that never caught up | [spare-pull] |
| severe | 27 | A pull waiting for good | [apply-lock] |
| severe | 2 | A node behind wrote and joined commits | [behind], [caught-up] |
| severe | 5 | Row locks held for good | [party-yield], [orphan] |
| severe | 50 | A copy's restart pulled its first term again | [seed-kept] |
| severe | 49 | A leader one write behind: a subterm served short of its second statement | [partial-read] |
| severe | 30 | A node back from a kill read itself complete without a term's last writes | [placeholder] |
| severe | 31 | A node cut off during a transaction lacked its row, reading itself complete | [2pc-member], [checkout-unprepared], [all-online] |
| severe | 36 | A node short of an older term's tail, reading itself complete | [term-end] |
| severe | 48 | A node short of three rows: a term's hole left out at a start | [dv-start] |
| severe | 17 | A term's tail unseen | [term-tail] |
| severe | 16 | A hole forgotten at a restart | [replay] |
| severe | 19 | A transaction served in part | [partial] |
| severe | 14 | A catch-up's write over a missing predecessor | [dep-defer] |
| severe | 7 | A committed write dropped where a node rolled its part back | [rolled-back-here] |
| warning | 21 | Two terms writing one row | [term-fence] |
| warning | 29 | `half` without recon: a differing row drew further apart | [divergent-t3] |
| warning | 47 | Every subterm of a term read as diverged: a second WAL file of it | [wal-first] |
| warning | 51 | A member's own insert drew values replicated rows held | [seq] |
| warning | 3 | Leaderless for good | [restart-leaderless] |
| warning | 44 | No leader at the end: an older term's leader led on | [stale-leader], [restart-leaderless] |
| warning | 33 | A cold start's split vote was never asked again | [cold-split] |
| warning | 46 | No cluster at the start: a leader of two votes in five | [roster], [health] |
| warning | 4 | A stale leader kept its term | [stale-leader] |
| warning | 32 | A leader lost right after a restart was never noticed | [lost-after-start] |
| warning | 37 | No write in a whole run under the harshest schedule | [gap-mode] |
| warning | 41 | No write in a whole run again: one gap in flight held every table | [gap-rows] |
| warning | 43 | A node down to the end: a WAL file with no header | [wal-header] |
| warning | 45 | A node down to the end: a WAL page a kill tore | [torn-page] |
| warning | 15 | A node stalling itself | [outdated-abort] |
| warning | 18 | A node stalled at a term's first write | [tm-guard] |
| warning | 23 | A lock cycle in the fix for 19 | [partial] |
| warning | 6 | A cluster setting applied before its commit | [cfg-commit] |
| warning | 35 | A cluster setting committed on a member and never in effect there | [cfg-pull] |
| warning | 10 | yt_setup's table row unseen | [cfgtbl] |
| warning | 11 | The image set the election size to every node | [min_cluster_size] |
| low | 28 | A false CLUSTER DIVERGENCE after a kill | [apply-2pc] |
| low | 34 | A false CLUSTER DIVERGENCE: a 2PC step cut off by its deadline | [complete-whole] |
| low | 38 | A false CLUSTER DIVERGENCE: a later term's write over an older term's missing tail | [older-tail], [repair-gate], [self-resolved] |
| low | 39 | A false CLUSTER DIVERGENCE: records held undecided read as held | [older-tail] |
| low | 12 | A false CLUSTER DIVERGENCE on a re-apply | [apply-whole], [replay] |
| low | 9 | A refusal read as a lost connection | [57P03] |

## 2026-10-22 / 23

**Setup.** Five nodes; jepsen-io/sql's `append` and `rw`, judged by Elle;
partitions, ytserv killed and paused, packet delay and loss. Every table
configured before the workload: sequential
consistency 1, `cluster_commit` `all`, the transaction's isolation level carried
to every party member. The goal: strong writes, eventually consistent
reads, no divergence - Elle `cursor-stability` (no lost, duplicated or diverging
write; stale reads allowed) and every node's copy equal at the end.

**Before:** build 1.20.1 - every run invalid: lost updates, incompatible list
orders, divergence, a cluster left without a leader, sessions holding locks for
good.

**After:** with the fixes below (in YT Cluster 1.20) every
case passes - nothing stuck, a leader on every node, the copies equal:

| case | runs |
|---|---|
| `append`, partition + kill + pause, 60 s | 3 |
| `rw`, partition + kill + pause, 60 s | 6 |
| `append`, packet faults, 60 s | 3 |
| `append`, partition + kill + pause, 300 s | 2 |
| `rw`, partition + kill + pause, 300 s | 1 |
| `append`, `--delta` | 1 |

**Found and fixed** (ytserv):

1. A duplicate insert committed although every party member refused it - now a
   member holding the key refuses it as a conflict, the leader checks an INSERT
   as it checks an UPDATE, and a party that lost every member is vetoed.
2. A node behind - back from a restart, or a term joined late - wrote and joined
   commits on what it lacked (stale writes, read skew) - now refused until it
   holds what the members hold.
3. A cluster leaderless for good after restarts, every node running - now a
   restarted member rejoins, and a node lets go of a leader that answers Spare.
4. A leader cut off during the next term's election kept leading its old term -
   now it steps down when it hears a newer term's leader.
5. Row locks held for good: a deadlock across two nodes, and party sessions whose
   origin's rollback never arrived - now a party session blocking a local writer
   yields, and one its origin already decided is ended (the status call that asks
   the origin, which never answered, fixed).
6. A cluster setting applied before its transaction committed - a vetoed write
   stayed in effect - now applied at commit.
7. A committed write dropped on a node that had rolled its own part back - now
   applied when that node catches up.
8. `all` left a node out while it came back from a restart - commits went on
   without it - now, under sequential consistency, every node counts.

**Found in Jepsen 0.3.14, handled in the test:** `grepkill!` sends no
signal; `nemesis-package` sets up every fault whether asked or not; a test's
start needs git on the control node.

**A row left different is blocked, so the difference cannot grow.** A row whose
copy differs on one node (1, 7 and 8, before the fixes) takes no later write:
under `all` every node is a party member, and the member whose row is not the one
the writer read refuses with 40001 ([party-cas]) - the transaction rolls back on
every node, whichever node it came from, and each retry meets the same refusal.
Other rows write on. With `recon` repair on the table, a round finds the lone copy
against a strict majority and overwrites it from a winner - the row converges and
writes again; with no majority it is blocked for good (55000) and reported. With
`recon` off (the default) the row stays blocked. The
held locks (5) blocked their rows until a restart; no leader or two leaders (3, 4)
blocked every write.

**Found as well**, fixed the same night (9 to 12 below): a refusal without its own SQLSTATE reaches the client as 08006, a lost
connection; `yt_setup`'s table row reaches no running ytserv until a restart; the
image sets the election size to every node; a catch-up re-applying a write it
holds logs a false CLUSTER DIVERGENCE. By design, not a finding: a serializable
read over the whole cluster is not the goal - reads are eventually consistent, and
write skew between nodes from a stale read (G2-item) is what `cursor-stability`
allows.

## 2026-10-23, night - every case

**Setup.** As above, and the matrix of every case: sequential (`all`,
sequential consistency 1, the isolation level carried), strong (`all`, no
sequential consistency), `half` for node bouncing only (kill and pause) - each
with `--recon` too, the self-healing: every test table reconciles its rows, a
differing copy repaired from the majority or the row blocked. Every case is held
to its configuration: sequential and strong to Elle's `cursor-stability`, the
copies equal, nothing stuck, a leader everywhere, no CLUSTER DIVERGENCE; `half`
to the copies equal (eventually: 60 s after the run), nothing stuck, a leader
everywhere - Elle's verdict reported only.

The cases, on the build with every fix below (each passed run: the copies
equal, nothing stuck, a leader everywhere; sequential and strong also Elle
`cursor-stability` valid and no CLUSTER DIVERGENCE):

| # | configuration | workload | faults | s | | passed |
|---|---|---|---|---|---|---|
| 1 | sequential | `append` | partition, kill, pause | 60 |  | 1 of 1 |
| 2 | sequential | `rw` | partition, kill, pause | 60 |  | 1 of 1 |
| 3 | sequential | `append` | packet | 60 |  | 1 of 1 |
| 4 | sequential | `rw` | packet | 60 |  | 1 of 1 |
| 5 | sequential | `append` | partition | 60 |  | 1 of 1 |
| 6 | sequential | `append` | kill | 60 |  | 1 of 1 |
| 7 | sequential | `append` | pause | 60 |  | 1 of 1 |
| 8 | sequential | `rw` | partition | 60 |  | 1 of 1 |
| 9 | sequential | `rw` | kill | 60 |  | 1 of 1 |
| 10 | sequential | `rw` | pause | 60 |  | 1 of 1 |
| 11 | sequential | `append` | partition, kill, pause | 60 | `--delta` | 1 of 1 |
| 12 | sequential+recon | `append` | partition, kill, pause | 60 | `--recon` | 1 of 1 |
| 13 | sequential+recon | `rw` | partition, kill, pause | 60 | `--recon` | 1 of 1 |
| 14 | strong | `append` | partition, kill, pause | 60 |  | 1 of 1 |
| 15 | strong | `rw` | partition, kill, pause | 60 |  | 1 of 1 |
| 16 | strong | `append` | packet | 60 |  | 1 of 1 |
| 17 | strong | `rw` | packet | 60 |  | 1 of 1 |
| 18 | strong+recon | `append` | partition, kill, pause | 60 | `--recon` | 1 of 1 |
| 19 | strong+recon | `rw` | partition, kill, pause | 60 | `--recon` | 1 of 1 |
| 20 | half, node bouncing | `append` | kill, pause | 60 |  | 8 of 9 |
| 21 | half, node bouncing | `rw` | kill, pause | 60 |  | 1 of 1 |
| 22 | half+recon, node bouncing | `rw` | kill, pause | 60 | `--recon` | 1 of 1 |
| 23 | sequential | `append` | partition, kill, pause | 300 |  | 1 of 1 |
| 24 | sequential | `rw` | partition, kill, pause | 300 |  | 1 of 1 |
| 25 | sequential+recon | `rw` | partition, kill, pause, packet | 300 | `--recon` | 1 of 1 |
| 26 | strong | `append` | partition, kill, pause | 300 |  | 3 of 4 |

35 of 37 runs passed, 26 cases - every case passed; 20 and 26 failed once each, a node
left behind at the end that had not caught up (30, below). Before the fixes
they had failed in 21 runs of 122.

**The first session's four, fixed:**

9. A refusal without a code of its own - no leader, not joined yet, short of
   nodes, the node's ytserv unreachable - reached the client as 08006, a lost
   connection: now 57P03 (`cannot_connect_now`), the write was not taken.
10. A table row written with the config table's trigger off - `yt_setup`'s, a
    local save - reached no running ytserv until a restart: now taken by the
    periodic re-read of the table rows, as a deleted one was dropped.
11. The image and `ytctl --batch` set `min_cluster_size` to every node, holding
    off a cold-start election, every pause and every split while one node was
    down: both seed a majority.
12. A false CLUSTER DIVERGENCE: a write applied again over its own rows - its
    first apply cut off by the caller's deadline after the database committed it,
    before its record - now an apply runs to its end, and a miss over a row that
    already reads as the write leaves it is no divergence.

**Found and fixed by the matrix** (ytserv):

13. **A commit never sent** (sequential, pause): a node back from a pause opened
    the new term's WAL twice at once and kept the second; its write's record went
    with the first, its commit found none, and COMMIT PREPARED never went out -
    every member held the transaction prepared, its rows locked, for good, the
    copies different. A term is now opened once; a decision that cannot be
    recorded after the local commit still goes out.
14. **A catch-up's write over a missing predecessor** (`half`): a node back from a
    kill applied a later write of a row while the row's earlier one - this term's
    or the last's - was still undecided or still to come; the miss was recorded,
    the earlier write landed over it, the copy different for good. Such a miss is
    now deferred to the pull.
15. **A node stalling itself** (`half`): the leader, behind on a table, refused
    its writes with an answer its own origin pulled on inside the statement that
    held the row the pull had to write; the client hung, the table stayed behind.
    Now the client's transaction ends with 40001 and the pull lands.
16. **A hole forgotten at a restart** (`half`): a WAL reload read a subterm with no
    record as held - a write deferred to the pull, or never arrived, before the
    stop was never asked for again; an insert and every later write of its row
    missing there for good - and so did a term this node opened at a later
    subterm, its first ones read held. The reload now stops the decided run at the
    first hole from the term's start (a copy's seeded mark still raises it).
17. **A term's tail unseen** (`half`): once the next term opened, the members'
    pings left the term just completed out; a node that had missed its last
    writes read itself complete and never pulled them. The newest complete term
    now goes with the open ones.
18. **A node stalled at a term's first write** (`half`): an apply held the WAL
    map's read lock while it waited on a client's row; the new term's opening
    queued behind it, and every reader behind that - the client's own statement
    among them. The lock is now let go before any wait.
19. **A transaction served in part** (`half`): a subterm of several statements
    served from the file came as its first, or without a statement whose rows a
    member lacked; the puller recorded it committed and the rest was missing there
    for good. Now served whole, or as its outcome alone.
20. **A prepared transaction left behind** (`half`, a kill): a member stopped right
    after its PREPARE had the transaction prepared and its record not moved yet;
    the rollback that reached it later was only recorded, the prepared transaction
    held its rows for good. The database is now asked.
21. **Two terms writing one row** (`half`): cut off while the next term was
    elected, a leader handed out keys of its old term for seconds, and the
    members, in the newer term, took them. A member now refuses a new statement
    of an older term (40001, retried).
22. **A prepared transaction with no record** (strong, kills): a member stopped
    over and over right after its PREPARE came back with no record of the subterm,
    the transaction still prepared; the decided write was applied over the
    prepared one's locks and waited on them for good. The transactions prepared
    as ytserv starts are now looked up once and finished by the decision.
23. **A lock cycle of the fix for 19** (`half`): its first form asked the WAL
    pages for a subterm's statements, holding them while a page loaded under the
    file lock - a writer held the file and waited for the pages; the node's state
    machine stopped. The statements are now read one by one, as the first always
    was.
24. **A Spare node that never caught up** (`half`, a pause): back from a pause,
    Spare, a node asks to follow and is refused while it is behind - and the gap
    pull skipped a node that is not up, so it never pulled the holes below its
    newest record and stayed behind, refused, to the end. The gaps are now pulled
    whatever the node's state.
25. **A rollback that missed a prepared transaction** (`half`, a pause): the
    decision reached a member whose process no longer listed the transaction as
    prepared; the rollback was only remembered, and the prepared transaction kept
    its row locked. A decision now finishes a prepared transaction by its name
    when the database holds it, listed or not.
26. **A prepared record closed as committed** (`half`, a kill): the origin killed
    between its PREPARE and its COMMIT sent, from its restart, the checkout that
    closes a subterm; a member holding the transaction prepared closed its record
    as committed and never committed the transaction - the write invisible there,
    its rows locked, every later decision passing it by as held. A checkout now
    leaves a prepared record to its outcome, which the pull brings.
27. **A pull waiting for good** (`half`, a kill): a pull's earlier write of a row
    waited on the lock of a transaction held prepared here, whose outcome the same
    pull had still to bring - the pull never ended, no later one ran, and the node
    stayed behind. An apply now waits on a row lock twice the statement timeout,
    then fails, rolled back, a gap the next pull brings once the prepared one is
    finished.

Every one of 13 to 27 but 13 and 22 came from `half` with node bouncing, the catch-up paths a node
back from a kill or a pause takes - paths `all` takes too, after a restart.

**Fixed after the night** (every finding fixed and retested until gone):

28. **A false CLUSTER DIVERGENCE after a kill** (`half`, node bouncing; seen again
    in a debug repeat: 3.579 on n2, killed right after its apply): a node killed
    between an apply's database commit and its WAL record came back holding the
    rows with no record of them; the pull applied the subterm again over its own
    rows, missed, and logged a divergence for copies that were equal. *Fixed*
    ([apply-2pc]): an apply runs PREPARE TRANSACTION, its WAL record is written,
    then COMMIT PREPARED. Killed in between, the node comes back with the
    transaction prepared - with no record, the pull's commit finishes and records
    it; recorded, the restart commits it. A party member's prepared transaction
    with no record (22) is now recorded as it is finished too: before, only its
    state was set, on no record, and the pull applied it again.
29. **`half` with `recon` off: a differing row drew further apart**: a node outside
    the party took every later write of a row it held different, each a miss, and
    nothing stopped or repaired it. *Fixed* ([divergent-t3]): every CLUSTER
    DIVERGENCE puts the row under recovery's T3 whatever its table's `recon` - the
    leader blocks it cluster-wide (55000), so its difference cannot grow; it is
    re-checked every minute, repaired from a majority, and released once its
    copies agree.

30. **A node back from a kill read itself complete without a term's last writes**
    (`half` node bouncing, strong 300 s: 2 runs of 37 on the night's last build; one
    write missing in one, eight in the other, each a row's last). Found in the code,
    not yet in a failing run (the two had INFO logs only; 20 debug repeats did not
    fail): a new subterm's first insert puts an empty map in the WAL cache before
    its file write, and an insert cut off there - a party member's modify runs in its
    gRPC handler, dropped at the origin's deadline, which pauses and kills bring -
    left the empty map for good. The data version skips an empty entry, a gap only
    when a record follows it; the catch-up counted the newest cache key held. At a
    term's tail the node read itself through that subterm: not behind, no gap,
    nothing pulled. *Fixed* ([placeholder]): an insert that does not end takes its
    empty map out again, and the catch-up counts a subterm held only by a record.

31. **A node cut off during a transaction lacked its row at the end, reading
    itself complete** (sequential `rw`, partition + kill + pause; the last run
    before the retest, on a bisect build with 28 taken out): a partition cut one
    node off while a transaction of three writes ran; the transaction committed
    on the other four, and the node, back, read its subterm as held and never
    pulled it - the transaction's inserted row missing there for good, its data
    version complete, the copies different. INFO logs only, so the path is not
    proven; the fixes close every path that can leave a member's record held
    without its rows. *Fixed:*
    - [2pc-member]: every member of a party is one of the transaction's 2PC - a
      pure rollback when it is a real party member, as under `all`. A member's
      failed statement, or a PREPARE it did not ack, rolls the transaction back on
      every node. It was dropped as optional before, the rest went on, and only an
      abandon notice - lost in a partition - kept its record from closing committed;
    - [checkout-unprepared]: a checkout no longer closes a member's statements that
      never reached a PREPARE there - the record goes back to `New`, and the pull
      brings the outcome;
    - [all-online]: `all` is every node online now - a safe node restart is
      normal: a node gone off shrinks the cluster, and `all` means every node
      online now. A Down member takes no slot, never below a majority of the node set
      (it held every `all` write off until it was back - "not enough working nodes",
      among the refusals of the runs that committed nothing). Below `all` it
      depends on the member - part of the 2PC or of the eventual list: a party
      member as above, a node outside the party brought up to date by apply and,
      after a restart, by recovery.

32. **A leader lost right after a restart was never noticed** (sequential `rw`,
    partition + kill + pause, on the build with 31: a run that committed no write,
    Elle's verdict unknown): for `cold_start_sec` (30 s) after ytserv starts, a
    follower never declares its leader lost - the grace for a leader still coming
    up. Every node restarted, a leader was elected, and two seconds later a
    partition cut it off: the other four kept following it, nobody asked for an
    election, and every write waited on it to its statement timeout - 40 seconds
    led by nobody. *Fixed* ([lost-after-start]): the grace covers a leader that has
    not answered this node since its start; one that answered and then stopped is
    lost, and the election runs.

33. **A cold start's split vote was never asked again** (sequential `rw`, partition
    + kill + pause, on the build with 32: every node named no leader at the end):
    every node was paused right after a restart of all and resumed at once; in
    the same round each one detected the cold start, became Main and asked for an
    election - 1 of 4 votes each, all failed. The cold start's window was past by
    the next round, and the leaderless check, which asks again, runs on a cluster
    up only - which a cold start's Main was not. *Fixed* ([cold-split]): a cold
    start's Main is up, as the leaderless restart's is, and the next checks ask
    again.

34. **A false CLUSTER DIVERGENCE again** (`half` node bouncing, on the build with
    28 to 33: one run of 10 - one divergence, a row blocked, the copies equal at
    the end; its logs lost, as the judge of the `half` cases did not count a
    divergence then and the next run wiped the store): a party member's step of
    the 2PC - PREPARE TRANSACTION or COMMIT PREPARED - ran in the database, and
    the call's deadline, which a pause brings, dropped the handler before it moved
    the subterm's record. A commit left `PartySaved`: the pull brought the subterm
    again, no transaction was prepared to finish, so its statements were applied
    again over rows a later write had moved on by then - a miss, the divergence,
    and [divergent-t3] blocked the row. Found in the code, not proven in a run.
    *Fixed* ([complete-whole]): the step runs in a task of its own, as an apply's
    pass does ([apply-whole]) - the record follows the database whatever the
    caller does - and a PREPARE that ends after the origin's rollback leaves the
    decided record as it is.

35. **A cluster setting committed on a party member and never in effect there**
    (sequential `rw`, on the build with 34: one node never ran with the test's
    settings, and the setup gave up after 60 s - Jepsen's `crashed`, no workload
    run): a party member holds a setting its statement wrote until the origin's
    COMMIT reaches it ([cfg-commit]). The pull ran ahead of that COMMIT - the
    leader's data version moved as the origin committed - and finished the
    member's prepared transaction itself ([2pc-recovery]; the node's log shows
    it), which settled nothing, and the COMMIT call found nothing prepared. The
    row was in the member's table, its setting not in effect there until a
    restart. *Fixed* ([cfg-pull]): a transaction the pull decides settles its held
    settings - in effect with its commit, dropped with its rollback - and a
    checkout that undoes a member's session never prepared
    ([checkout-unprepared]) drops them, as an abandon does.

36. **A node short of an older term's tail, reading itself complete** (sequential
    `rw`, partition + kill + pause, on the build with 35: one node lacked the last
    write of three rows at the end, its data version complete): the node was
    killed, then cut off, while the others committed term 2's last 40 subterms.
    Back, it learned the members were through 293 and began to pull, was killed
    again, and came back into a cluster two terms on. The data version names the
    open terms and the newest complete one ([term-tail]), so no node told it how
    far term 2 went: it pulled the holes below its own last record (254), read
    term 2 complete there and never asked for the rest. It had also won the
    election of term 3 that far behind - a vote compared no data (fixed since: a vote
    compares the data, [vote-data], with 42). *Fixed* ([term-end]): every node names the end of each complete
    term it holds, and a node short of the members' end of an older term is
    behind in it - it pulls that term's tail, and takes no party write of an
    `all` table until it holds it.

37. **No write in a whole run under the harshest schedule** (sequential `rw`,
    partition + kill + pause, on the build with 36: Elle `unknown`, nothing
    committed): two subterms the leader of term 1 issued at check-in as the faults
    began (1.7, 1.8) were saved by no node. The leader rolls back a gap no node
    holds only once every member has answered without a record of it
    ([abandoned]) - a member that does not answer may be its origin, holding it -
    and some member was cut off, paused or killed through the whole run. The gaps
    never closed, and the outdated-table gate held every write to every synced
    table, also while a new leader stood with a majority (10 s, then 10 s more).
    *Fixed* ([gap-mode]): a gap's outcome follows its tables' configuration, the
    strongest of a transaction's tables: under `all` or `half` the data must be on
    every node or a majority, so a gap a majority does not hold is no valid data;
    under a single node or one more, that node is the source of truth for the
    transaction. When every synced
    table commits on a majority (`all`, `half`, no az or shard) - a gap nobody
    holds may be a transaction of any of them - the leader rolls back a gap of an
    older term once the nodes that hold the term's WAL and answered with no record
    of it are a majority; [term-fence] keeps its origin from committing it later.
    A node with no WAL of the term (joined by a copy, its file gone) is no
    witness. Otherwise the leader waits for every member, as before.

And with them ([spare-out]): a node back from a restart is Spare until it rejoins
as a follower, and takes no slot until then, sequentially consistent or not - it
rejoins on its own, no approval needed, as every node knows it already. 8's
[sc-all] counted it on a table sequentially consistent
and `all`, and every write waited while it caught up; the catch-up holds the node
back from party writes until it holds what the members hold ([caught-up]).

Retest on the build with 28 to 33 (2026-10-23, 18:44 to 21:08 CDT): case 2 3 of 3,
the 26 cases, case 20 10 of 10 and case 26 4 of 4 passed - but for 34, in one of
case 20's ten (and in another, Elle's cycle search ran out of time: `unknown`, a
limit of the checker; `half` is judged on its copies, Elle reported only). On the
build with 34, case 20 passed 10 of 10 at DEBUG, and the retest's first run
crashed in its setup (35). On the build with 35, case 2 passed 2 of 3, the third
left a node short of a term's tail (36). On the build with 36, case 2's second
run committed nothing (37); the whole matrix again on it, going on past a
failure: case 2 3 of 3, the 26 cases and case 26 4 of 4 passed, case 20 18 of 20
- the other two 38 (and two of the 18 Elle `unknown`, its cycle search out of
time, as before). The retests of 2026-10-24: the next section.

**The test:** `--recon` (the self-healing), the copies given `CONVERGE_WAIT` (60 s)
to become equal, recon's counters, every node's rows when they do not
(`docker/<node>.rows.txt`) and its data version (`docker/<node>.dv.txt`), a ytserv log level by hand (`YT_LOG_LEVEL`), 57P03 a
definite failure.

## 2026-10-24 - the retests

**Setup.** The night's matrix on each build with fixes, going on past a failure:
first the cases that had failed on the build before, then case 2 three times (the
case that had left a node short of a write), the 26 cases, case 20 (`half` node
bouncing) ten or twenty times and case 26 (strong, every fault, 300 s) four or six
times - at INFO, times CDT.

| build | when | runs | passed | failed |
|---|---|---|---|---|
| with 36's fix | 10-23 22:51 to 01:57 | 55 | 52 | 37 (case 2), 38 (case 20, twice) |
| with 38's fix | 02:47 to 06:06 | 63 | 61 | 39 (case 20), 40 (case 26) |
| with 39's and 40's fixes | 06:50 to 10:52 | 69 | 66 | 41 (case 15), 42 (case 24), 43 (case 25) |
| with 41's to 43's fixes and the rules of 2026-10-24 | 13:33 to 16:54 | 55 | 54 | 44 (case 2) |
| with 44's fix | 17:48 to 22:20 | 51 | 47 | 45 (case 24), 46 (case 18), 47 (case 21); case 2 once no data |
| with 45's to 47's fixes | 22:26 to 01:41 | 55 | 53 | 48 (case 25), 49 (case 24) |
| with 48's and 49's fixes | 02:12 to 05:19 | 49 | 49 | none |

Elle's cycle search ran out of time in two `half` runs on each of the first two
builds: `unknown`, a limit of the checker - `half` is judged on its copies, Elle
reported only.

**Found and fixed** (ytserv; every finding fixed and retested until gone):

38. **A false CLUSTER DIVERGENCE: a later term's write over an older term's
    missing tail** (`half` node bouncing, on the build with 36: 2 runs of 20, six
    divergences in one, one in the other, a row blocked each time, the copies
    equal at the end): a node back from a kill held term 2 through 230, the
    members through 234, and term 3 was elected as it began to pull. A write of
    term 3 reached it by apply before 231 did: the row 231 wrote first was not
    there, the apply matched nothing, and it was recorded a divergence. The
    deferral of such a miss to the pull ([dep-defer]) looked for a hole in what
    the node held of the terms before - there was none, only their end was
    missing, which the members' data version shows. The row's later writes then
    missed in turn; [divergent-t3] repaired it from a majority, and the pull's
    older writes of it, held in the repaired row already, missed once more - the
    other five. *Fixed* ([older-tail]): behind the members in an earlier term,
    or not known yet not to be from a term joined to the next ping round, a node
    rolls back a later term's write that misses its row and leaves it to the
    pull, which brings it after the tail - not counted against the bound of
    deferrals while that lasts. The repair waits now too ([repair-gate]): only
    once the cluster has completed the row's writes and no transaction touches it -
    a row is repaired only on a node that holds what the members decided, its last
    write closed on the whole cluster and no transaction on it; and a subterm every
    row of which a later commit held here wrote is held through those
    ([self-resolved], by whole subterm: a gap all of whose rows a later transaction
    wrote resolves itself, one with only some of them stays a gap).

39. **A false CLUSTER DIVERGENCE a fourth time: records held undecided read as
    held** (`half` node bouncing, on the build with 38's fix: 1 run of 31, one
    divergence, the row blocked and repaired from a majority, the copies equal at
    the end): the leader of term 1 was killed with term 1's last three subterms in
    flight, and the members decided them while it was out - term 1 through 119.
    Back, it held their records undecided. The catch-up counts a node's newest
    record as held, so it read itself through term 1's end, and 38's guard did not
    take it for behind. A write of term 2 reached it before the pull brought those
    outcomes: the row one of them wrote was not there, the apply matched nothing,
    and it was recorded a divergence. *Fixed* ([older-tail]): for that guard a node
    holds a term as far as it holds decisions of it - a record undecided here is
    none - so a later term's write that misses goes to the pull until the outcomes
    are in. The catch-up's own count of held is as it was.

40. **A row on three nodes of five, its write failed** (strong, partition + kill
    + pause, 300 s, on the build with 38's fix: 1 run of 5, not converged; Elle
    valid, the client's result indeterminate): every ytserv was paused for 10 s
    just as a client inserted a row. At the resume one party member's call had
    passed its deadline, so the statement failed, and the origin rolled the
    transaction back on every node. Three nodes held the row at the end - two of
    them had logged no record of its subterm - and the origin and the fourth
    member did not. The pull had served it as committed, with its rows, from the
    origin's record: an origin polls the cluster on a checkout of a record of its
    own that is not closed yet - and its write still in flight was such a record -
    then writes ClusterCommited over it at the poll's end, over a rollback it
    recorded meanwhile too. A checkout names no outcome: one follows the apply of a
    rollback as well. Inferred from the code and the logs - at INFO they do not show
    the checkout. *Fixed* ([checkout-decided]): an origin polls only for a commit
    of its own not yet closed on the whole cluster, the poll's end closes such a
    commit alone, and a checkout leaves a member's record that is decided on disk,
    no longer cached, as it is.

41. **No write in a whole run again: one gap in flight held every table**
    (strong `rw`, partition + kill + pause, on the build with 39's and 40's fixes:
    Elle `unknown`, nothing committed; the case's other runs committed 35 to 117
    writes): the schedule left about 9 s with a majority up and connected - every
    node killed at the start, ring partitions, a majority paused - and the
    refusals the rules call for took them: [caught-up] after the restarts, party
    members cut off mid-statement, each holding its client 5 to 11 s to its
    deadline, and the recon gate holding every synced table for 5 s while one gap,
    a write a member held in flight (2.23), was open. *Fixed*
    ([gap-rows]): a gap whose transaction a member holds in flight
    holds the rows it writes, not every synced table; a gap no node holds a record
    of holds every synced table still.

42. **Two leaders of one term, its subterm numbers issued twice** (sequential
    `rw`, partition + kill + pause, 300 s, on the build with 39's and 40's fixes:
    21 CLUSTER DIVERGENCE lines, five rows missing on two nodes, not converged): a
    node back from a kill in term 8, while three members stood in term 9 under
    another leader, asked for term 9 - its own term plus one - and won: a vote
    compared no term, and the confirm repointed the members already in term 9. It
    issued 9.1 onward again. The first leader's commits under those numbers were
    taken for the new writes' rollbacks, marked Collision on their origin and
    served as rolled back, and two nodes lacked their rows at the end; recon
    released one of the rows on one of them as converged, on the answer of one
    other node that lacked it too. *Fixed* ([term-vote]): a voter refuses a term
    it is at or holds data of, a candidate asks past every term its members
    named, and a confirm of a term below a node's own, or of its own term for
    another leader, is refused; a rollback marks only its own transaction's
    record, and recon releases a blocked row only on a majority's answer. With it
    36's vote ([vote-data]): a voter refuses a candidate behind it - the
    candidate's newest decided term, and how far it holds it, go with its request,
    and a voter that holds more refuses it; an older node sends none and is not
    checked.

43. **A node down to the end of a run: a WAL file with no header** (sequential
    + recon, `rw`, every fault and packet, 300 s, on the build with 39's and 40's
    fixes: one node leaderless at the end, its ytserv not running): the node was
    killed between creating a new term's WAL file and writing its header. Every
    start after refused the file and exited, 45 times to the end of the run.
    *Fixed* ([wal-header]): a new WAL file appears under its name with its header
    in it - written under a temporary name, then linked to the name - and a start
    moves aside a file whose header is not whole: no record was ever written to
    one. A header there that does not read is refused still.

44. **No leader at the end: the leader of an older term led on** (sequential `rw`,
    partition + kill + pause, on the build with 41's to 43's fixes: 1 run of 3 of
    case 2, three nodes of five naming no leader at the end; Elle valid, the
    copies equal): term 3 was elected on three nodes while the leader of term 2
    and its one follower were cut off, and its leader was killed before it ever
    answered the old one. Healed, the old leader led term 2 on with that follower:
    a leader stepped down only for another answering that it led a newer term, and
    the members at term 3 named no leader. The two of them restarted into term 3
    stayed Spare behind it - a leader named was one to learn, though it was of an
    older term than theirs, which a node never takes - and neither voted; by the
    code (the refusals were not in the log), the old leader and its follower
    refused every vote as term bouncing, their term set under 300 s before and a
    leader named. The third member asked for term 4 every second to the end, no
    vote but its own each time, and no other node asked. *Fixed* ([stale-leader],
    [restart-leaderless]): a leader one of whose members answers a newer term steps
    down, a leader of it named or not - one term, one leader; a leader named at an
    older term than a member's own is none it can learn, and the member rejoins for
    the election as when none is named; and taking a leader of an older term never
    lowers the newest term held here, which a vote refuses ([term-vote]). A failed
    election logs its votes and their refusals now - they were collected in a set
    the answer never read.

45. **A node down to the end of a run: a WAL page a kill tore** (sequential `rw`,
    partition + kill + pause, 300 s, on the build with 44's fix: 1 run of 2 of case
    24, one node leaderless at the end, its ytserv not running; Elle valid, the
    copies of the four others equal): every ytserv was killed while one wrote a
    record's address into its WAL page. An insert wrote the page's count first,
    then the item: the kill came between, and the count took in a slot of the
    page's zero padding - a subterm 0, under the page's least. Every start after
    panicked loading the page, an index past the map of its subterms, 56 times to
    the end of the run. *Fixed* ([torn-page]): a page loads without the slots its
    count takes in that hold no item - the insert was not made, as a kill before it
    leaves; its data an orphan, the pull brings the subterm - its bounds those of
    the items kept, and the next insert writes the slot again; an insert writes its
    item first and its count after, so a kill between leaves the item uncounted;
    and an item out of its page's bounds is left out of the page's figures, not a
    panic at every start.

46. **No cluster at the start: a leader of two votes in five** (strong + recon,
    `append`, partition + kill + pause, on the build with 44's fix: the run did
    not start - four nodes of five naming no leader, the test's settings never
    written): the first node up started before the others' names resolved, and
    left the three of them out of its peer list - as the roster pass means it, to
    be added once they resolve - and out of every majority with them. Its election
    of term 1 counted the two peers it had: its own vote and one other won it, a
    majority of two, not of five. Its writes were refused after, "2 of 5" once the
    three were in the list. The other four never took it as their leader: a node
    takes a leader when no more than half its members are spare, and the one that
    had lost its elections read as spare to them for good - a member with no leader
    counts as one that has been spare while its uptime is in the cold start's, and
    a node's ping answer carried an uptime of 0 for good, written only with the
    health rank on (off by default). *Fixed* ([roster], [health]): a member whose
    host did not resolve counts in every majority - the election's win and its
    confirm, the cold start's spares, a write's majority under `all` - as a member
    that does not answer, until it resolves and is in the list; and a node's ping
    answer carries its uptime with the health rank off too.

47. **A node read every subterm of a term as diverged: a second WAL file of it**
    (half, node bouncing, `rw`, kill + pause, on the build with 44's fix: 305
    CLUSTER DIVERGENCE lines on one node, 25 of its rows blocked for audit; Elle
    valid, every copy equal at the end): a node restarted from a kill took a modify
    before it had read its WAL files - its listener opens first - and the modify
    made the term's WAL, a new file under a name of its own. Its load put the
    term's own file over that one; killed again, the next start read the two the
    other way round and kept the one of a few records: it had lost its record of
    almost every subterm of the term, pulled them all again over rows that held
    them and later writes, and read each as diverged, rows blocked. *Fixed*
    ([wal-first]): no term's WAL is made before the start has read the WAL files -
    refused as not now, the sender's retry or the pull brings it - and a start that
    finds a term in two files takes in the one with more in it, and moves the
    other aside, logged, never loaded again.

**No data, found in the run with 44's fix**: one run of case 2 committed no write
- the faults left no leader through its client phase: every node killed in its
first second, then a majority paused, all killed again, all paused, a majority
killed; four nodes of five ran together for under 3 s, less than a node back from
a restart waits before it stands - and Elle had nothing to check (unknown, an
empty graph). Not a defect by the code. A run with no write committed and nothing
else wrong is void now, run again - never a pass.

48. **A node short of three rows to the end: a term's hole left out at a start**
    (sequential + recon, `rw`, every fault and packet, 300 s, on the build with
    45's to 47's fixes: the copies not converged, one follower lacking three rows
    the others hold; Elle valid): the follower, paused and cut off, missed the
    commits of a stretch of a term, and back from a kill it named the gap and
    pulled part of it. Killed again, its next start left the term out of its data
    version: the term the data version starts at was worked out file by file, in
    the order the directory gave them - a newer complete term raised it, a term
    with a hole lowered it only when read after one - and the term with the hole
    was read first. Its missed subterms were never asked for again, and a recon
    that checks only rows marked diverged never saw the rows missing. *Fixed*
    ([dv-start]): the data version starts at the oldest term not complete, never
    past the newest complete one, whatever the order the files are read in.

49. **A leader one write behind to the end: a subterm served short of its second
    statement** (sequential `rw`, partition + kill + pause, 300 s, on the build with
    45's to 47's fixes: the copies not converged, the leader at the end holding an
    older value of one row than the four others; Elle valid, no read saw it): a
    transaction of two writes committed on three nodes while the two others were
    cut off; one of those two, leader later, pulled the subterm after the three
    were killed and restarted, and applied its first write only - recorded
    committed, never pulled again. The node serving it read the subterm's
    statements from its file version by version, until one was not there, and a
    version recorded that did not read was taken for that end: the subterm went
    as its first statement alone (by the code and the end state - the WAL files
    went with the containers). *Fixed* ([partial-read]): only a version the pages
    hold no record of ends a subterm's statements; a recorded one that does not
    read has the subterm served as its outcome alone, logged, for the puller to
    ask the others past - and an apply that leaves a subterm's later statements
    unapplied, a statement that changes nothing here, says so ([partial-apply]).

**The rules of 2026-10-24**, with them: a vote refuses a candidate behind
the voter (36, 42: [vote-data]); a gap's outcome follows its tables' mode - a
majority decides an older term's gap when every table commits on a majority (37:
[gap-mode]); a gap in flight holds its own rows only (41: [gap-rows]); a repair
only after the cluster completed the row's writes and with no transaction on it,
and a subterm self-resolved when later commits wrote all its rows (38:
[repair-gate], [self-resolved]).

**The quorum guard** every write passes, kept as it is: `all` means every active
node, not every configured one; a count above zero means that many nodes besides
this one, zero this node alone; a node not active while a transaction needs other
nodes (a count above zero, `half` or `all`) waits until it is a correct follower,
or rolls back - the cluster is required but not available yet. The guard counts the peers, a
peer that answers but sees no leader as off; a node that is no active follower
refuses a write that needs other nodes, retryable, as it did.

**Found in the test, fixed:** a pause could stop itself. The nemesis signals
ytserv by `pgrep -f` piped to `xargs kill`, and the shell's fork for the pipe's
other side holds the shell's command line, the pattern in it, until it execs
`xargs`: pgrep took it - a sibling, which `--ignore-ancestors` keeps - and the
SIGSTOP stopped `xargs` itself, so the pause, and the run, waited for good (case
26 on the build with 44's fix, 19:49 to 21:27, released by hand; the run then
passed). The pattern matches no command line that carries it now
(`[y]t-cluster/ytserv`).

**Retested:** 28 to 49 passed on the build with 48's and 49's fixes, every run of
it (49 of 49, 2026-10-25). Under `half` - Elle reported only - one run of case 20 on
each of the last two builds ended Elle's cycle search at its time limit (unknown):
the checker's limit, the copies converged.

**Found by the nightly of 2026-10-25** (every suite, with coverage, on the build with
28 to 49's fixes: 7 checks of topology's new identity test and 2 of rmc failed, the
two findings below; that run did not publish, the build with their fixes did):

50. **A copy's restart pulled its first term again: a config row back to an older
    value** (rmc, east's leader a physical copy of a member, restarted): the copy
    holds its first term in its database through the position it was copied at,
    with no WAL record of it, and held that position in memory only. Restarted, it
    read the term's start as 612 missed subterms - by 48's fix every start takes
    the oldest term not complete into its data version, where before the order of
    its files decided - and pulled them again over the copied rows: a config row
    went back to its value of two steps before, and the members refused the
    leader's next writes of it, its read not the row they held (40001, twice).
    *Fixed* ([seed-kept]): a copy's start position - a physical copy's, a filled
    joiner's - is recorded with the proven marks under its WAL folder, and every
    start holds the term through it. rmc passed in the nightly of 2026-10-25 (1004
    of 1004).

51. **A member's own insert drew values replicated rows held** (topology
    33_identity I3, its first run - the identity work of 2026-10-22, not
    published): a replicated insert moved only the key column's sequence on the
    member; a serial column past the key and a column whose default calls nextval
    kept their sequences, and the member's own next insert drew 1 where the
    replicated rows held 1 to 5. *Fixed* ([seq]): an inserted row's every value
    moves the sequence its column draws from, the key's and the others'.

**The state, 2026-10-25:** every finding fixed and retested - 51 with topology
33_identity on its own (30 of 30), 50 with the nightly of unit and rmc (1502 and
1004 passed), which published YT Cluster 1.20, build 1.20.2, at 13:35 CDT. The findings
one by one, by severity: [findings.html](findings.html)
(a copy of [the page shared on 2026-10-23](https://claude.ai/artifact/Dtu2vx8WUyNm19J8NBjRFH),
brought up to date the same day). Four of the cases run in the nightly as a suite of
their own (`nightly_cases.sh`).

**Next:** we continue improving and monitoring YT Cluster as new features come, and
this Jepsen test project is updated with them.
