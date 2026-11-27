# Troubleshooting

Every row below was hit during real runs of this lab.

| Symptom | Cause | Fix |
|---|---|---|
| Pod `Pending`, `Insufficient cpu/memory` | Too many or too large replicas for the Docker VM | Raise Docker memory (12 GB; 16 GB for two replicas) or stay on 1 replica (`make vllm-up`) |
| `ErrImagePull`, `lookup ... server misbehaving` | Docker Desktop DNS flaking inside the cluster | `make kind-load` pulls on the host; the overlays use `imagePullPolicy: IfNotPresent` |
| `Can't load tokenizer for 'Qwen/...'` | The pod cannot reach huggingface.co | Use `make model-download model-copy vllm-up` (offline, model read from the node) |
| `FailedCreate ... violates PodSecurity "baseline" ... hostPath` | The local model uses hostPath | The `cpu-local` overlay relaxes the `llm` namespace label on kind only |
| `VLLM_PORT 'tcp://...' appears to be a URI` | A Service named `vllm` injects `VLLM_PORT` into pods | `enableServiceLinks: false` (already set in the base Deployment) |
| `OOMKilled`, exit 137 during "Warming up model for the compilation" | torch.compile peak memory | Limits are 8Gi (`cpu`) and 7Gi (`cpu-local-llmd`); raise them if your VM is large |
| Pod restarts after ~15 min, event `Container failed startup probe` | Compile on a busy CPU outlasted the probe budget | `cpu-local-llmd` allows 40 min; for the base overlay raise `startupProbe.failureThreshold` |
| Every pod restart takes ~8 min | The torch.compile cache was lost with the container | `cpu-local-llmd` keeps it on the node at `/opt/vllm-cache`; check `docker exec llm-lab-worker2 ls /opt/vllm-cache` |
| `kubectl port-forward svc/vllm` always hits one pod | port-forward picks one pod and sticks to it | Benchmark in-cluster: `make bench-direct` / `make bench-llmd` |
| Benchmark job `Failed` with `TimeoutError` | Prompts too heavy for CPU pods at that concurrency | Lower `CONC`, `RULES` or `REQS`, e.g. `make bench-direct REQS=4 CONC=1` |
| `make: ... Error 1` right after `make scan-test` flags the pickle | The first scan is meant to fail | The Makefile ignores that exit code; exit 3 on the real model means nothing scannable (fine) |
| `pip install modelscan` finds no versions | Python 3.13/3.14 venv | Use the Makefile target; it runs `uvx --python 3.12` |
| `brew install uv` runs for an hour | Builds from source on Intel Macs | `.venv/bin/pip install uv` (the Makefile does this) |
| garak: `FileNotFoundError` for the report | Relative `--report_prefix` | The Makefile passes an absolute path |
| `hf download ... --exclude "a" "b"` fetches only the excluded files | Extra patterns parsed as filenames | Repeat the flag: `--exclude a --exclude b` |
| guard pod: `Unrecognized model ... no model_type in config.json` | Classifier download incomplete | Re-download; `ls model-cache/guard` must show `config.json` and weights |
| `docker build` of the guard: torch download times out | Flaky network; pip cannot resume | `make guard-wheel` once (resumable curl), then `make guard-build` |
| `kubectl` says `inference-gateway` service not found | The gateway has not been created yet | Run `make llmd-real-up` (safe to repeat) |
| Garak run slower than before | More hops and two replicas share the same CPU | Compare like with like; use `--parallel_attempts` for speed |
| `Warning: would violate PodSecurity "restricted:latest"` when installing the router or running a benchmark | The `llm` namespace carries a `warn` label for the restricted profile | Harmless: it is only a warning, enforcement is relaxed on purpose for the local hostPath model |
