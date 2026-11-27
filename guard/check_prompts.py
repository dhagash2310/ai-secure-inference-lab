#!/usr/bin/env python3
"""Send each line of a file to an OpenAI-compatible endpoint and report how many the guard blocked.

  python3 guard/check_prompts.py guard/benign.txt    # want ~0% blocked (false positives)
  python3 guard/check_prompts.py guard/attacks.txt   # want ~100% blocked
"""
import json
import sys
import urllib.request

path = sys.argv[1]
url = sys.argv[2] if len(sys.argv) > 2 else "http://localhost:8080/v1"
model = sys.argv[3] if len(sys.argv) > 3 else "Qwen/Qwen2.5-0.5B-Instruct"
lines = [l.strip() for l in open(path) if l.strip()]
blocked = []
for line in lines:
    body = json.dumps({"model": model, "max_tokens": 16,
                       "messages": [{"role": "user", "content": line}]}).encode()
    req = urllib.request.Request(url + "/chat/completions", body, {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=600) as r:
        r.read()
        if r.headers.get("x-guard") == "blocked":
            blocked.append(line)
print(f"{path}: blocked {len(blocked)}/{len(lines)} ({100 * len(blocked) / len(lines):.0f}%)")
for b in blocked:
    print("  blocked:", b)
