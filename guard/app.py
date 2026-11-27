"""Prompt-injection guard: an OpenAI-compatible proxy that screens prompts before they reach vLLM.

Blocked requests get a normal-looking completion with a refusal message and an `x-guard: blocked` header.
Everything else is forwarded unchanged. Only INPUTS are screened (no output checks).
GUARD_FAKE=1 swaps in a keyword stub so the plumbing can be tested without torch (tests only).
"""
import os
import time
import uuid

import httpx
from fastapi import FastAPI, Request, Response
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import JSONResponse

MODEL_DIR = os.getenv("MODEL_DIR", "/model")
UPSTREAM = os.getenv("UPSTREAM", "http://vllm.llm.svc:8000").rstrip("/")
THRESHOLD = float(os.getenv("THRESHOLD", "0.5"))
FAKE = os.getenv("GUARD_FAKE") == "1"
REFUSAL = "Request blocked by guardrail: possible prompt injection."
SAFE_LABELS = {"SAFE", "LABEL_0", "BENIGN"}

app = FastAPI()
client = httpx.AsyncClient(timeout=httpx.Timeout(600.0))
stats = {"allowed": 0, "blocked": 0, "classify_ms_total": 0.0}


def load_classifier():
    if FAKE:
        def fake(text):
            t = text.lower()
            return ("INJECTION", 0.99) if "ignore" in t and "instruction" in t else ("SAFE", 0.99)
        return fake
    from transformers import pipeline

    pipe = pipeline("text-classification", model=MODEL_DIR, truncation=True, max_length=512, device=-1)

    def classify(text):
        out = pipe(text)[0]
        return out["label"], float(out["score"])

    return classify


classify = load_classifier()


def prompt_texts(path, body):
    """Collect the text a user supplied, for chat or legacy completions requests."""
    texts = []
    if path.endswith("chat/completions"):
        for m in body.get("messages", []):
            if m.get("role") != "user":
                continue
            c = m.get("content")
            if isinstance(c, str):
                texts.append(c)
            elif isinstance(c, list):
                texts += [p.get("text", "") for p in c if isinstance(p, dict) and p.get("type") == "text"]
    else:
        p = body.get("prompt", "")
        texts += [p] if isinstance(p, str) else [x for x in p if isinstance(x, str)]
    return [t for t in texts if t.strip()]


def is_injection(texts):
    worst = ("SAFE", 0.0)
    for t in texts:
        label, score = classify(t)
        if label.upper() not in SAFE_LABELS and score >= THRESHOLD and score >= worst[1]:
            worst = (label, score)
    return worst[0].upper() not in SAFE_LABELS, worst


def refusal(path, model):
    base = {"id": f"guard-{uuid.uuid4().hex[:12]}", "created": int(time.time()), "model": model}
    usage = {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}
    if path.endswith("chat/completions"):
        base.update(object="chat.completion", usage=usage, choices=[
            {"index": 0, "message": {"role": "assistant", "content": REFUSAL}, "finish_reason": "stop"}])
    else:
        base.update(object="text_completion", usage=usage, choices=[
            {"index": 0, "text": REFUSAL, "finish_reason": "stop"}])
    return JSONResponse(base, headers={"x-guard": "blocked"})


@app.get("/healthz")
def healthz():
    return {"ok": True}


@app.get("/guard/stats")
def guard_stats():
    n = stats["allowed"] + stats["blocked"]
    return {**stats, "requests": n, "avg_classify_ms": round(stats["classify_ms_total"] / n, 1) if n else 0,
            "threshold": THRESHOLD, "fake": FAKE}


@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE"])
async def proxy(path: str, request: Request):
    raw = await request.body()
    guarded = request.method == "POST" and path in ("v1/chat/completions", "v1/completions")
    if guarded:
        try:
            body = await request.json()
        except ValueError:
            return JSONResponse({"error": "invalid JSON"}, status_code=400)
        t0 = time.perf_counter()
        blocked, (label, score) = await run_in_threadpool(lambda: is_injection(prompt_texts(path, body)))
        stats["classify_ms_total"] += (time.perf_counter() - t0) * 1000
        if blocked:
            stats["blocked"] += 1
            return refusal(path, body.get("model", "unknown"))
        stats["allowed"] += 1
    headers = {k: v for k, v in request.headers.items() if k.lower() not in ("host", "content-length")}
    r = await client.request(request.method, f"{UPSTREAM}/{path}", content=raw, headers=headers,
                             params=request.query_params)
    return Response(content=r.content, status_code=r.status_code,
                    media_type=r.headers.get("content-type"), headers={"x-guard": "allowed"} if guarded else {})
