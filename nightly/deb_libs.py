#!/usr/bin/env python3
"""[sbom] The debs' libraries and licenses into dbinvent.com's D1 table deb_libs, which its
/licenses page reads at each request - grouped by deb, then by binary (owner, 2026-11-17).

After a green run that published (nightly.sh, step 7), as the packages carry them:
  yt-cluster  the rows yt-cluster's ytctl/deb-sbom.py wrote at the build: ytctl/sbom/deb-libs.json
  sge         made here from the sge checkout beside this repository, as its deb is built:
              sge, sge-sqlite and sge-mysql (the crate schema_guard) and diff_data - by yt-cluster-lite's tools/sbom.py
Each deb's rows are replaced whole, in one file of statements, through the site's wrangler
(dbinvent's node_modules, its login) on the database the docs Worker holds (wrangler.docs.toml).

    deb_libs.py [--dry-run]     --dry-run: write the statements and say how many, run nothing
"""
import datetime
import json
import os
import shlex
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
GIT = os.path.dirname(os.path.dirname(HERE))
YT = os.environ.get("YT_PGXT") or os.path.join(GIT, "yt-cluster")
SITE = os.path.join(GIT, "dbinvent")
SBOM = os.path.join(GIT, "yt-cluster-lite", "tools", "sbom.py")
DB = "dbinvent-docs"
COLS = ("deb", "deb_version", "bin", "bin_version", "kind", "name", "version", "license", "purl", "updated_at")


def version_of(cargo_toml):
    with open(cargo_toml) as f:
        return re.search(r'(?m)^version\s*=\s*"([^"]+)"', f.read()).group(1)


def sge_rows(tmp):
    """the sge deb's rows: sge, sge-sqlite, sge-mysql and diff_data, as its build makes them
    ([xdb 2026-11-20] sge 2.4's two binaries each with its own feature, as dist/build.sh builds them). sge from its committed HEAD
    (git archive), as sge's CI builds the published deb from a commit: the checkout's uncommitted
    work - a version no registry has yet - made cargo metadata fail and no row reach the site
    (2026-11-19). None when a part fails: that deb keeps the site's last list"""
    rows = os.path.join(tmp, "sge-rows.json")
    src = os.path.join(tmp, "sge-head")
    os.makedirs(src)
    a = subprocess.run(f"git -C {shlex.quote(os.path.join(GIT, 'sge'))} archive HEAD | tar -x -C {shlex.quote(src)}",
                       shell=True)
    if a.returncode != 0:
        print(f"deb_libs: the sge deb: git archive of its HEAD failed ({a.returncode})", file=sys.stderr)
        return None
    v = version_of(os.path.join(src, "Cargo.toml"))
    xdb = lambda f: ["--no-default-features", "--features", f"cli,{f}"]
    parts = [(src, "schema_guard", "sge", [])]
    # a HEAD from before sge 2.4 has neither binary: its deb ships only sge and diff_data
    for b, f in (("sge-sqlite", "sqlite"), ("sge-mysql", "mysql")):
        if f'name = "{b}"' in open(os.path.join(src, "Cargo.toml")).read():
            parts.append((src, "schema_guard", b, xdb(f)))
    parts.append((os.path.join(GIT, "diff-data"), "diff_data", "diff_data", []))
    for d, package, name, more in parts:
        r = subprocess.run([sys.executable, "-I", SBOM, "--dir", d, "--package", package,
                            "--name", name, "--out", os.path.join(tmp, f"sbom-{name}.cdx.json"),
                            "--rows", rows, "--deb", "sge", "--deb-version", v] + more)
        if r.returncode != 0:
            print(f"deb_libs: the sge deb's {name}: sbom.py failed ({r.returncode}) - its last list kept", file=sys.stderr)
            return None
    with open(rows) as f:
        return json.load(f)


def q(s):
    return "'" + str(s).replace("'", "''") + "'"


def statements(by_deb, now):
    """[review 2026-11-17] a deb's rows laid in first (INSERT OR REPLACE, its key), the ones this
    run did not write taken out last: a statement that fails leaves the deb's last full list,
    never a deleted or half one. A deb with no rows is refused, not emptied"""
    out = []
    for deb, rows in by_deb.items():
        if not rows:
            sys.exit(f"deb_libs: no rows for {deb}: the site keeps its last list")
        seen = set()
        values = []
        for r in rows:
            key = (r["deb"], r["binary"], r["kind"], r["name"], r["version"])
            if key in seen:  # the table's key: a library once a binary
                continue
            seen.add(key)
            values.append("(" + ", ".join(q(x) for x in (r["deb"], r["deb_version"], r["binary"], r["binary_version"],
                                                            r["kind"], r["name"], r["version"], r["license"], r["purl"], now)) + ")")
        for i in range(0, len(values), 100):
            out.append(f"INSERT OR REPLACE INTO deb_libs ({', '.join(COLS)}) VALUES\n" + ",\n".join(values[i:i + 100]) + ";")
        out.append(f"DELETE FROM deb_libs WHERE deb = {q(deb)} AND updated_at <> {q(now)};")
    return "\n".join(out) + "\n"


def main():
    dry = "--dry-run" in sys.argv
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    yt_rows = os.path.join(YT, "ytctl", "sbom", "deb-libs.json")
    if not os.path.isfile(yt_rows):
        sys.exit(f"deb_libs: no {yt_rows}: the build writes it (ytctl/deb-sbom.py)")
    with open(yt_rows) as f:
        by_deb = {"yt-cluster": json.load(f)}
    with tempfile.TemporaryDirectory() as tmp:
        # [review 2026-11-19] one deb that fails keeps its own last list, not the other's out
        failed = []
        sge = sge_rows(tmp)
        if sge is None:
            failed.append("sge")
        else:
            by_deb["sge"] = sge
        sql = os.path.join(tmp, "deb_libs.sql")
        with open(sql, "w") as f:
            f.write(statements(by_deb, now))
        counts = ", ".join(f"{d} {len({r['binary'] for r in rows})} binaries {len(rows)} rows" for d, rows in by_deb.items())
        if dry:
            print(f"deb_libs: dry run, nothing sent: {counts}; {os.path.getsize(sql)} bytes of statements")
            return
        wrangler = os.path.join(SITE, "node_modules", ".bin", "wrangler")
        r = subprocess.run([wrangler, "d1", "execute", DB, "--remote", "--yes", "--file", sql,
                            "--config", "wrangler.docs.toml"], cwd=SITE, capture_output=True, text=True, timeout=600)
        if r.returncode != 0:
            sys.exit(f"deb_libs: D1 refused the rows: {(r.stderr or r.stdout).strip()[-800:]}")
    print(f"deb_libs: {counts} -> D1 {DB}.deb_libs")
    if failed:
        sys.exit(f"deb_libs: not written, their last list kept: {', '.join(failed)}")


if __name__ == "__main__":
    main()
