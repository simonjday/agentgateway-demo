# agentgateway on Kubernetes: A Platform Engineer’s Deep Dive

*MCP proxying, LLM routing, content guardrails, JWT RBAC, and prompt enrichment — all from a single Kubernetes-native control plane.*

-----

## What is agentgateway?

agentgateway is an open-source, Kubernetes-native AI and MCP gateway from the Linux Foundation (originally developed by Solo.io). It sits between your AI clients, LLM providers, and MCP tool servers — providing a unified control plane for routing, governance, and observability across all AI traffic.

Where traditional API gateways were built for HTTP services, agentgateway is built for the agentic AI stack: it understands LLM tokens, MCP tool calls, and JWT claims natively, and lets you enforce policy on them using Kubernetes CRDs.

Architecture-wise it is closer to Envoy/Istio than a conventional gateway. A Go-based controller manages configuration via Kubernetes CRDs and pushes xDS config to Rust-based proxy pods spawned dynamically from `Gateway` resources.

> 📸 **[SCREENSHOT 1 — Grafana_dashboard.png]**
> *agentgateway Overview dashboard (Grafana ID 24590) — total requests, P95 latency, MCP tool calls, request rate by route (kubernetes-mcp and ollama), status code breakdown including 422 (guardrails blocked) and 429 (rate limited).*

-----

## Lab Setup

Everything in this post was tested on a local kind cluster on an M3 MacBook Pro:

- **Cluster:** kind (single node)
- **Local inference:** Ollama — `llama3.2:3b`, `qwen3-coder:30b`
- **Observability:** kube-prometheus-stack + Grafana dashboard 24590
- **MCP server:** `ghcr.io/containers/kubernetes-mcp-server:latest` deployed in-cluster
- **MCP client:** VS Code GitHub Copilot Agent mode
- **agentgateway version:** v1.2.1

-----

## Installation

Two Helm charts — CRDs must be installed before the control plane or the controller crash-loops waiting for its own CRDs to exist.

```bash
# 1. Gateway API CRDs
kubectl apply --server-side --force-conflicts \
  -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.0/standard-install.yaml

# 2. agentgateway CRDs — install first
helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --namespace agentgateway-system --create-namespace --version v1.2.1

# 3. Control plane
helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --namespace agentgateway-system --version v1.2.1 \
  --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true \
  --wait

# 4. Proxy — spawned by creating a Gateway resource
kubectl apply -f- <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: agentgateway-proxy
  namespace: agentgateway-system
spec:
  gatewayClassName: agentgateway
  listeners:
  - protocol: HTTP
    port: 80
    name: http
    allowedRoutes:
      namespaces:
        from: All
EOF
```

Verify everything is running:

```bash
kubectl get pods -n agentgateway-system
kubectl get gateway agentgateway-proxy -n agentgateway-system
```

The gateway proxy is healthy when `PROGRAMMED=True`. Test with:

```bash
kubectl port-forward deployment/agentgateway-proxy -n agentgateway-system 8080:80 &
curl http://localhost:8080/
# Expected: 404 "route not found" — proxy healthy, no routes yet
```

-----

## LLM Routing — Ollama

Ollama runs outside the cluster on the host machine. agentgateway needs a headless Service and EndpointSlice to reach it via stable in-cluster DNS.

```bash
kubectl apply -f- <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ollama
  namespace: agentgateway-system
spec:
  type: ClusterIP
  clusterIP: None
  ports:
  - port: 11434
    targetPort: 11434
    protocol: TCP
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: ollama
  namespace: agentgateway-system
  labels:
    kubernetes.io/service-name: ollama
addressType: IPv4
endpoints:
- addresses:
  - 192.168.1.21   # your Mac's LAN IP
ports:
- port: 11434
  protocol: TCP
---
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: ollama
  namespace: agentgateway-system
spec:
  ai:
    provider:
      openai:        # Ollama exposes an OpenAI-compatible API
        model: llama3.2:3b
      host: ollama.agentgateway-system.svc.cluster.local
      port: 11434
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ollama
  namespace: agentgateway-system
spec:
  parentRefs:
  - name: agentgateway-proxy
    namespace: agentgateway-system
  rules:
  - backendRefs:
    - name: ollama
      namespace: agentgateway-system
      group: agentgateway.dev
      kind: AgentgatewayBackend
EOF
```

