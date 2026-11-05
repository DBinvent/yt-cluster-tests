#!/usr/bin/env python3
"""mongodb/ writer: the one document every node's writer increments, each at its own path.

  doc.py create <url>                  the document: _id "doc", profile, a counter {n: 0}
                                       at each of PATHS, and EXTRA's paths empty lists
  doc.py read <url>                    its counters, as JSON {path: n}: every path holding one
  doc.py write <url> <path> <seconds> <threads>
                                       increment <path>.n for <seconds>, <threads> at once;
                                       a refused increment is tried again until it commits
                                       (a short random pause between); prints JSON: the
                                       increments committed, the retries, ops/s, the latency
                                       of a committed increment (its retries included), the
                                       errors seen
Database `perf`, collection `doc` - the same collection and document on every node.
"""
import json
import random
import sys
import threading
import time

from pymongo import MongoClient
from pymongo.errors import PyMongoError

DB, COLL, DOC_ID = "perf", "doc", "doc"
# the paths of the document: the first four a counter {n: 0} each; social and hobby empty
# lists, [], until a writer of theirs (a cluster of six) makes its own a counter
PATHS = ["education", "jobs", "achievement", "awards"]
EXTRA = ["social", "hobby"]
GIVE_UP_AFTER = 30.0  # seconds past the run's end an increment still refused is abandoned


def coll(url):
    return MongoClient(url, retryWrites=False, serverSelectionTimeoutMS=20000)[DB][COLL]


def create(url):
    c = coll(url)
    c.delete_many({"_id": DOC_ID})
    c.insert_one(dict({"_id": DOC_ID, "profile": "name"}, **{p: {"n": 0} for p in PATHS}, **{p: [] for p in EXTRA}))


def read(url):
    """every counter of the document - each path holding {n: ...} - whatever the paths"""
    d = coll(url).find_one({"_id": DOC_ID}) or {}
    return {k: v["n"] for k, v in d.items() if isinstance(v, dict) and "n" in v}


def write(url, path, seconds, threads):
    c = coll(url)
    # a path still an empty list - social, hobby - its writer's counter from now on
    for _ in range(30):
        try:
            c.update_one({"_id": DOC_ID, path: []}, {"$set": {path: {"n": 0}}})
            break
        except PyMongoError:
            time.sleep(1)
    stop = time.monotonic() + seconds
    lock = threading.Lock()
    res = {"ok": 0, "retries": 0, "abandoned": 0, "lat": [], "errors": {}}

    def work():
        ok, retries, abandoned, lat, errors = 0, 0, 0, [], {}
        while time.monotonic() < stop:
            t0 = time.monotonic()
            while True:
                try:
                    if c.update_one({"_id": DOC_ID}, {"$inc": {path + ".n": 1}}).modified_count == 1:
                        ok += 1
                        lat.append(time.monotonic() - t0)
                        break
                    why = "matched no document"
                except PyMongoError as e:
                    why = (type(e).__name__ + ": " + str(e))[:160]
                errors[why] = errors.get(why, 0) + 1
                retries += 1
                if time.monotonic() > stop + GIVE_UP_AFTER:
                    abandoned += 1
                    break
                time.sleep(random.uniform(0.001, 0.010))
        with lock:
            res["ok"] += ok
            res["retries"] += retries
            res["abandoned"] += abandoned
            res["lat"] += lat
            for k, v in errors.items():
                res["errors"][k] = res["errors"].get(k, 0) + v

    t_start = time.monotonic()
    ts = [threading.Thread(target=work) for _ in range(threads)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    elapsed = time.monotonic() - t_start
    lat = sorted(res["lat"])
    pct = lambda q: round(lat[min(len(lat) - 1, int(q * len(lat)))] * 1000, 2) if lat else 0
    print(json.dumps({
        "path": path, "ok": res["ok"], "retries": res["retries"], "abandoned": res["abandoned"],
        "seconds": round(elapsed, 1), "ops_s": round(res["ok"] / elapsed, 1) if elapsed else 0,
        "avg_ms": round(sum(lat) / len(lat) * 1000, 2) if lat else 0,
        "p95_ms": pct(0.95), "p99_ms": pct(0.99),
        "errors": dict(sorted(res["errors"].items(), key=lambda kv: -kv[1])[:5]),
    }))


if __name__ == "__main__":
    cmd, url = sys.argv[1], sys.argv[2]
    if cmd == "create":
        create(url)
    elif cmd == "read":
        print(json.dumps(read(url)))
    elif cmd == "write":
        write(url, sys.argv[3], float(sys.argv[4]), int(sys.argv[5]))
    else:
        sys.exit(f"unknown command {cmd}")
