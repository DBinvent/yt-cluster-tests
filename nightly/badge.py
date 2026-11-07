#!/usr/bin/env python3
"""Render the newest nightly run as two badge images, served from the apt host, and the
coverage table the second one links to.

    nightly/badge.py                    # results.yaml next to this file -> nightly/badge.svg, coverage.svg
    nightly/badge.py --out PATH         # the first image there, coverage.svg beside it (nightly.sh: REPO_DIR/paks/nightly/)
    nightly/badge.py --print            # print the badges and the shields.io URLs, fetch and write nothing

The badges are what dbinvent.com shows next to the release it announces, read through its
own Worker from these two (owner, 2026-11-05: [nightly|<version>: <total> tests] [coverage|81%]):

    https://apt.dbinvent.com/paks/nightly/badge.svg       nightly | 1.2.0: 5.6K tests
                                                          nightly | 1.2.0: 5.6K tests · 1 failed
    https://apt.dbinvent.com/paks/nightly/coverage.svg    coverage | 81%

The total is every suite's checks, the unit tests too, in thousands with one decimal (5,624
is 5.6K). The coverage is ytserv's. Green says they all passed.

A promoted run may have run only some suites (nightly.sh --force --suites unit, to publish
after a run that passed every suite but could not publish, 2026-10-20). So the total is by
suite, for the deb: its checks in this run, else in the newest earlier run of the same deb
where that suite passed. A suite this deb never passed counts nothing.

The badge is the newest promotion: the newest run that published its package
(`published:` set in results.yaml). A run that failed, or passed and published
nothing, does not move it - it vouches for what can be installed. nightly.sh calls this
after a run that published, and after a green run for coverage alone: then the nightly
badge comes out the same, from the same promotion, and the coverage badge is new.

The nightly badge's message is the ytserv tested, the total and how it went. A promoted
run passed every suite, so it is green; red is only for an entry that says
published but failed, which nightly.sh never writes. A suite skipped for a missing
outside service is named, unless an earlier run of the deb passed it: it tested nothing,
and a green badge should not hide that. Coverage is ytserv's line coverage, unit and end-to-end tests together,
from coverage.yaml - the last measurement: the first night with no new code after a green
run measures (nightly.sh), so the coverage badge is a day late at best.

coverage.md, next to this file, is the table behind the coverage badge: coverage.yaml by
crate and by suite. Written with the badges, and pushed to the public repository with the
rest of it.

The images are drawn here, at the end of the run: shields.io's static badge renders
label, message and color into an SVG, and the SVG is written in place of the old
one (a temp file renamed over it, so a fetch never sees half of it). Nothing reads
them from GitHub, so no push is needed: under /paks/ the apt host's nginx serves a
name with no version in it as max-age=300, must-revalidate, and Cloudflare follows
that - a new badge is on the page within ten minutes, each image on its own clock.
shields.io unreachable (after a few tries): nothing written, the previous badges stay,
exit 1. coverage.yaml unreadable: the nightly badge is still drawn, the coverage badge and
table stay as they are, and stderr says so.

Only the tail of results.yaml is read: the file only grows, and the newest
promotion is the last `- run` entry with `published:` set - the last TAIL lines,
then four times as many, until one is found or the whole file was read.
"""
import os
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
RESULTS = HERE / "results.yaml"
BADGE = HERE / "badge.svg"
COVERAGE = HERE / "coverage.yaml"
COVERAGE_TABLE = HERE / "coverage.md"
SHIELDS = "https://img.shields.io/static/v1"
TAIL = 30
TRIES = 3


def tail(path: Path, n: int) -> list[str]:
    """The last n lines of a file, read from its end."""
    with open(path, "rb") as f:
        end = pos = f.seek(0, 2)
        data = b""
        while pos > 0 and data.count(b"\n") <= n:
            pos = max(0, pos - 4096)
            f.seek(pos)
            data = f.read(end - pos)
    return data.decode().splitlines()[-n:]


