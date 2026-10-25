(ns jepsen.ytcluster
  "Jepsen against YT Cluster: PostgreSQL where every node takes writes, ytserv
  beside each node. The workloads are jepsen.sql's - list append and rw over
  JDBC, judged by Elle - written on every node at once, under network
  partitions, packet faults, and ytserv killed or paused. The nodes are
  containers that set themselves up (docker/, run.sh): the db here waits for
  each to name a leader, the client puts the workload's tables on every node
  and on the cluster, and the nemesis kills or pauses ytserv.

  Correctness only - no performance graphs. Run by hand (run.sh), and four of
  its cases in the nightly (nightly_cases.sh)."
  (:require [clojure.string :as str]
            [jepsen [checker :as checker]
                    [cli :as cli]
                    [client :as client]
                    [control :as c]
                    [db :as db]
                    [generator :as gen]
                    [sql :as sql]
                    [tests :as tests]
                    [util :as util]]
            [jepsen.core]
            [jepsen.checker.timeline :as timeline]
            [jepsen.nemesis.combined :as nc]
            [next.jdbc :as j]
            [next.jdbc.result-set :as rs]
            [slingshot.slingshot :refer [try+]])
  (:import (org.postgresql.util PSQLException)))

(def db-name
  "The database the nodes replicate: their POSTGRES_DB (run.sh)"
  "app")

(def ytserv
  "What ytserv's command line holds, for pgrep -f: the entrypoint runs
  /usr/local/bin/yt-cluster/ytserv. Fixed: a pattern the command carrying it
  does not match - the shell's fork for the pipe's other side holds that command
  line until it execs xargs, a sibling --ignore-ancestors keeps, and a pause
  stopped xargs itself: the nemesis waited for good (case 26, 2026-10-25)"
  "[y]t-cluster/ytserv")

;; ── The nodes ────────────────────────────────────────────────────────────────

(def cluster-row-sql
  "yt_info('o')'s cluster row: `Term: 3, for 2min., Leader: 9c..e14d9a:n2:7421` on a
  follower, `..., Leader` on the leader, `..., Leader: None!` while there is none"
  "select value from json_to_recordset(yt_info('o')) as x(name text, value text) where name = 'cluster'")

