# ai-secure-inference-lab: run `make help`
SHELL := /bin/bash
.DEFAULT_GOAL := help
.PHONY: $(shell sed -n 's/^\([a-zA-Z][a-zA-Z0-9_-]*\):.*/\1/p' $(MAKEFILE_LIST))

CLUSTER ?= llm-lab
NS ?= llm
URL ?= http://localhost:8000/v1

# vLLM CPU image. The kustomize overlays name the x86_64 image; the apply step swaps in $(CPU_IMAGE).
# Apple Silicon / arm64 uses the arm64 repo and is UNTESTED.
ARCH := $(shell uname -m)
CPU_IMAGE_DEFAULT := public.ecr.aws/q9t5s3a7/vllm-cpu-release-repo:latest
ifneq (,$(filter arm64 aarch64,$(ARCH)))
  TORCH_ARCH := aarch64
  CPU_IMAGE ?= public.ecr.aws/q9t5s3a7/vllm-arm64-cpu-release-repo:latest
else
  TORCH_ARCH := x86_64
  CPU_IMAGE ?= $(CPU_IMAGE_DEFAULT)
endif
apply_vllm = kubectl kustomize $(1) | sed 's|$(CPU_IMAGE_DEFAULT)|$(CPU_IMAGE)|' | kubectl apply -f -

help: ## Show this help
	@grep -hE '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  %-24s %s\n", $$1, $$2}'

doctor: ## Check tools, Docker memory and CPU architecture before starting
	@ok=1; for t in docker kind kubectl helm python3 curl; do \
	  if command -v $$t >/dev/null 2>&1; then echo "ok       $$t"; else echo "MISSING  $$t"; ok=0; fi; done; \
	mem=$$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0); gb=$$((mem/1073741824)); \
	echo "Docker memory: $${gb} GB (about 12 needed for labs 1,2,4; 16 for lab 3 with 2 real replicas)"; \
	if [ "$$gb" -lt 12 ]; then echo "WARN     raise Docker Desktop memory (Settings > Resources)"; ok=0; fi; \
	echo "CPU arch: $(ARCH) -> vLLM image $(CPU_IMAGE)"; \
	case "$(ARCH)" in arm64|aarch64) echo "NOTE     the arm64 path is untested";; esac; \
	if [ $$ok = 1 ]; then echo "Ready."; else echo "Fix the items above first."; exit 1; fi

.venv/bin/hf:
	python3 -m venv .venv
	.venv/bin/pip install -q -U huggingface_hub uv

# ---------------- Lab 1: serve a model on Kubernetes ----------------
kind-up: ## Create the local kind cluster (1 control plane + 3 workers)
	kind create cluster --name $(CLUSTER) --config kind/kind-config.yaml

kind-down: ## Delete the kind cluster and everything in it
	kind delete cluster --name $(CLUSTER)

kind-load: ## Pull the vLLM CPU image on the host and load it into the workers
	docker pull $(CPU_IMAGE)
	kind load docker-image $(CPU_IMAGE) --name $(CLUSTER) --nodes $$(kind get nodes --name $(CLUSTER) | grep worker | paste -sd, -)

model-download: .venv/bin/hf ## Download Qwen2.5-0.5B-Instruct to ./model-cache/qwen
	.venv/bin/hf download Qwen/Qwen2.5-0.5B-Instruct --local-dir model-cache/qwen

model-copy: ## Copy the model onto each kind worker at /opt/models/qwen
	for n in $$(kind get nodes --name $(CLUSTER) | grep worker); do \
	  docker exec $$n mkdir -p /opt/models && docker cp model-cache/qwen $$n:/opt/models/ ; done

vllm-up: ## Deploy 1 vLLM replica (CPU, offline, model read from the node)
	$(call apply_vllm,manifests/vllm/overlays/cpu-local)

port-forward: ## Forward vLLM to localhost:8000 (waits for the rollout; first start takes 5-15 min)
	kubectl -n $(NS) rollout status deploy/vllm --timeout=30m
	kubectl -n $(NS) port-forward svc/vllm 8000:8000

