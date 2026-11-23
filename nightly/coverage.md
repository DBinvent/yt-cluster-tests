# Code coverage

The lines of YT Cluster's Rust code that the nightly's tests ran: the unit tests and
the end-to-end suites below, against an instrumented ytserv and ytctl
([coverage.sh](coverage.sh) says what counts). Not counted: migrate and jepsen, whose
counts are not collected. The coverage badge shows ytserv's figure.

Written from [coverage.yaml](coverage.yaml): run 20261120-043256, measured 2026-11-20
on ytserv 1.21.3, run result: pass. The first nightly with no new code measures
again, so the figures can be days behind the newest release.

## By crate

| Crate | Lines | Covered | By unit tests | By end-to-end suites |
|---|--:|--:|--:|--:|
| ytcluster-types | 1,122 | 94.7% | 90.6% | 31.1% |
| ytctl | 26,938 | 78.0% | 75.4% | 9.4% |
| ytserv | 70,987 | 94.0% | 82.1% | 45.6% |
| **All** | **99,047** | **89.7%** | | |

## By suite

The share of all those lines each one ran alone. They overlap, so they do not add up.

| Suite | Lines it ran |
|---|--:|
| unit tests | 80.4% |
| all end-to-end suites together | 35.6% |
| hier | 17.6% |
| llm | 8.6% |
| lxc | 9.2% |
| rmc | 19.5% |
| topo | 21.1% |
| topo-faults | 20.7% |
| topo-membership | 18.5% |
| topology | 25.4% |
| topology-py | 15.5% |
