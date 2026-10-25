#!/usr/bin/env python3
"""Render what the regular ytserv is made of as a badge, served from the apt host.

    nightly/safety_badge.py                 # -> nightly/ytserv-safety.svg
    nightly/safety_badge.py --out PATH      # nightly.sh: REPO_DIR/paks/nightly/ytserv-safety.svg
    nightly/safety_badge.py --print         # say what it found, fetch nothing
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

It is the regular ytserv's badge: ytserv-py, the build with Python functions,
links pyo3 and libpython and takes SECRET out of its environment in one unsafe
call of its own.

Green: both hold. A vulnerability in ytserv's tree, or unsafe code that compiled,
turns it red and says which. A check that could not run (no cargo-audit, no
network for its advisory database) is named instead of guessed. Renewed, like the
nightly badge, only by a run that published - and written the same way: shields.io
draws it, a temp file renamed over the old one (badge.py).
"""
import json
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


def audit(tree: set) -> tuple:
    """(advisories of ytserv's tree, or None when the audit could not run; what it says)"""
    r = run(["cargo", "audit", "--json"], timeout=600)
    try:
        d = json.loads(r.stdout)
    except ValueError:
        return None, f"cargo audit did not run: {(r.stderr.strip().splitlines() or ['no output'])[-1]}"
    hits = sorted({f"{v['advisory']['id']} {v['package']['name']}"
                   for v in d.get("vulnerabilities", {}).get("list", [])
                   if (v["package"]["name"], v["package"]["version"]) in tree})
    return hits, ", ".join(hits) if hits else "no advisory in ytserv's tree"


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
    parts = ["audit: not run" if hits is None else "audit clean" if not hits else
             f"{len(hits)} advisor{'y' if len(hits) == 1 else 'ies'}",
             "unsafe: not checked" if clean is None else "unsafe forbidden" if clean else "unsafe found"]
    ok = hits == [] and clean is True
    failed = bool(hits) or clean is False
    color = "brightgreen" if ok else "red" if failed else "lightgrey"
    return ({"label": f"ytserv {ytserv_version()}", "message": " · ".join(parts), "color": color},
            f"audit: {audit_says}; unsafe: {unsafe_says}")


def main() -> int:
    out = Path(sys.argv[sys.argv.index("--out") + 1]) if "--out" in sys.argv else BADGE
    try:
        b, detail = badge()
    except (OSError, subprocess.TimeoutExpired) as err:
        print(f"safety badge: {err}", file=sys.stderr)
        return 1
    if "--label" in sys.argv:
        b["label"] = sys.argv[sys.argv.index("--label") + 1]
    if "--print" in sys.argv:
        print(f"{b['label']} | {b['message']} ({b['color']}) - {detail}\n{SHIELDS}?{urllib.parse.urlencode(b)}")
        return 0
    try:
        write(out, render(b))
    except OSError as err:
        print(f"safety badge: {err}", file=sys.stderr)
        return 1
    print(f"safety badge: {out} <- {b['label']} | {b['message']} - {detail}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
