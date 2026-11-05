# Code coverage

The lines of YT Cluster's Rust code that the nightly's tests ran: the unit tests and
every end-to-end suite, against an instrumented ytserv and ytctl
([coverage.sh](coverage.sh) says what counts). The coverage badge shows ytserv's figure.

Written from [coverage.yaml](coverage.yaml): run 20261025-105906, measured 2026-10-25
on ytserv 1.20.2, run result: fail. A run measures only when asked or when that file is
missing, so the figures can be older than the newest release.

## By crate

| Crate | Lines | Covered | By unit tests | By end-to-end suites |
|---|--:|--:|--:|--:|
| ytcluster-common | 167 | 83.8% | 52.7% | 47.3% |
| ytcluster-types | 1,813 | 74.0% | 68.7% | 26.5% |
| ytctl | 17,293 | 38.4% | 27.0% | 14.0% |
| ytserv | 51,777 | 81.2% | 52.8% | 52.4% |
| **All** | **71,050** | **70.6%** | | |

## By suite

The share of all those lines each one ran alone. They overlap, so they do not add up.

| Suite | Lines it ran |
|---|--:|
| unit tests | 46.9% |
| all end-to-end suites together | 42.4% |
| hier | 23.4% |
| llm | 11.5% |
| lxc | 10.8% |
| rmc | 23.9% |
| topo | 27.7% |
| topo-faults | 27.6% |
| topo-membership | 24.2% |
| topology | 27.2% |
| topology-py | 20.1% |
