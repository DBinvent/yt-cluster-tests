#!/usr/bin/env python3
"""Render what the regular ytserv is made of as a badge, served from the apt host.

    nightly/safety_badge.py                 # -> nightly/ytserv-safety.svg
    nightly/safety_badge.py --out PATH      # nightly.sh: REPO_DIR/paks/nightly/ytserv-safety.svg
    nightly/safety_badge.py --print         # say what it found, fetch nothing
    nightly/safety_badge.py --gate          # the nightly before its publish: exit 1 when red,
                                            # or when a check could not run; nothing drawn
    nightly/safety_badge.py --label TEXT    # instead of "ytserv <version>": a draw by hand between
                                            # publishes checks sources the package does not carry
                                            # yet - "ytserv next" says so

    https://apt.dbinvent.com/paks/nightly/ytserv-safety.svg

    ytserv 1.19.0 | audit clean · unsafe forbidden

Two checks, on yt-cluster's tree as it was built (YT_PGXT, default ../../yt-cluster):

- audit: `cargo audit` over the workspace's Cargo.lock, counting the RustSec
  vulnerabilities of the crates in ytserv's own tree (`cargo tree -p ytserv`) -
  an advisory of a crate only ytctl links (rsa, through russh) is not ytserv's.
- unsafe: `cargo check -p ytserv` with unsafe code forbidden (RUSTFLAGS
  `-F unsafe_code`). Cargo caps the lints of registry crates, so it fails exactly
  when a crate of ytserv's own - ytserv, ytcc, ytct, etcds, rppd-common,
  schema_guard, diff_doc, marg - compiles unsafe code in the build that ships: the
  compiler's word, cfg included, where a scan of the sources (cargo geiger) reads
  a `cfg_attr(.., forbid(unsafe_code))` as no forbid at all. Its own target dir
  (target/unsafe-check): other flags would rebuild target/release.

It is the regular ytserv's badge: ytserv-all, the build with Python functions,
links pyo3 and libpython and takes SECRET out of its environment in one unsafe
call of its own.

Green: both hold. Each advisory is graded by its CVSS score, as cargo audit prints it
(or worked out from a CVSS 3 vector), and the badge names the levels - "1 medium
advisory": red only for a high or critical one (7.0 and up) or unsafe code that
compiled; a medium, low or unrated one (RustSec gives many no score) is yellow (owner,
2026-10-25: a medium advisory is no critical compromise). A check that could not run
(no cargo-audit, no network for its advisory database) is named instead of guessed. Renewed, like the
nightly badge, only by a run that published - and written the same way: shields.io
draws it, a temp file renamed over the old one (badge.py).
"""
import json
import math
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from badge import SHIELDS, render, write  # noqa: E402 - the same drawing as the nightly badge

import urllib.parse  # noqa: E402

YT_PGXT = Path(os.environ.get("YT_PGXT", HERE / ".." / ".." / "yt-cluster")).resolve()
BADGE = HERE / "ytserv-safety.svg"


def run(args: list, env: dict | None = None, timeout: int = 1800) -> subprocess.CompletedProcess:
    return subprocess.run(args, cwd=YT_PGXT, capture_output=True, text=True, timeout=timeout,
                          env={**os.environ, **(env or {})})


def ytserv_version() -> str:
    m = re.search(r'^version = "([^"]+)"', (YT_PGXT / "ytserv" / "Cargo.toml").read_text(), re.M)
    return m.group(1) if m else "?"


def ytserv_tree() -> set:
    """(name, version) of every crate the regular ytserv links or builds with"""
    r = run(["cargo", "tree", "-p", "ytserv", "-e", "normal,build", "--prefix", "none", "--format", "{p}"])
    if r.returncode != 0:
        raise OSError(f"cargo tree: {r.stderr.strip().splitlines()[-1:]}")
    out = set()
    for line in r.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[1].startswith("v"):
            out.add((parts[0], parts[1][1:]))
    return out


LEVELS = ["critical", "high", "medium", "low", "unrated"]   # worst first

# CVSS 3.x base metrics (FIRST's specification, 3.1)
CVSS3 = {"AV": {"N": 0.85, "A": 0.62, "L": 0.55, "P": 0.2}, "AC": {"L": 0.77, "H": 0.44},
         "UI": {"N": 0.85, "R": 0.62}, "CIA": {"H": 0.56, "L": 0.22, "N": 0.0}}
PR = {False: {"N": 0.85, "L": 0.62, "H": 0.27}, True: {"N": 0.85, "L": 0.68, "H": 0.5}}


def cvss3_score(vector: str) -> float | None:
    """The base score of a CVSS 3.x vector, None for anything else (a CVSS 4 one)"""
    if not vector or not vector.startswith("CVSS:3."):
        return None
    try:
        m = dict(part.split(":") for part in vector.split("/")[1:])
        changed = m["S"] == "C"
        iss = 1 - (1 - CVSS3["CIA"][m["C"]]) * (1 - CVSS3["CIA"][m["I"]]) * (1 - CVSS3["CIA"][m["A"]])
        impact = 7.52 * (iss - 0.029) - 3.25 * (iss - 0.02) ** 15 if changed else 6.42 * iss
        exploit = 8.22 * CVSS3["AV"][m["AV"]] * CVSS3["AC"][m["AC"]] * PR[changed][m["PR"]] * CVSS3["UI"][m["UI"]]
    except (KeyError, ValueError):
        return None
    if impact <= 0:
        return 0.0
    raw = min((1.08 if changed else 1.0) * (impact + exploit), 10.0)
    i = round(raw * 100000)   # 3.1's roundup: up to one decimal, float noise aside
    return i / 100000.0 if i % 10000 == 0 else (math.floor(i / 10000) + 1) / 10.0