debug: ## Pod events and node allocation
	kubectl -n $(NS) get pods -o wide
	kubectl -n $(NS) describe pod -l app.kubernetes.io/name=vllm | sed -n '/Events:/,$$p'
	kubectl describe nodes | grep -A6 'Allocated resources'

loadtest: ## Unique-prompt load test against localhost:8000
	python3 loadtest/prefix_bench.py --url $(URL) --requests 40 --concurrency 4

loadtest-shared-prefix: ## Shared-prefix load test against localhost:8000
	python3 loadtest/prefix_bench.py --url $(URL) --requests 120 --concurrency 8 --shared-prefix

# ---------------- Lab 2: scan the model supply chain ----------------
scan-test: .venv/bin/hf ## ModelScan: flag a harmless test pickle, pass the real model
	python3 scripts/make_test_pickle.py evil-test.pkl
	-.venv/bin/uvx --python 3.12 modelscan -p evil-test.pkl
	-.venv/bin/uvx --python 3.12 modelscan -p model-cache/qwen
	@echo "First scan is EXPECTED to flag a CRITICAL issue. Exit code 3 on the second means nothing scannable (safetensors only), which is fine."

# ---------------- Lab 3: route with llm-d ----------------
GWAPI_VER ?= v1.6.3
IGW_VER ?= v1.6.2
AGW_VER ?= v1.7.0
ROUTER_VER ?= v0.9.0
LLMD_NS ?= llm-d-sim

llmd-crds: ## Install Gateway API + Inference Extension CRDs
	kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/$(GWAPI_VER)/standard-install.yaml
	kubectl apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/$(IGW_VER)/manifests.yaml

llmd-agentgateway: ## Install the agentgateway controller
	helm upgrade -i --create-namespace -n agentgateway-system --version $(AGW_VER) agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds
	helm upgrade -i -n agentgateway-system --version $(AGW_VER) --set inferenceExtension.enabled=true agentgateway oci://cr.agentgateway.dev/charts/agentgateway
	kubectl -n agentgateway-system rollout status deploy --timeout=180s

llmd-sim-up: ## llm-d with 3 simulated model servers (no real model, tiny CPU cost)
	kubectl create namespace $(LLMD_NS) --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -f manifests/llm-d/sim/sim-deployment.yaml
	kubectl -n $(LLMD_NS) wait --for=condition=available --timeout=180s deployment/vllm-qwen3-32b
	kubectl apply -f manifests/llm-d/sim/gateway.yaml
	kubectl -n $(LLMD_NS) wait --for=condition=Programmed --timeout=180s gateway/inference-gateway
	helm upgrade -i vllm-qwen3-32b oci://ghcr.io/llm-d/charts/llm-d-router-gateway -n $(LLMD_NS) --version $(ROUTER_VER) \
	  --set router.modelServers.matchLabels.app=vllm-qwen3-32b \
	  --set router.epp.resources.requests.cpu=100m --set router.epp.resources.requests.memory=128Mi --set router.epp.resources.limits.memory=512Mi \
	  --set provider.name=none --set httpRoute.create=true --set httpRoute.inferenceGatewayName=inference-gateway
	kubectl -n $(LLMD_NS) get inferencepool,httproute,gateway

llmd-sim-forward: ## Forward the simulator gateway to localhost:8081
	kubectl -n $(LLMD_NS) port-forward service/inference-gateway 8081:80

llmd-sim-test: ## Send one request through the simulator gateway
	curl -s -i http://localhost:8081/v1/completions -H 'Content-Type: application/json' \
	  -d '{"model":"Qwen/Qwen3-32B","prompt":"What is the warmest city in the USA?","max_tokens":50}' | head -20

llmd-sim-down: ## Remove the simulator stack
	-helm uninstall vllm-qwen3-32b -n $(LLMD_NS)
	-kubectl delete namespace $(LLMD_NS)