def newest_promoted(path: Path) -> dict:
    """The last run in results.yaml that published its package."""
    n = TAIL
    while True:
        lines = tail(path, n)
        starts = [i for i, line in enumerate(lines) if line.startswith("- run")]
        # the entries from the first whole one in the window on, newest last
        runs = yaml.safe_load("\n".join(lines[starts[0]:])) if starts else []
        promoted = [r for r in runs if r.get("published")]
        if promoted:
            return promoted[-1]
        if len(lines) < n:
            raise ValueError(f"no run in {path} published its package")
        n *= 4


def deb_of(run: dict):
    return (run.get("version") or {}).get("deb")


def deb_suites(path: Path, run: dict) -> dict[str, int]:
    """Each suite's checks for this run's deb: from this run, else from the newest earlier
    run of the same deb where that suite passed. A later run does not count."""
    n = TAIL
    while True:
        lines = tail(path, n)
        starts = [i for i, line in enumerate(lines) if line.startswith("- run")]
        runs = yaml.safe_load("\n".join(lines[starts[0]:])) if starts else []
        ids = [r.get("run") for r in runs]
        whole = len(lines) < n
        if run.get("run") in ids and (whole or deb_of(runs[0]) != deb_of(run)):
            upto = runs[:ids.index(run.get("run")) + 1]
            break
        if whole:
            upto = [run]
            break
        n *= 4
    counts: dict[str, int] = {}
    for r in reversed(upto):
        if deb_of(r) == deb_of(run):
            for s in r.get("suites") or []:
                if s.get("result") == "pass" and int(s.get("failed", 0)) == 0:
                    counts.setdefault(s.get("name"), int(s.get("passed", 0)))
    return counts


def read_coverage() -> dict | None:
    """coverage.yaml as nightly.sh last wrote it, None when it cannot be read."""
    try:
        data = yaml.safe_load(COVERAGE.read_text())
    except (OSError, ValueError, yaml.YAMLError):
        return None
    return data if isinstance(data, dict) else None


def ytserv_coverage(data: dict | None) -> float | None:
    """ytserv's percent in coverage.yaml."""
    try:
        return next(float(c["percent"]) for c in data["crates"] if c.get("name") == "ytserv")
    except (AttributeError, KeyError, TypeError, ValueError, StopIteration):
        return None


def thousands(n: int) -> str:
    """A count as the badge states it: thousands with one decimal (5,624 is 5.6K)."""
    return f"{n / 1000:.1f}K" if n >= 1000 else f"{n:,}"


def badge(run: dict) -> dict:
    version = (run.get("version") or {}).get("ytserv", "?")
    totals = run.get("totals") or {}
    passed, failed = int(totals.get("passed", 0)), int(totals.get("failed", 0))
    suites = run.get("suites") or []
    if run.get("result") == "pass":
        counts = deb_suites(RESULTS, run) if suites else {}
        total = sum(counts.values()) if suites else passed + failed
        skipped = sum(1 for s in suites if s.get("result") == "skipped" and s.get("name") not in counts)
        color = "brightgreen"
        message = f"{thousands(total)} tests" + (f" · {skipped} suite{'s' if skipped > 1 else ''} skipped" if skipped else "")
    else:
        color = "red"
        message = f"{thousands(passed + failed)} tests · {failed:,} failed" if suites else "build failed"
    return {"label": "nightly", "message": f"{version}: {message}", "color": color}


def coverage_badge(percent: float) -> dict:
    color = "brightgreen" if percent >= 80 else "yellow" if percent >= 60 else "red"
    return {"label": "coverage", "message": f"{percent:.0f}%", "color": color}


def percent(v) -> str:
    return f"{float(v):.1f}%"