Test:

```bash
curl localhost:8080/v1/chat/completions \
  -H "content-type: application/json" \
  -d '{"model":"llama3.2:3b","messages":[{"role":"user","content":"ping"}]}' | jq
```

-----

## MCP Server — Kubernetes Tools via VS Code

Deploy the `containers/kubernetes-mcp-server` in-cluster with a read-only ClusterRole, wire it to agentgateway, and connect VS Code GitHub Copilot.

```bash
kubectl apply -f- <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: mcp
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kubernetes-mcp-server
  namespace: mcp
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kubernetes-mcp-server
rules:
- apiGroups: ["*"]
  resources: ["*"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["pods/log", "pods/exec"]
  verbs: ["get", "create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kubernetes-mcp-server
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kubernetes-mcp-server
subjects:
- kind: ServiceAccount
  name: kubernetes-mcp-server
  namespace: mcp
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kubernetes-mcp-server
  namespace: mcp
spec:
  selector:
    matchLabels:
      app: kubernetes-mcp-server
  template:
    metadata:
      labels:
        app: kubernetes-mcp-server
    spec:
      serviceAccountName: kubernetes-mcp-server
      containers:
      - name: kubernetes-mcp-server
        image: ghcr.io/containers/kubernetes-mcp-server:latest
        args: ["--port", "8080"]
        ports:
        - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: kubernetes-mcp-server
  namespace: mcp
  labels:
    app: kubernetes-mcp-server
spec:
  selector:
    app: kubernetes-mcp-server
  ports:
  - port: 80
    targetPort: 8080
    appProtocol: agentgateway.dev/mcp
---
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: kubernetes-mcp
  namespace: agentgateway-system
spec:
  mcp:
    targets:
    - name: kubernetes-mcp-target
      static:
        host: kubernetes-mcp-server.mcp.svc.cluster.local
        port: 80
        protocol: StreamableHTTP
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: kubernetes-mcp
  namespace: agentgateway-system
spec:
  parentRefs:
  - name: agentgateway-proxy
    namespace: agentgateway-system
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /mcp
    backendRefs:
    - name: kubernetes-mcp
      group: agentgateway.dev
      kind: AgentgatewayBackend
EOF
```

Add to VS Code `mcp.json`:

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

> 📸 **[SCREENSHOT 2 — VS_Code_Copilot_with_pod_list.png]**
> *VS Code GitHub Copilot Agent mode — `kubernetes-agentgateway` MCP server returning a full pod list across all namespaces. Tool call attributed to `kubernetes-agentgateway (MCP Server)`. 19 pods, all Running.*

-----

## Observability

The proxy exposes Prometheus metrics on port 15020. Apply a ServiceMonitor:

```bash
kubectl apply -f- <<EOF
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: agentgateway-proxy
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  namespaceSelector:
    matchNames:
    - agentgateway-system
  selector:
    matchLabels:
      app.kubernetes.io/name: agentgateway-proxy
  endpoints:
  - port: metrics
    interval: 15s
    path: /metrics
EOF
```

> 📸 **[SCREENSHOT 3 — Prometheus_targets.png]**
> *Prometheus target health — `agentgateway-proxy` showing 1/1 UP, scraping <http://10.244.0.7:15020/metrics>. Labels show namespace, pod, and service attribution.*

Import Grafana dashboard ID `24590`. It tracks requests, P95 latency, token usage (input/output), MCP tool calls, and Tokio runtime metrics natively — no additional instrumentation required.

-----

## Content Guardrails — PII Filtering

`AgentgatewayPolicy` supports input blocking and output masking with built-in PII detectors and custom regex. No external dependency required.

```bash
kubectl apply -f- <<'EOF'
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: ollama-guardrails
  namespace: agentgateway-system
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: ollama
  backend:
    ai:
      promptGuard:
        request:
        - regex:
            action: Reject
            builtins:
            - CreditCard
            - Ssn
            - Email
            - PhoneNumber
            matches:
            - "(?i)(api[_-]?key|secret|password|token)\\s*[:=]\\s*\\S+"
          response:
            message: "Request blocked: sensitive data detected (PII or credentials)"
            statusCode: 422
        response:
        - regex:
            action: Mask
            builtins:
            - CreditCard
            - Ssn
            - Email
EOF
```

