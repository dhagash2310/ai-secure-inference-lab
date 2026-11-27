# llm-d manifests

- `sim/`: three simulated model servers (`llm-d-inference-sim`) plus a gateway. No real model, almost no CPU. Start here.
- `real/`: a gateway and Helm values that put the llm-d router in front of the real vLLM pods in the `llm` namespace.
- Versions are pinned in the Makefile (`GWAPI_VER`, `IGW_VER`, `AGW_VER`, `ROUTER_VER`) and listed in `docs/tested-versions.md`.

llm-d moves quickly. If an install step fails, compare against the current agentgateway guide, "Inference routing":
https://agentgateway.dev/docs/kubernetes/latest/documentation/llm/inference/inference-routing/

Useful checks once running:

```bash
kubectl get inferencepool,httproute,gateway -A
kubectl -n llm logs deploy/vllm-pool-epp --tail=20
```