llmd-real-up: ## llm-d in front of 2 real vLLM replicas (needs ~16 GB Docker memory)
	-kubectl -n $(LLMD_NS) scale deploy --all --replicas=0
	$(call apply_vllm,manifests/vllm/overlays/cpu-local-llmd)
	kubectl -n $(NS) rollout status deploy/vllm --timeout=40m
	kubectl apply -f manifests/llm-d/real/gateway.yaml
	kubectl -n $(NS) wait --for=condition=Programmed --timeout=180s gateway/inference-gateway
	helm upgrade -i vllm-pool oci://ghcr.io/llm-d/charts/llm-d-router-gateway -n $(NS) --version $(ROUTER_VER) -f manifests/llm-d/real/router-values.yaml
	kubectl -n $(NS) get pods -o wide
	kubectl -n $(NS) get inferencepool,httproute,gateway

llmd-real-forward: ## Forward the router gateway to localhost:8082
	kubectl -n $(NS) port-forward service/inference-gateway 8082:80

llmd-real-test: ## Send one chat request through the router
	curl -s -i http://localhost:8082/v1/chat/completions -H 'Content-Type: application/json' \
	  -d '{"model":"Qwen/Qwen2.5-0.5B-Instruct","messages":[{"role":"user","content":"Say hi in five words."}],"max_tokens":30}' | head -20

llmd-real-down: ## Remove the router and go back to 1 plain vLLM replica
	-helm uninstall vllm-pool -n $(NS)
	-kubectl delete -f manifests/llm-d/real/gateway.yaml
	$(call apply_vllm,manifests/vllm/overlays/cpu-local)

REQS ?= 40
CONC ?= 4
GROUPS_N ?= 1
RULES ?= 30
SALT ?= $(shell date +%s)

bench-run:
	kubectl -n $(NS) create configmap bench-script --from-file=loadtest/prefix_bench.py --dry-run=client -o yaml | kubectl apply -f -
	-kubectl -n $(NS) delete job bench-$(NAME) --ignore-not-found
	sed -e 's|@NAME@|$(NAME)|' -e 's|@URL@|$(BENCH_URL)|' -e 's|@REQS@|$(REQS)|' -e 's|@CONC@|$(CONC)|' -e 's|@GROUPS@|$(GROUPS_N)|' -e 's|@RULES@|$(RULES)|' -e 's|@SALT@|$(SALT)|' manifests/bench/job.yaml.tpl | kubectl apply -f -
	@for i in $$(seq 240); do \
	  s=$$(kubectl -n $(NS) get job/bench-$(NAME) -o jsonpath='{.status.succeeded}'); f=$$(kubectl -n $(NS) get job/bench-$(NAME) -o jsonpath='{.status.failed}'); \
	  if [ "$$s" = 1 ] || [ -n "$$f" ]; then break; fi; sleep 10; done
	kubectl -n $(NS) logs job/bench-$(NAME)

bench-direct: ## In-cluster benchmark against the plain Service (REQS, CONC, GROUPS_N, RULES)
	$(MAKE) bench-run NAME=direct BENCH_URL=http://vllm.$(NS).svc:8000/v1

bench-llmd: ## Same benchmark through the llm-d router
	$(MAKE) bench-run NAME=llmd BENCH_URL=http://inference-gateway.$(NS).svc:80/v1

# ---------------- Lab 4: attack and defend ----------------
PREFIX ?= before-guardrail

garak-baseline: .venv/bin/hf ## garak prompt-injection probe against localhost:8000, no guard (slow on CPU)
	.venv/bin/uvx --python 3.12 garak --model_type openai.OpenAICompatible \
	  --model_name Qwen/Qwen2.5-0.5B-Instruct \
	  --generator_option_file redteam/garak-local.json \
	  --probes promptinject.HijackHateHumansMini --generations 1 \
	  --report_prefix $(CURDIR)/redteam/reports/$(PREFIX)

guard-model-download: .venv/bin/hf ## Download the prompt-injection classifier (~700 MB)
	.venv/bin/hf download protectai/deberta-v3-base-prompt-injection-v2 --local-dir model-cache/guard --exclude "onnx/*" --exclude "*.onnx" --exclude "openvino/*"

