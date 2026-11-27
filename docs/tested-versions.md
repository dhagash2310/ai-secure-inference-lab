# Tested versions

Tested on an Intel Mac (darwin/amd64) with Docker Desktop. Pin these when you reproduce a result.

| Component | Version |
|---|---|
| Docker Engine | 29.7.2 |
| kind | v0.33.0 |
| kubectl (client) | v1.36.1, built-in Kustomize v5.8.1 |
| Helm | v4.2.3 |
| vLLM CPU image | `public.ecr.aws/q9t5s3a7/vllm-cpu-release-repo:latest`, pulled 2026-11-26, vLLM 0.29.0, digest `sha256:66064cf683152e60eff2e5b18ec2d4ace236fb063c0a241f918691db9caddcf4` |
| Model | `Qwen/Qwen2.5-0.5B-Instruct` |
| Guard classifier | `protectai/deberta-v3-base-prompt-injection-v2` |
| torch (guard image) | 2.15.0 CPU build |
| garak | 0.10.3.1 |
| ModelScan | run through `uvx --python 3.12` |
| Gateway API CRDs | v1.6.3 |
| Gateway API Inference Extension | v1.6.2 |
| agentgateway chart | v1.7.0 |
| llm-d router chart | v0.9.0 |
| llm-d inference simulator | v0.8.2 |

`:latest` for the vLLM CPU image is a moving target; the digest above is the exact image these results came from. If a later image breaks the lab, you can get the known-good one with `docker pull public.ecr.aws/q9t5s3a7/vllm-cpu-release-repo@sha256:66064cf683152e60eff2e5b18ec2d4ace236fb063c0a241f918691db9caddcf4`, and please open an issue with the version your image reports.