def level(score: float | None) -> str:
    if score is None:
        return "unrated"
    return "critical" if score >= 9.0 else "high" if score >= 7.0 else "medium" if score >= 4.0 else "low"


def printed_scores() -> dict:
    """advisory id -> the score cargo audit prints for it ("Severity: 5.9 (medium)"),
    CVSS 4 included; the database is the one the JSON run just fetched"""
    r = run(["cargo", "audit", "--no-fetch"], timeout=600)
    scores, current = {}, None
    for line in r.stdout.splitlines():
        if line.startswith("ID:"):
            current = line.split(":", 1)[1].strip()
        elif line.startswith("Severity:") and current:
            m = re.match(r"\s*([0-9.]+)", line.split(":", 1)[1])
            if m:
                scores[current] = float(m.group(1))
    return scores


def audit(tree: set | None) -> tuple:
    """(advisories of ytserv's tree as (id, crate, level), or None when the audit could not
    run; what it says). A tree of None takes the whole workspace (a check by hand)."""
    r = run(["cargo", "audit", "--json"], timeout=600)
    try:
        d = json.loads(r.stdout)
    except ValueError:
        return None, f"cargo audit did not run: {(r.stderr.strip().splitlines() or ['no output'])[-1]}"
    found = {(v["advisory"]["id"], v["package"]["name"], v["advisory"].get("cvss") or "")
             for v in d.get("vulnerabilities", {}).get("list", [])
             if tree is None or (v["package"]["name"], v["package"]["version"]) in tree}
    printed = printed_scores() if found else {}
    hits = sorted(((aid, crate, level(printed.get(aid, cvss3_score(vector)))) for aid, crate, vector in found),
                  key=lambda h: (LEVELS.index(h[2]), h[0]))
    return hits, ", ".join(f"{aid} {crate} ({lv})" for aid, crate, lv in hits) if hits else "no advisory in ytserv's tree"


def advisories_said(hits: list) -> str:
    """'1 medium advisory', '1 high, 2 unrated advisories'"""
    counts = {lv: sum(1 for h in hits if h[2] == lv) for lv in LEVELS}
    said = ", ".join(f"{n} {lv}" for lv, n in counts.items() if n)
    return f"{said} advisor{'y' if len(hits) == 1 else 'ies'}"


def unsafe_forbidden() -> tuple:
    """(True when ytserv's own crates compile no unsafe code, None when the check could not run; detail)"""
    r = run(["cargo", "check", "-p", "ytserv", "--release"],
            env={"RUSTFLAGS": "-F unsafe_code", "CARGO_TARGET_DIR": str(YT_PGXT / "target" / "unsafe-check")})
    if r.returncode == 0:
        return True, "ytserv and its own crates compile with unsafe code forbidden"
    crates = sorted(set(re.findall(r"could not compile `([^`]+)`", r.stderr)))
    if not re.search(r"unsafe", r.stderr):
        return None, f"cargo check failed for another reason: {(r.stderr.strip().splitlines() or ['?'])[-1]}"
    return False, f"unsafe code in {', '.join(crates) or 'ytserv'}"


def badge() -> tuple:
    tree = ytserv_tree()
    hits, audit_says = audit(tree)
    clean, unsafe_says = unsafe_forbidden()
    parts = ["audit: not run" if hits is None else "audit clean" if not hits else advisories_said(hits),
             "unsafe: not checked" if clean is None else "unsafe forbidden" if clean else "unsafe found"]
    ok = hits == [] and clean is True
    severe = clean is False or any(h[2] in ("critical", "high") for h in hits or [])
    color = ("brightgreen" if ok else "red" if severe else "yellow" if hits
             else "lightgrey")
    # [security-gate] what lets a publish go: both checks ran, no high or critical
    # advisory, no unsafe code - a medium, low or unrated advisory passes, as Trivy's
    # gate passes a finding below HIGH
    passes = hits is not None and clean is True and not severe
    return ({"label": f"ytserv {ytserv_version()}", "message": " · ".join(parts), "color": color},
            f"audit: {audit_says}; unsafe: {unsafe_says}", passes)


def main() -> int:
    out = Path(sys.argv[sys.argv.index("--out") + 1]) if "--out" in sys.argv else BADGE
    try:
        b, detail, passes = badge()
    except (OSError, subprocess.TimeoutExpired) as err:
        print(f"safety badge: {err}", file=sys.stderr)
        return 1
    if "--gate" in sys.argv:
        print(f"{b['message']} - {detail}")
        return 0 if passes else 1
    if "--label" in sys.argv:
        b["label"] = sys.argv[sys.argv.index("--label") + 1]
    if "--print" in sys.argv:
        print(f"{b['label']} | {b['message']} ({b['color']}) - {detail}\n{SHIELDS}?{urllib.parse.urlencode(b)}")
        return 0
    try:
        write([(out, render(b))])
    except OSError as err:
        print(f"safety badge: {err}", file=sys.stderr)
        return 1
    print(f"safety badge: {out} <- {b['label']} | {b['message']} - {detail}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