> 📸 **[SCREENSHOT 4 — Screenshot_2026-05-31_at_17_30_55.png]**
> *Terminal — guardrails blocking credit card (4111-1111-1111-1111), SSN (123-45-6789), and api_key credentials with HTTP 422. Clean request passes with HTTP 200. No client-side changes required.*

Built-in detectors: `CreditCard`, `Ssn`, `Email`, `PhoneNumber`, `CaSin`. Actions are `Reject` (block with status code) or `Mask` (replace with token e.g. `<CREDIT_CARD>`).

Two gotchas worth noting:

- Use `<<'EOF'` (single-quoted heredoc) for regex patterns — unquoted heredoc interpolates backslashes
- Action values are title-case: `Reject` / `Mask` not `REJECT` / `MASK`

-----

## JWT-Based User Identity and MCP Tool RBAC

Apply JWT validation at the Gateway level, then CEL-based tool access control per user on the MCP backend. No external IdP required for testing — agentgateway validates JWTs inline against an embedded JWKS.

```bash
kubectl apply -f- <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: jwt-authn
  namespace: agentgateway-system
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: agentgateway-proxy
  traffic:
    jwtAuthentication:
      mode: Strict
      providers:
      - issuer: solo.io
        jwks:
          inline: '{"keys":[{"use":"sig","kty":"RSA","kid":"5891645032159894383",...}]}'
---
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: jwt-mcp-rbac
  namespace: agentgateway-system
spec:
  targetRefs:
  - group: agentgateway.dev
    kind: AgentgatewayBackend
    name: kubernetes-mcp
  backend:
    mcp:
      authorization:
        action: Allow
        policy:
          matchExpressions:
          - 'jwt.sub == "bob"'
          - 'jwt.sub == "alice" && (mcp.tool.name == "pods_list" || mcp.tool.name == "namespaces_list" || mcp.tool.name == "nodes_top")'
EOF
```

Result: unauthenticated requests return 401. Alice sees 3 read-only tools. Bob sees all 19 tools including `pods_exec`, `pods_delete`, `resources_create_or_update`.

> 📸 **[SCREENSHOT 5 — Screenshot_2026-05-31_at_17_33_47.png]**
> *Terminal — JWT RBAC: Alice (sub=alice) sees 3 tools. Bob (sub=bob) sees 19 tools including write operations. Same gateway, same MCP server, differentiated by JWT claims.*

-----

## API Key Authentication

API keys are stored as Kubernetes secrets with type `extauth.solo.io/apikey`. Policy targets secrets by label selector — adding or removing the label is instant key revocation with no policy change.

```bash
kubectl apply -f- <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: apikey-team-dev
  namespace: agentgateway-system
  labels:
    team: dev
    access: allowed
type: extauth.solo.io/apikey
stringData:
  api-key: dev-key-abc123
---
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: apikey-auth
  namespace: agentgateway-system
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: agentgateway-proxy
  traffic:
    apiKeyAuthentication:
      mode: Strict
      secretSelector:
        matchLabels:
          access: allowed
EOF
```

Instant revocation:

```bash
# Revoke — immediate effect
kubectl label secret apikey-team-dev -n agentgateway-system access-

# Restore
kubectl label secret apikey-team-dev -n agentgateway-system access=allowed
```

-----

## Prompt Enrichment

Inject system prompts at the gateway — every request gets consistent context without clients needing to send it. The gateway prepends; client-provided system prompts are additive.

```bash
kubectl apply -f- <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: ollama-prompt-enrichment
  namespace: agentgateway-system
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: ollama
  backend:
    ai:
      prompt:
        prepend:
        - role: system
          content: "You are a data extraction assistant. Always respond with structured CSV format only. No prose, no explanation. Columns: city,continent"
EOF
```

> 📸 **[SCREENSHOT 6 — Screenshot_2026-05-31_at_17_36_59.png]**
> *WITHOUT enrichment: same user message produces freeform prose — the model has no output format instructions.*

> 📸 **[SCREENSHOT 7 — Screenshot_2026-05-31_at_17_37_33.png]**
> *WITH enrichment: identical request returns structured CSV. The gateway injected the system prompt — the client sent nothing.*

-----