(defn leader-known?
  "Whether this node's ytserv answers through its extension and names a leader"
  []
  (let [row (c/exec :psql :-X :-tA :-U :postgres :-d db-name :-c cluster-row-sql)]
    (boolean (and (re-find #"Leader" row)
                  (not (re-find #"None|discrepancy" row))))))

(defn await-node
  "Waits for this node's cluster to name a leader: the node set itself up on
  its first start"
  [node]
  (util/await-fn
    (fn ready []
      (or (leader-known?)
          (throw (ex-info "no leader yet" {:node node}))))
    {:timeout        300000
     :retry-interval 2000
     :log-interval   15000
     :log-message    (str "Waiting for " node "'s cluster to name a leader...")}))

(defn await-ytserv
  "Waits for this node's ytserv process - the entrypoint starts a killed one
  again 5 s later. Not for a leader: the nemesis is one worker, and a node still
  paused would hold the election, and so the resume, off for good."
  [node]
  (util/await-fn
    (fn running [] (c/exec :pgrep :-f :--ignore-ancestors ytserv))
    {:timeout        60000
     :retry-interval 1000
     :log-interval   10000
     :log-message    (str "Waiting for " node "'s ytserv to start again...")}))

(defn leader?
  "Whether this node's ytserv leads: its cluster row names no other node"
  []
  (let [row (c/exec :psql :-X :-tA :-U :postgres :-d db-name :-c cluster-row-sql)]
    (boolean (re-find #"Leader\s*$" row))))

(defn majority
  "More than half of n"
  [n]
  (inc (quot n 2)))

(defn settings
  "The catalog C rows the test runs with - YT Cluster set as Jepsen expects a
  consistent database to behave, the same for every table, never fewer than
  half the nodes:
  - def_cluster_commit: how many nodes a commit takes (--commit) - all, the
    strict refusal (ytserv config.md: under half a conflict with a node outside
    the party is reported after the commit), or half, rounded up;
  - min_cluster_size: the nodes an election needs - a majority, so the
    majority side of a partition elects (the image sets every node: one node
    down held every election off);
  - def_sql_timeout_sec: how long a node may take to execute a statement before
    it refuses (--sql-timeout). Static, well inside the client's socket timeout
    (30 s, open): the cluster decides - a definite answer - before the client
    gives up, which leaves the operation indeterminate."
  [test]
  {"def_cluster_commit"  (name (:commit test))
   "min_cluster_size"    (str (majority (count (:nodes test))))
   "def_sql_timeout_sec" (str (:sql-timeout test))})

(defn effective
  "A setting's value in effect on this node for the replicated database"
  [setting]
  (str/trim
    (c/exec :psql :-X :-tA :-U :postgres :-d db-name :-c
            (str "select value from json_to_recordset(yt_info('c:" setting "'))"
                 " as x(name text, value text) where name = 'effective'"))))

(defn configure!
  "The leader writes the test's settings into the catalog - cluster settings
  live there, and a config row written on the leader reaches every node and
  applies at once; every node waits until it runs with them. Each round the
  node that leads writes them again - an upsert: the cluster may refuse one
  for a while (once `all` holds, a node still catching up takes no write), and
  the leader may change - and the round ends when this node runs with all."
  [test node]
  (let [want (settings test)]
    (util/await-fn
      (fn applied []
        (when (leader?)
          (doseq [[k v] want]
            (c/exec :psql :-X :-v "ON_ERROR_STOP=1" :-U :postgres :-d :postgres :-c
                    (str "insert into public.yt_config (name, module, value) values ('" k "', 'C', '" v "')"
                         " on conflict (module, name) do update set value = excluded.value"))))
        (let [got (into {} (map (juxt key (comp effective key))) want)]
          (or (= got want)
              (throw (ex-info "settings not in effect yet" {:node node, :want want, :got got})))))
      {:timeout        60000
       :retry-interval 1000
       :log-interval   10000
       :log-message    (str "Waiting for " node " to run with " want "...")})))

(defn signal!
  "Sends this node's ytserv a signal, as cu/grepkill! would: in jepsen 0.3.14
  that one sends none - its command sits inside its timeout form, so its body is
  empty and it returns at once. A ytserv already gone (between a kill and its
  restart) is no error."
  [signal]
  (try+ (c/exec :pgrep :-f :--ignore-ancestors ytserv
                c/| :xargs :--no-run-if-empty :kill (str "-" signal))
        (catch [:type :jepsen.control/nonzero-exit, :exit 123] _ nil)))

(defn db
  "The cluster as the containers run it. setup! waits for each node and puts
  the test's settings on the cluster; kill! and pause! act on ytserv - the
  node's PostgreSQL stays up (its exit ends the container) - and the entrypoint
  starts a killed ytserv again 5 s later, so start! waits for the process. The
  nodes' logs are their containers' (docker logs): run.sh keeps them beside the
  store."
  []
  (reify
    db/DB
    (setup! [_ test node]
      (await-node node)
      (configure! test node))
    (teardown! [_ test node])

    db/Kill
    (kill! [_ test node] (signal! 9))
    (start! [_ test node] (await-ytserv node))

    db/Pause
    (pause! [_ test node] (signal! 19))
    (resume! [_ test node] (signal! 18))))

;; ── The client ───────────────────────────────────────────────────────────────

(defn open
  "A JDBC connection to the node's PostgreSQL, in the database the nodes
  replicate. Short timeouts: under a partition a call fails - an indeterminate
  operation - rather than holding its worker. With --delta the session says its
  SQL is a delta (yt_cluster.delta)."
  [test node]
  (let [conn (j/get-connection
               (j/get-datasource {:dbtype         "postgresql"
                                  :host           node
                                  :port           5432
                                  :dbname         db-name
                                  :user           "postgres"
                                  :password       (:pg-password test)
                                  :sslmode        "disable"
                                  :connectTimeout 5
                                  :loginTimeout   10
                                  :socketTimeout  30
                                  :tcpKeepAlive   true}))]
    (when (:delta test)
      (j/execute! conn ["set yt_cluster.delta = on"]))
    conn))

(def definite-states
  "SQLSTATEs after which a transaction is known to have left nothing anywhere:
  ytserv's verdicts, refused on purpose before a commit was decided - 40001
  (retry), 55409 (a row a concurrent write changed: do not retry), 55000, 40P01;
  57P03, the cluster cannot take the write now (no leader, not joined, short of
  nodes, ytserv unreachable) - the write was not taken."
  #{"40001" "40P01" "55409" "55000" "57P03"})

(defn refused-by-trigger?
  "Did the extension's row trigger raise it? `yt_synchronize: ...` - the
  cluster not ready, short of nodes, ytserv unreachable. The statement failed,
  so its transaction cannot commit, whatever SQLSTATE it came with: a refusal
  without a code of its own still reaches the client as 08006, a connection
  failure, though nothing was lost. A COMMIT's errors name another function."
  [^PSQLException e]
  (boolean (some-> e .getServerErrorMessage .getMessage (str/starts-with? "yt_synchronize:"))))

(defn error-fn
  "What an error left behind (jepsen.sql's contract): a definite one nothing, so
  the operation failed; anything else - a connection lost, a timeout, 08006 -
  may have committed, so it is indeterminate. A duplicate key and a statement in
  an aborted transaction are local to the statement: definite, and so is a
  statement the row trigger refused."
  [e]
  (when (instance? PSQLException e)
    (let [state (.getSQLState ^PSQLException e)]
      (cond
        (= "23505" state)              {:type :duplicate-key-value, :definite? true}
        (= "25P02" state)              {:type :txn-aborted, :definite? true}
        (contains? definite-states state) {:type :aborted, :sqlstate state, :definite? true}
        (refused-by-trigger? e)        {:type :refused, :sqlstate state, :definite? true}
        (and state (str/starts-with? state "08")) {:type :connection-lost, :sqlstate state}
        (= "57014" state)              {:type :canceled, :sqlstate state}
        :else                          nil))))

(def unsynced-tables-sql
  "This database's tables a workload made: keyed, not the extension's, not yet
  carrying the sync trigger"
  "select n.nspname || '.' || c.relname as rel
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where c.relkind in ('r', 'p')
      and n.nspname not in ('pg_catalog', 'information_schema')
      and n.nspname not like 'pg_toast%'
      and not exists (select 1 from pg_depend d where d.classid = 'pg_class'::regclass
                         and d.objid = c.oid and d.deptype = 'e')
      and exists (select 1 from pg_index i where i.indrelid = c.oid and i.indisprimary)
      and not exists (select 1 from pg_trigger t join pg_proc p on p.oid = t.tgfoid
                       where t.tgrelid = c.oid and p.proname = 'yt_synchronize')")

(defn put-on-cluster!
  "The workload's tables on this node's side of the cluster: each one's sync
  trigger and table config row, as yt_setup puts a table there on a node"
  [conn]
  (doseq [{:keys [rel]} (j/execute! conn [unsynced-tables-sql]
                                    {:builder-fn rs/as-unqualified-lower-maps})]
    (j/execute! conn ["select count(*) from yt_setup(?, '', true)" rel])))

(def sc-tables-sql
  "The workload's table rows in this database's config table: module A, the
  tables a workload made, not the extension's own"
  "select name from yt_config where module = 'A' and name like 'public.%' and name not like 'public.yt\\_%'")

(defn leads?
  "Whether the node behind this connection leads its cluster"
  [conn]
  (let [row (-> (j/execute-one! conn [cluster-row-sql] {:builder-fn rs/as-unqualified-lower-maps}) :value)]
    (boolean (and row (re-find #"Leader\s*$" row)))))

(defn sc-in-effect?
  "Whether every workload table runs sequentially consistent on this node"
  [conn]
  (let [tables (map :name (j/execute! conn [sc-tables-sql] {:builder-fn rs/as-unqualified-lower-maps}))]
    (and (seq tables)
         (every? (fn [t]
                   (some-> (j/execute-one! conn [(str "select value from json_to_recordset(yt_info('a:" t "'))"
                                                      " as x(name text, value text) where name = 'sequential_consistency'")]
                                           {:builder-fn rs/as-unqualified-lower-maps})
                           :value (str/starts-with? "1")))
                 tables))))

(def recon-cfg
  "--recon's ReconCfg, as yt_ct_decode shows it: repair (mode 2), a round once 20
  changed rows queued or the oldest is 2 s old, 3 rounds before a row is blocked"
  "{\"mode\":2,\"rows\":20,\"timeout_sec\":2,\"max_attempts\":3}")

(defn recon-in-effect?
  "Whether every workload table reconciles its rows (recon repair) on this node"
  [conn]
  (let [tables (map :name (j/execute! conn [sc-tables-sql] {:builder-fn rs/as-unqualified-lower-maps}))]
    (and (seq tables)
         (every? (fn [t]
                   (some-> (j/execute-one! conn [(str "select yt_ct_decode(value)::jsonb #>> '{value,Table,recon,mode}' as mode"
                                                      " from json_to_recordset(yt_info('a:" t "'))"
                                                      " as x(name text, value text) where name = 'raw'")]
                                           {:builder-fn rs/as-unqualified-lower-maps})
                           :mode #{"2" "ReconRepair"}))
                 tables))))

(def commit-modes
  "ClusterCommitCfg's mode for --commit, as yt_ct_decode shows it"
  {:half 1, :all 3})

(defn table-cfg-sql
  "The update of every workload table's row: --sc's sequential_consistency 1 and
  cluster_commit (--commit), --recon's ReconCfg"
  [test]
  (let [v (cond-> "yt_ct_decode(value)::jsonb"
            (:sc test)    (as-> v (str "jsonb_set(jsonb_set(" v ", '{value,Table,sequential_consistency}', '1'),"
                                       " '{value,Table,cluster_commit}', '{\"at_least\":0,\"mode\":"
                                       (commit-modes (:commit test)) "}')"))
            (:recon test) (as-> v (str "jsonb_set(" v ", '{value,Table,recon}', '" recon-cfg "')")))]
    (str "update yt_config set value = yt_ct_encode(" v "::text)"
         " where module = 'A' and name in (" sc-tables-sql ")")))

(defn configure-tables!
  "Every workload table configured before the workload: --sc (the default)
  sequentially consistent (sequential_consistency 1) with its own cluster_commit
  (--commit, all by default), each party member running the transaction at its
  origin's isolation level; --recon reconciling its
  rows - a copy that differs repaired from the majority, or the row blocked: the
  self-healing. Every node has made its tables and their rows first (the barrier);
  the leader then updates the rows - replicated, a table row written so applies at
  once on every node - and each node waits until it runs with them."
  [test conn node]
  (jepsen.core/synchronize test)
  (util/await-fn
    (fn cfg []
      (when (leads? conn)
        (j/execute! conn [(table-cfg-sql test)]))
      (or (and (or (not (:sc test)) (sc-in-effect? conn))
               (or (not (:recon test)) (recon-in-effect? conn)))
          (throw (ex-info "table configuration not in effect yet" {:node node}))))
    {:timeout        60000
     :retry-interval 1000
     :log-interval   10000
     :log-message    (str "Waiting for " node "'s tables to run as configured...")}))

(defrecord YtClient [inner node]
  client/Client
  (open! [this test node]
    (assoc this :node node :inner (client/open! inner test node)))

  ; DDL does not replicate: every node makes the workload's tables, as the
  ; workload makes them on the primary - this node first in the node list - and
  ; puts them on the cluster. Jepsen runs this on every node at once.
  (setup! [_ test]
    (client/setup! inner (assoc test :nodes (into [node] (remove #{node}) (:nodes test))))
    (put-on-cluster! (:conn inner))
    (when (or (:sc test) (:recon test))
      (configure-tables! test (:conn inner) node)))

  (invoke! [_ test op] (client/invoke! inner test op))

  ; Not the workload's teardown, which drops the tables: the containers go with
  ; them anyway (run.sh), a --keep run leaves them to look at, and a DROP waits
  ; for every lock on its table - a write the cluster never finished holds one.
  (teardown! [_ test])
  (close! [_ test] (client/close! inner test)))

;; ── The test ─────────────────────────────────────────────────────────────────

(def workloads
  "jepsen.sql's workloads, opening connections and judging errors as above"
  (sql/workloads {:open open, :error-fn error-fn}))

(def all-faults
  "What the nemesis may do. No clock: the nodes are containers, and containers
  share their host's clock - a clock fault would set the docker host's own."
  #{:partition :packet :kill :pause})

(defn parse-faults
  "partition,kill or none"
  [s]
  (if (= "none" s)
    #{}
    (set (map keyword (str/split s #",")))))

(defn nemesis
  "The faults' nemesis and generators: nemesis-package's, but of the packages
  for these faults only. nemesis-package also sets up the ones no test asks
  for - file corruption fetches bitflip from GitHub on every node, the clock
  one builds its tools there and resets the clock."
  [opts]
  (nc/compose-packages [(nc/partition-package opts)
                        (nc/packet-package opts)
                        (nc/db-package opts)]))

(defn yt-test
  "The test map, from the CLI options"
  [opts]
  (let [wname    (:workload opts)
        workload ((workloads wname) opts)
        db       (db)
        nemesis  (nemesis
                   {:db        db
                    :nodes     (:nodes opts)
                    :faults    (:faults opts)
                    :partition {:targets [:one :majority :majorities-ring]}
                    :packet    {:targets   [:one :all]
                                :behaviors [{:delay {}} {:loss {}}]}
                    :kill      {:targets [:one :majority :all]}
                    :pause     {:targets [:one :majority :all]}
                    :interval  (:nemesis-interval opts)})]
    (merge tests/noop-test
           opts
           {:name      (str "yt-cluster " (name wname) " " (name (:isolation opts))
                            " " (name (:commit opts))
                            (when (:sc opts) " sc")
                            (when (:recon opts) " recon")
                            (when (seq (:faults opts))
                              (str " " (str/join "," (sort (map name (:faults opts))))))
                            (when (:delta opts) " delta"))
            :db        db
            :client    (map->YtClient {:inner (:client workload)})
            :nemesis   (:nemesis nemesis)
            ; correctness only: no checker/perf
            :checker   (checker/compose
                         {:workload   (:checker workload)
                          :stats      (checker/stats)
                          :exceptions (checker/unhandled-exceptions)
                          :timeline   (timeline/html)})
            :generator (gen/phases
                         (->> (:generator workload)
                              (gen/stagger (/ (:rate opts)))
                              (gen/nemesis (:generator nemesis))
                              (gen/time-limit (:time-limit opts)))
                         (gen/log "Healing the cluster")
                         (gen/nemesis (:final-generator nemesis))
                         (gen/log "Giving the cluster time to recover")
                         (gen/sleep (:recovery-time opts))
                         (gen/clients (:final-generator workload)))})))

(def cli-opts
  "Options of this test, over jepsen.sql's (cli-opts there) and Jepsen's own"
  [["-w" "--workload NAME" "A jepsen.sql workload: append (lists of integers) or rw (registers), both judged by Elle"
    :default  :append
    :parse-fn keyword
    :validate [#{:append :rw} (cli/one-of #{:append :rw})]]

   [nil "--nemesis FAULTS" "Comma-separated faults - partition, packet, kill, pause - or none. No clock: the nodes are containers, which share their host's clock"
    :id       :faults
    :default  #{:partition :kill :pause}
    :parse-fn parse-faults
    :validate [(partial every? all-faults) (cli/one-of all-faults)]]

   [nil "--rate HZ" "Approximate operations per second, every client together"
    :default  50
    :parse-fn read-string
    :validate [#(and (number? %) (pos? %)) "Must be a positive number"]]

   [nil "--commit MODE" "How many nodes a commit takes (def_cluster_commit): all, the strict refusal, or half, rounded up. Never fewer than half"
    :default  :all
    :parse-fn keyword
    :validate [#{:half :all} (cli/one-of #{:half :all})]]

   [nil "--sql-timeout SECS" "How long a node may take to execute a statement before it refuses (def_sql_timeout_sec): inside the client's 30 s socket timeout"
    :default  5
    :parse-fn parse-long
    :validate [#(and % (<= 1 % 20)) "Must be 1 to 20 seconds"]]

   [nil "--recovery-time SECS" "How long the healed cluster gets before the final reads"
    :default  20
    :parse-fn parse-long
    :validate [pos? "Must be positive"]]

   [nil "--[no-]delta" "Every session sets yt_cluster.delta: a conflicting row is retryable (40001) rather than refused (55409)"
    :default false]

   [nil "--[no-]sc" "Every workload table configured before the workload: sequential_consistency 1 and its own cluster_commit (--commit) - with all, what YT Cluster holds serializable across nodes"
    :default true]

   [nil "--[no-]recon" "Every workload table reconciles its rows (recon repair): a copy that differs is repaired from the majority, or the row blocked - the self-healing"
    :default false]

   [nil "--[no-]savepoints" "May an insert in a transaction roll back to a savepoint on a duplicate key? Off: the duplicate fails the transaction"
    :default false]

   [nil "--pg-password PASS" "The postgres user's password on every node (run.sh's POSTGRES_PASSWORD)"
    :default "jepsen"]])

(defn -main
  "lein run test --workload append ... - or lein run serve, to browse the store"
  [& args]
  (cli/run! (merge (cli/single-test-cmd {:test-fn  yt-test
                                         :opt-spec (cli/merge-opt-specs sql/cli-opts cli-opts)
                                         :opt-fn   sql/opt-fn})
                   (cli/serve-cmd))
            args))
