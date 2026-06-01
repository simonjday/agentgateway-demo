# agentgateway-demo

A hands-on demo of [agentgateway](https://agentgateway.dev) v1.2.1 on a local kind cluster,
covering LLM routing, MCP proxying, observability, and policy governance.

## What This Demo Covers

| Feature | Manifest |
|---|---|
| LLM routing to Ollama | `manifests/ollama/` |
| Kubernetes MCP server | `manifests/mcp/` |
| Prometheus + Grafana | `manifests/observability/` |
| MCP tool restrictions | `manifests/policies/mcp-tool-restrictions.yaml` |
| JWT authentication + RBAC | `manifests/policies/jwt-authn.yaml`, `jwt-mcp-rbac.yaml` |
| API key authentication | `manifests/policies/apikey-auth.yaml` |
| Rate limiting | `manifests/policies/rate-limit.yaml` |
| Content guardrails | `manifests/policies/guardrails.yaml` |
| Prompt enrichment | `manifests/policies/prompt-enrichment.yaml` |

## Prerequisites

- Docker Desktop
- `kind`, `kubectl`, `helm` installed
- Ollama installed and running locally (`OLLAMA_HOST=0.0.0.0:11434 ollama serve`)
- At least one model pulled (`ollama pull llama3.2:3b`)

## Quick Start

```bash
# 1. Create kind cluster
kind create cluster

# 2. Install Gateway API CRDs
kubectl apply --server-side --force-conflicts \
  -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.0/standard-install.yaml

# 3. Install agentgateway CRDs (must be before control plane)
helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --namespace agentgateway-system --create-namespace --version v1.2.1

# 4. Install agentgateway control plane
helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --namespace agentgateway-system --version v1.2.1 \
  --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true \
  --wait

# 5. Create proxy
kubectl apply -f manifests/core/gateway.yaml

# 6. Deploy Ollama route
# Edit manifests/ollama/endpointslice.yaml — replace OLLAMA_IP with your Mac's LAN IP
kubectl apply -f manifests/ollama/

# 7. Deploy Kubernetes MCP server
kubectl apply -f manifests/mcp/

# 8. Install metrics-server (required for nodes_top MCP tool)
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl patch deployment metrics-server -n kube-system --type=json -p='[
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}
]'

# 9. Install observability stack
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade -i kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace --wait
kubectl apply -f manifests/observability/servicemonitor.yaml
```

## Port Forwards

```bash
# agentgateway proxy (LLM + MCP)
kubectl port-forward deployment/agentgateway-proxy -n agentgateway-system 8080:80 &

# Prometheus
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &

# Grafana (import dashboard ID 24590)
export GRAFANA_POD=$(kubectl -n monitoring get pod \
  -l "app.kubernetes.io/name=grafana,app.kubernetes.io/instance=kube-prometheus-stack" -oname)
kubectl -n monitoring port-forward $GRAFANA_POD 3000 &

# Kill all port-forwards
pkill -f "kubectl port-forward"
```

Grafana default credentials: `admin` / retrieve with:
```bash
kubectl -n monitoring get secrets kube-prometheus-stack-grafana \
  -o jsonpath="{.data.admin-password}" | base64 -d ; echo
```

## Test LLM Routing

```bash
curl localhost:8080/v1/chat/completions \
  -H "content-type: application/json" \
  -d '{"model":"llama3.2:3b","messages":[{"role":"user","content":"ping"}]}' | jq
```

## Test MCP

```bash
# Initialize session
INIT=$(curl -si http://localhost:8080/mcp/mcp \
  -H "Accept: application/json, text/event-stream" \
  -H "content-type: application/json" \
  -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}')
SESSION=$(echo "$INIT" | grep -i "mcp-session-id" | awk '{print $2}' | tr -d '\r')

# List tools
curl -s http://localhost:8080/mcp/mcp \
  -H "Accept: application/json, text/event-stream" \
  -H "content-type: application/json" \
  -H "mcp-session-id: $SESSION" \
  -d '{"jsonrpc":"2.0","method":"tools/list","params":{},"id":2}' | grep -o '"name":"[^"]*"'
```

## VS Code MCP Integration

Add to `.vscode/mcp.json`:

```json
{
  "servers": {
    "kubernetes-agentgateway": {
      "type": "http",
      "url": "http://localhost:8080/mcp/mcp"
    }
  }
}
```

## Apply Policies

Policies are independent — apply any combination:

```bash
# MCP tool restrictions (read-only tools only)
kubectl apply -f manifests/policies/mcp-tool-restrictions.yaml

# JWT auth + per-user MCP RBAC (alice=read-only, bob=full)
kubectl apply -f manifests/policies/jwt-authn.yaml
kubectl apply -f manifests/policies/jwt-mcp-rbac.yaml

# API key authentication
kubectl apply -f manifests/policies/apikey-secrets.yaml
kubectl apply -f manifests/policies/apikey-auth.yaml

# Rate limiting (3 requests/minute on Ollama route)
kubectl apply -f manifests/policies/rate-limit.yaml

# Content guardrails (PII blocking + output masking)
kubectl apply -f manifests/policies/guardrails.yaml

# Prompt enrichment (CSV output enforcement)
kubectl apply -f manifests/policies/prompt-enrichment.yaml
```

## Documentation

| Doc | Description |
|---|---|
| [Setup Guide](docs/agentgateway-kind-setup.md) | Full step-by-step setup guide with troubleshooting |
| [Medium Article](docs/agentgateway-deep-dive-medium-final.md) | Platform engineer's deep dive |

## Repo Structure

```
.
├── README.md
├── docs/
│   ├── agentgateway-kind-setup.md
│   └── agentgateway-deep-dive-medium-final.md
└── manifests/
    ├── core/
    │   └── gateway.yaml
    ├── ollama/
    │   ├── service.yaml
    │   ├── endpointslice.yaml
    │   ├── backend.yaml
    │   └── httproute.yaml
    ├── mcp/
    │   ├── namespace.yaml
    │   ├── rbac.yaml
    │   ├── deployment.yaml
    │   ├── service.yaml
    │   ├── backend.yaml
    │   └── httproute.yaml
    ├── observability/
    │   └── servicemonitor.yaml
    └── policies/
        ├── mcp-tool-restrictions.yaml
        ├── jwt-authn.yaml
        ├── jwt-mcp-rbac.yaml
        ├── apikey-secrets.yaml
        ├── apikey-auth.yaml
        ├── rate-limit.yaml
        ├── guardrails.yaml
        └── prompt-enrichment.yaml
```

## Known Gotchas

- Install `agentgateway-crds` before `agentgateway` — controller crash-loops without CRDs
- Use `<<'EOF'` for regex patterns in policies — unquoted heredoc interpolates backslashes
- Policy action values are title-case: `Reject` / `Mask` not `REJECT` / `MASK`
- `matchExpressions` not supported in `secretSelector` — use `matchLabels` with a shared label
- metrics-server requires `--kubelet-insecure-tls` on kind
- LLM requests must go to `/v1/chat/completions` not `/`

## References

- [agentgateway docs](https://agentgateway.dev/docs/kubernetes/latest/)
- [Grafana dashboard 24590](https://grafana.com/grafana/dashboards/24590)
- [kubernetes-mcp-server](https://github.com/containers/kubernetes-mcp-server)