def coverage_table(data: dict) -> str:
    """coverage.md: what the coverage badge stands on. Public: nothing local in it."""
    version = (data.get("version") or {}).get("ytserv", "?")
    lines = data.get("lines") or {}
    out = [
        "# Code coverage",
        "",
        "The lines of YT Cluster's Rust code that the nightly's tests ran: the unit tests and",
        "the end-to-end suites below, against an instrumented ytserv and ytctl",
        "([coverage.sh](coverage.sh) says what counts). Not counted: migrate and jepsen, whose",
        "counts are not collected. The coverage badge shows ytserv's figure.",
        "",
        f"Written from [coverage.yaml](coverage.yaml): run {data.get('run', '?')}, measured"
        f" {str(data.get('measured', '?'))[:10]}",
        f"on ytserv {version}, run result: {data.get('result', '?')}. The first nightly with no"
        " new code measures",
        "again, so the figures can be days behind the newest release.",
        "",
        "## By crate",
        "",
        "| Crate | Lines | Covered | By unit tests | By end-to-end suites |",
        "|---|--:|--:|--:|--:|",
    ]
    for c in data.get("crates") or []:
        out.append(f"| {c.get('name')} | {int(c.get('lines', 0)):,} | {percent(c.get('percent', 0))}"
                   f" | {percent(c.get('unit', 0))} | {percent(c.get('e2e', 0))} |")
    out.append(f"| **All** | **{int(lines.get('total', 0)):,}** | **{percent(lines.get('percent', 0))}** | | |")
    out += ["", "## By suite", "", "The share of all those lines each one ran alone. They overlap, so they do not add up.",
            "", "| Suite | Lines it ran |", "|---|--:|"]
    names = {"unit": "unit tests", "e2e": "all end-to-end suites together"}
    by = data.get("by") or {}
    for key in ["unit", "e2e"] + sorted(k for k in by if k not in names):
        if key in by:
            out.append(f"| {names.get(key, key)} | {percent(by[key])} |")
    return "\n".join(out) + "\n"


def render(b: dict) -> bytes:
    """The badge as an SVG, drawn by shields.io - a few tries before giving up."""
    url = f"{SHIELDS}?{urllib.parse.urlencode(b)}"
    req = urllib.request.Request(url, headers={"User-Agent": "yt-cluster-nightly-badge"})
    for attempt in range(1, TRIES + 1):
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                svg = r.read()
            if svg.lstrip().startswith(b"<svg"):
                return svg
            err = f"not an SVG: {svg[:80]!r}"
        except OSError as e:
            err = str(e)
        if attempt < TRIES:
            time.sleep(10 * attempt)
    raise OSError(f"{url}: {err}")


def write(files: list[tuple[Path, bytes]]) -> None:
    """Replace the files at once, each from a temp file written first: a reader sees the old
    file or the new one, and a full disk or a bad directory changes none of them."""
    temps = []
    for path, data in files:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name(f".{path.name}.tmp")
        tmp.write_bytes(data)
        tmp.chmod(0o644)
        temps.append((tmp, path))
    for tmp, path in temps:
        os.replace(tmp, path)


def main() -> int:
    out = Path(sys.argv[sys.argv.index("--out") + 1]) if "--out" in sys.argv else BADGE
    try:
        run = newest_promoted(RESULTS)
        images = [(out, badge(run))]
    except (OSError, ValueError, yaml.YAMLError, AttributeError, IndexError, KeyError, TypeError) as err:
        print(f"badge: {err}", file=sys.stderr)
        return 1
    data = read_coverage()
    pct = ytserv_coverage(data)
    if pct is not None:
        images.append((out.with_name("coverage.svg"), coverage_badge(pct)))
    else:
        print(f"badge: no ytserv figure in {COVERAGE.name}: the coverage badge stays as it is", file=sys.stderr)
    table = None
    if data is not None:
        try:
            table = coverage_table(data)
        except (AttributeError, KeyError, TypeError, ValueError) as err:
            print(f"badge: {COVERAGE_TABLE.name} stays as it is: {err}", file=sys.stderr)
    if "--print" in sys.argv:
        for _, b in images:
            print(f"{b['label']} | {b['message']} ({b['color']})\n{SHIELDS}?{urllib.parse.urlencode(b)}")
        return 0
    try:
        files = [(path, render(b)) for path, b in images]
        if table is not None:
            files.append((COVERAGE_TABLE, table.encode()))
        write(files)
    except OSError as err:
        print(f"badge: {err}", file=sys.stderr)
        return 1
    for path, b in images:
        print(f"badge: {path} <- run {run.get('run')}: {b['label']} | {b['message']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
