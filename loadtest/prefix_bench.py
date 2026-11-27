#!/usr/bin/env python3
"""Tiny load generator for an OpenAI-compatible endpoint. Stdlib only.

--shared-prefix sends requests that share a long system prompt, which is where
prefix-cache-aware routing (llm-d) should beat round-robin.
"""
import argparse
import json
import statistics
import sys
import threading
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor

def make_prefix(rules):
    return (
        "You are a support assistant for an internal platform. Policy notes: "
        + " ".join(f"Rule {i}: always cite the runbook section and keep answers short." for i in range(rules))
    )


LONG_PREFIX = make_prefix(120)
SALT = ""  # unique per run so prefix caches from earlier runs cannot help this one


def one(url, model, i, shared, groups=1):
    if shared:
        system = (f"Tenant {i % groups} policy. " + LONG_PREFIX) if groups > 1 else LONG_PREFIX
    else:
        system = f"Session {i}. " + LONG_PREFIX[::-1][:600]
    if SALT:
        system = f"Run {SALT}. " + system
    body = json.dumps({
        "model": model,
        "max_tokens": 32,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": f"Question {i}: how do I restart a failed rollout?"},
        ],
    }).encode()
    req = urllib.request.Request(url + "/chat/completions", body, {"Content-Type": "application/json"})
    t0 = time.perf_counter()
    with urllib.request.urlopen(req, timeout=900) as r:
        r.read()
    return time.perf_counter() - t0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://localhost:8000/v1")
    ap.add_argument("--model", default="Qwen/Qwen2.5-0.5B-Instruct")
    ap.add_argument("--requests", type=int, default=40)
    ap.add_argument("--concurrency", type=int, default=4)
    ap.add_argument("--shared-prefix", action="store_true")
    ap.add_argument("--prefix-rules", type=int, default=120, help="prefix length: ~14 tokens per rule")
    ap.add_argument("--salt", default="", help="make this run's prefixes unique (defeats caches from earlier runs)")
    ap.add_argument("--groups", type=int, default=1, help="number of distinct shared prefixes (with --shared-prefix)")
    a = ap.parse_args()
    global LONG_PREFIX, SALT
    LONG_PREFIX = make_prefix(a.prefix_rules)
    SALT = a.salt

    done, lock = [0], threading.Lock()

    def run(i):
        d = one(a.url, a.model, i, a.shared_prefix, a.groups)
        with lock:
            done[0] += 1
            print(f"\r{done[0]}/{a.requests} done (last {d:.1f}s)", end="", file=sys.stderr, flush=True)
        return d

    t0 = time.perf_counter()
    with ThreadPoolExecutor(a.concurrency) as ex:
        lat = sorted(ex.map(run, range(a.requests)))
    print(file=sys.stderr)
    wall = time.perf_counter() - t0
    p = lambda q: lat[min(len(lat) - 1, int(q * len(lat)))]
    print(f"requests={len(lat)} wall={wall:.1f}s rps={len(lat)/wall:.2f}")
    print(f"latency mean={statistics.mean(lat):.2f}s p50={p(.5):.2f}s p95={p(.95):.2f}s")


if __name__ == "__main__":
    main()