guard-model-copy: ## Copy the classifier onto each kind worker
	for n in $$(kind get nodes --name $(CLUSTER) | grep worker); do \
	  docker exec $$n rm -rf /opt/models/guard && docker exec $$n mkdir -p /opt/models && docker cp model-cache/guard $$n:/opt/models/ ; done

TORCH_VER ?= 2.15.0
TORCH_WHEEL := torch-$(TORCH_VER)+cpu-cp312-cp312-manylinux_2_28_$(TORCH_ARCH).whl
guard-wheel: ## OPTIONAL: pre-download torch with a resumable curl if docker build times out
	mkdir -p guard/wheels
	test -f "guard/wheels/$(TORCH_WHEEL).done" || { curl -fL -C - --retry 20 --retry-all-errors --retry-delay 3 -o "guard/wheels/$(TORCH_WHEEL)" "https://download-r2.pytorch.org/whl/cpu/torch-$(TORCH_VER)%2Bcpu-cp312-cp312-manylinux_2_28_$(TORCH_ARCH).whl" && touch "guard/wheels/$(TORCH_WHEEL).done"; }

guard-build: ## Build the guard image (uses guard/wheels if you ran guard-wheel)
	docker build -t guard-proxy:local guard/

guard-load: ## Load the guard image into the kind workers
	kind load docker-image guard-proxy:local --name $(CLUSTER) --nodes $$(kind get nodes --name $(CLUSTER) | grep worker | paste -sd, -)

guard-deploy: ## Deploy the guard (namespace 'gateway')
	kubectl apply -k guard/k8s

guard-forward: ## Forward the guard to localhost:8080
	kubectl -n gateway rollout status deploy/guard --timeout=10m
	kubectl -n gateway port-forward svc/guard 8080:8080

guard-check: ## Benign prompts should pass, attack prompts should be blocked
	python3 guard/check_prompts.py guard/benign.txt
	python3 guard/check_prompts.py guard/attacks.txt

guard-stats: ## Guard counters and average classification time
	curl -s localhost:8080/guard/stats; echo

loadtest-guard: ## Load test through the guard (latency cost)
	python3 loadtest/prefix_bench.py --url http://localhost:8080/v1 --requests 40 --concurrency 4

garak-guarded: .venv/bin/hf ## Same garak probe through the guard
	.venv/bin/uvx --python 3.12 garak --model_type openai.OpenAICompatible \
	  --model_name Qwen/Qwen2.5-0.5B-Instruct \
	  --generator_option_file redteam/garak-guarded.json \
	  --probes promptinject.HijackHateHumansMini --generations 1 \
	  --report_prefix $(CURDIR)/redteam/reports/after-guardrail

guard-via-llmd: ## Point the guard at the llm-d router (needs llmd-real-up)
	kubectl -n gateway set env deploy/guard UPSTREAM=http://inference-gateway.$(NS).svc:80
	kubectl -n gateway rollout status deploy/guard --timeout=10m

guard-direct: ## Point the guard straight at the vLLM Service (default)
	kubectl -n gateway set env deploy/guard UPSTREAM=http://vllm.$(NS).svc:8000
	kubectl -n gateway rollout status deploy/guard --timeout=10m

# ---------------- Stop and resume ----------------
stop: ## Stop the cluster but keep all state (quit Docker Desktop afterwards if you like)
	-pkill -f "kubectl port-forward"
	-kubectl -n $(NS) delete job bench-direct bench-llmd --ignore-not-found
	docker stop $$(docker ps -q --filter name=$(CLUSTER))

resume: ## Start the stopped cluster again and wait for the nodes
	docker start $$(docker ps -aq --filter name=$(CLUSTER))
	@echo "Waiting for 4 Ready nodes..."
	@until [ "$$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready')" = 4 ]; do sleep 5; done
	kubectl get nodes
	kubectl -n $(NS) get pods
