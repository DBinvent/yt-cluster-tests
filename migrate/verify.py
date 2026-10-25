#!/usr/bin/env python3
"""Judge the nodes' mig_seq against what each writer was told.

    verify.py <rows-file> <uuid>=<writer-log> ...

<rows-file> holds one node's mig_seq as `<node uuid> <seq>` lines - every node
holds the same rows by then (50_compare.sh checks that first). Each writer's log
is migrate/writer.sh's. Prints one line per writer and exits with the number of
checks that failed:

  lost      a row the writer was told committed (OK) is missing
  phantom   a row the writer was told did not commit (ERR, NOC) is there
  foreign   a row of a uuid no writer has, or a seq no writer sent
"""
import sys


def main():
    rows = {}
    with open(sys.argv[1]) as f:
        for line in f:
            p = line.split()
            if len(p) == 2 and p[1].lstrip("-").isdigit():
                rows.setdefault(p[0], set()).add(int(p[1]))
    failed = 0

    def report(good, text):
        nonlocal failed
        print(f"  {'OK  ' if good else 'FAIL'}  {text}")
        failed += 0 if good else 1

    def few(s):
        s = sorted(s)
        return " ".join(str(x) for x in s[:5]) + (" ..." if len(s) > 5 else "")

    writers = dict(a.split("=", 1) for a in sys.argv[2:])
    for u, log in sorted(writers.items()):
        outcome = {}
        with open(log) as f:
            for line in f:
                p = line.split(" ", 3)
                if len(p) >= 3 and p[1].isdigit():
                    outcome[int(p[1])] = p[2]
        ok = {s for s, r in outcome.items() if r == "OK"}
        refused = {s for s, r in outcome.items() if r in ("ERR", "NOC")}
        unknown = {s for s, r in outcome.items() if r == "UNK"}
        have = rows.get(u, set())
        print(f"  ....  {u[:8]}: sent {len(outcome)}, OK {len(ok)}, ERR+NOC {len(refused)}, UNK {len(unknown)}; "
              f"{len(have)} rows on every node ({len(have & unknown)} of the UNK)")
        report(not ok - have, f"{u[:8]}: every OK row is on every node"
               + ("" if not ok - have else f" - {len(ok - have)} missing: {few(ok - have)}"))
        report(not refused & have, f"{u[:8]}: no refused row is anywhere"
               + ("" if not refused & have else f" - {len(refused & have)} present: {few(refused & have)}"))
        report(not have - set(outcome), f"{u[:8]}: no row its writer did not send"
               + ("" if not have - set(outcome) else f" - {few(have - set(outcome))}"))
        report(len(ok) > 0, f"{u[:8]}: its writer committed rows")
    strange = set(rows) - set(writers)
    report(not strange, "no row of a node without a writer" + ("" if not strange else f": {sorted(strange)}"))
    sys.exit(failed)


main()