## Rate Limiting

Local rate limiting is per-instance and request-based (not token-based). For true LLM token budgets use global rate limiting with a Redis-backed rate-limit server.

```bash
kubectl apply -f- <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: ollama-rate-limit
  namespace: agentgateway-system
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: ollama
  traffic:
    rateLimit:
      local:
      - tokens: 3
        unit: Minutes
EOF
```

Requests beyond the limit return 429. Remove the policy to restore access.

-----

## MCP Tool Restrictions

Restrict which tools are visible per backend — blocked tools are hidden from `tools/list` entirely, not just rejected at call time.

```bash
kubectl apply -f- <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: kubernetes-mcp-tool-restrictions
  namespace: agentgateway-system
spec:
  targetRefs:
  - group: agentgateway.dev
    kind: AgentgatewayBackend
    name: kubernetes-mcp
  backend:
    mcp:
      authorization:
        action: Allow
        policy:
          matchExpressions:
          - 'mcp.tool.name == "pods_list"'
          - 'mcp.tool.name == "namespaces_list"'
          - 'mcp.tool.name == "nodes_top"'
          - 'mcp.tool.name == "resources_list"'
          - 'mcp.tool.name == "resources_get"'
          - 'mcp.tool.name == "pods_log"'
EOF
```

-----

## Key Gotchas

A few things that aren’t obvious from the docs:

- **CRDs before control plane** — install `agentgateway-crds` chart before `agentgateway` or the controller crash-loops indefinitely
- **Single-quoted heredoc for regex** — `<<'EOF'` prevents shell backslash interpolation in regex patterns
- **Action values are title-case** — `Reject` / `Mask` not `REJECT` / `MASK`
- **`matchExpressions` not supported in `secretSelector`** — use `matchLabels` with a shared label on secrets
- **metrics-server needs `--kubelet-insecure-tls` on kind** — required for `nodes_top` MCP tool and `kubectl top`
- **LLM route path** — requests must go to `/v1/chat/completions` not `/`
- **SSE vs StreamableHTTP** — StreamableHTTP is simpler for request/response MCP tool calls; SSE requires session pre-negotiation
- **Policy intersection** — multiple `AgentgatewayPolicy` resources targeting the same backend apply simultaneously; the effective result is their intersection

-----

## Competitors and Alternatives

agentgateway sits in a growing market. Here’s how the landscape looks:

**Direct AI gateway competitors**

- **Bifrost** (maximhq) — UI-driven, 20+ providers, semantic caching via Qdrant, Go/WASM plugins. Strong on ease of setup and provider breadth. Enterprise tier adds RBAC, clustering, and compliance features. Less Kubernetes-native. *(Subject of a separate post.)*
- **LiteLLM** — Python-based proxy, very broad provider support, popular in the data science community. Significantly higher latency than Bifrost or agentgateway at scale. Strong OpenAI compatibility layer.
- **Kong AI Gateway** — enterprise-grade, built on Kong’s existing gateway infrastructure. Strong if you’re already a Kong shop. Heavier operationally.
- **Traefik AI** — Traefik’s AI plugin layer. Natural fit if Traefik is already your ingress controller.

**MCP-specific infrastructure**

- **ToolHive (Stacklok)** — Kubernetes operator for MCP servers. Manages MCP server lifecycle rather than proxying. Complementary to agentgateway rather than competitive.
- **mcp-proxy** — lightweight stdio-to-HTTP bridge. No governance layer, just transport conversion.

**Observability-focused**

- **Langfuse** — LLM observability platform. Agentgateway has a Langfuse integration. Complementary.
- **LangSmith** — LangChain’s observability layer. Same pattern — agentgateway integrates with it.

**Where agentgateway wins:** Kubernetes-nativeness, Gateway API integration, MCP governance (CEL RBAC, tool restrictions, JWT auth), content guardrails in OSS, prompt enrichment. It’s the right choice for platform engineering teams running GitOps workflows who need to govern AI tool access as a first-class platform concern.

-----

## Full Setup Guide

The complete setup guide with all YAML, tested commands, troubleshooting notes, and gotchas is available at:

`https://github.com/simonjday/bifrost-k8s-demo/docs/agentgateway-kind-setup.md`

*All testing performed on a personal lab environment. No production systems or client environments were involved.*