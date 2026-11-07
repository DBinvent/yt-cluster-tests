# Code coverage

The lines of YT Cluster's Rust code that the nightly's tests ran: the unit tests and
the end-to-end suites below, against an instrumented ytserv and ytctl
([coverage.sh](coverage.sh) says what counts). Not counted: migrate and jepsen, whose
counts are not collected. The coverage badge shows ytserv's figure.

Written from [coverage.yaml](coverage.yaml): run 20261106-120116, measured 2026-11-06
on ytserv 1.20.12, run result: pass. The first nightly with no new code measures
again, so the figures can be days behind the newest release.

## By crate

| Crate | Lines | Covered | By unit tests | By end-to-end suites |
|---|--:|--:|--:|--:|
| ytcluster-common | 167 | 86.8% | 55.7% | 47.3% |
| ytcluster-types | 1,362 | 76.1% | 70.0% | 35.8% |
| ytctl | 16,067 | 42.6% | 29.9% | 15.5% |
| ytserv | 56,170 | 88.2% | 56.9% | 58.5% |
| **All** | **73,766** | **78.1%** | | |

## By suite

The share of all those lines each one ran alone. They overlap, so they do not add up.

| Suite | Lines it ran |
|---|--:|
| unit tests | 51.3% |
| all end-to-end suites together | 48.7% |
| hier | 24.6% |
| llm | 12.0% |
| lxc | 12.5% |
| rmc | 25.2% |
| topo | 29.5% |
| topo-faults | 29.2% |
| topo-membership | 25.8% |
| topology | 34.7% |
| topology-py | 21.8% |
