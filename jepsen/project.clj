(defproject jepsen.ytcluster "0.1.0"
  :description "Jepsen tests of YT Cluster, run by hand (jepsen/run.sh)"
  :url "https://github.com/DBinvent/yt-cluster-tests"
  :license {:name "PolyForm Noncommercial 1.0.0, or a commercial license: LICENSE at the repository root"}
  :main jepsen.ytcluster
  ; pinned: jepsen 0.3.14 and io.jepsen/sql 0.1.1 (2026-09-22), next.jdbc and
  ; pgjdbc as io.jepsen/sql builds and tests with
  :dependencies [[org.clojure/clojure "1.12.6"]
                 [jepsen "0.3.14"]
                 [io.jepsen/sql "0.1.1"]
                 [com.github.seancorfield/next.jdbc "1.3.1118"]
                 [org.postgresql/postgresql "42.7.13"]]
  :jvm-opts ["-Xmx6g" "-Djava.awt.headless=true" "-server"])
