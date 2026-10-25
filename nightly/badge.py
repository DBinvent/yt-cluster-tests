#!/usr/bin/env python3
"""Render the newest nightly run as a badge image, served from the apt host.

    nightly/badge.py                    # results.yaml next to this file -> nightly/badge.svg
    nightly/badge.py --out PATH         # write the image there (nightly.sh: REPO_DIR/paks/nightly/badge.svg)
    nightly/badge.py --print            # print the badge and the shields.io URL, fetch nothing

The badge is what dbinvent.com shows next to the release it announces:

    https://apt.dbinvent.com/paks/nightly/badge.svg

    nightly 1.2.0 | 3K e2e tests with 86% coverage
    nightly 1.2.0 | 3K e2e tests · 1 failed with 86% coverage

The count is the end-to-end suites' checks - every suite but the unit tests -
rounded to thousands (2,854 is 3K); the coverage is ytserv's (owner, 2026-10-19:
"3K e2e tests with 86% coverage"). Green says they all passed.

A promoted run that ran only the unit tests (nightly.sh --force --suites unit, to
publish after a run that passed every suite but could not publish, 2026-10-20)
states the end-to-end count of the newest run of the same deb whose end-to-end
suites all passed: it ran none of its own, and "0 e2e tests" would not be the truth.

The badge is the newest promotion: the newest run that published its package
(`published:` set in results.yaml). A run that failed, or passed and published
nothing (a coverage run, --no-publish), leaves the badge as it is - it vouches for
what can be installed, and nightly.sh renews it only after a run that published.

The label is the ytserv tested, the message the total and how it went. A promoted
run passed every suite, so it is green; red is only for an entry that says
published but failed, which nightly.sh never writes. A suite skipped for a missing
outside service is named: it tested nothing, and a green badge should not hide
that. Coverage is ytserv's line coverage, unit and end-to-end tests together,
from coverage.yaml - the last measurement: a run measures only when that file is
missing (or lists fewer suites than a whole run), so most runs carry none of their own.

The image is drawn here, at the end of the run: shields.io's static badge renders
label, message and color into an SVG, and the SVG is written in place of the old
one (a temp file renamed over it, so a fetch never sees half of it). Nothing reads
it from GitHub, so no push is needed: under /paks/ the apt host's nginx serves a
name with no version in it as max-age=300, must-revalidate, and Cloudflare follows
that - a new badge is on the page within five minutes. shields.io unreachable
(after a few tries): nothing written, the previous badge stays, exit 1.

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


def e2e_tested(path: Path, deb: str) -> int:
    """The end-to-end checks of the newest run of this deb whose end-to-end suites
    all passed - for a promoted run that ran none of its own. 0 when there is none."""
    n = TAIL
    while True:
        lines = tail(path, n)
        starts = [i for i, line in enumerate(lines) if line.startswith("- run")]
        runs = yaml.safe_load("\n".join(lines[starts[0]:])) if starts else []
        for r in reversed(runs):
            e2e = [s for s in (r.get("suites") or []) if s.get("name") != "unit"]
            if ((r.get("version") or {}).get("deb") == deb and e2e
                    and all(s.get("result") == "pass" and int(s.get("failed", 0)) == 0 for s in e2e)):
                return sum(int(s.get("passed", 0)) for s in e2e)
        if len(lines) < n:
            return 0
        n *= 4


def ytserv_coverage() -> float | None:
    """ytserv's percent in coverage.yaml, as nightly.sh last measured it."""
    try:
        crates = yaml.safe_load(COVERAGE.read_text())["crates"]
        return next(float(c["percent"]) for c in crates if c.get("name") == "ytserv")
    except (OSError, yaml.YAMLError, KeyError, TypeError, ValueError, StopIteration):
        return None


def thousands(n: int) -> str:
    """A count as the badge states it: thousands, rounded (2,854 is 3K)."""
    return f"{n / 1000:.0f}K" if n >= 1000 else f"{n:,}"


def badge(run: dict) -> dict:
    version = (run.get("version") or {}).get("ytserv", "?")
    totals = run.get("totals") or {}
    passed, failed = int(totals.get("passed", 0)), int(totals.get("failed", 0))
    suites = run.get("suites") or []
    skipped = sum(1 for s in suites if s.get("result") == "skipped")
    # the end-to-end checks: every suite's but the unit tests'
    e2e_suites = [s for s in suites if s.get("name") != "unit"]
    e2e = sum(int(s.get("passed", 0)) + int(s.get("failed", 0)) for s in e2e_suites)
    if suites and not e2e_suites:
        # only the unit tests ran: the end-to-end count this deb was tested with
        e2e = e2e_tested(RESULTS, str((run.get("version") or {}).get("deb", "")))
    tests = f"{thousands(e2e)} e2e tests" if suites else f"{thousands(passed + failed)} tests"
    coverage = ytserv_coverage()
    with_coverage = f" with {coverage:.0f}% coverage" if coverage is not None else ""
    if run.get("result") == "pass":
        color = "brightgreen"
        message = tests + with_coverage + (f" · {skipped} suite{'s' if skipped > 1 else ''} skipped" if skipped else "")
    else:
        color = "red"
        message = (f"{tests} · {failed:,} failed" if suites else "build failed") + with_coverage
    return {"label": f"nightly {version}", "message": message, "color": color}


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


def write(path: Path, data: bytes) -> None:
    """Replace path with data at once: a reader sees the old badge or the new one."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_bytes(data)
    tmp.chmod(0o644)
    os.replace(tmp, path)


def main() -> int:
    out = Path(sys.argv[sys.argv.index("--out") + 1]) if "--out" in sys.argv else BADGE
    try:
        run = newest_promoted(RESULTS)
    except (OSError, ValueError, yaml.YAMLError, IndexError, TypeError) as err:
        print(f"badge: {err}", file=sys.stderr)
        return 1
    b = badge(run)
    if "--print" in sys.argv:
        print(f"{b['label']} | {b['message']} ({b['color']})\n{SHIELDS}?{urllib.parse.urlencode(b)}")
        return 0
    try:
        write(out, render(b))
    except OSError as err:
        print(f"badge: {err}", file=sys.stderr)
        return 1
    print(f"badge: {out} <- run {run.get('run')}: {b['label']} | {b['message']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
