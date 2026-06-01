# agentgateway on kind — Setup Guide

## Overview

This document covers setting up agentgateway v1.2.1 on a local kind cluster, including:
- kind cluster creation
- Gateway API CRDs
- agentgateway control plane and proxy
- Ollama LLM routing
- Prometheus + Grafana observability
- Kubernetes MCP server proxied via agentgateway
- VS Code GitHub Copilot MCP client integration

---

## Prerequisites

- Docker Desktop running
- `kind`, `kubectl`, `helm` installed on macOS
- Ollama installed and running locally

---

## 1. Create kind Cluster

```bash
kind create cluster
```

Verify:

```bash
kubectl get nodes
```

---

## 2. Install Gateway API CRDs

```bash
kubectl apply --server-side --force-conflicts \
  -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.0/standard-install.yaml
```

---

## 3. Install agentgateway

### 3.1 Install agentgateway CRDs

```bash
helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --create-namespace --namespace agentgateway-system \
  --version v1.2.1 \
  --set controller.image.pullPolicy=Always
```

> **Note:** The CRDs chart must be installed before the control plane chart. Installing the
> control plane first causes the controller to crash-loop waiting for
> `agentgatewaybackends.agentgateway.dev` and `agentgatewaypolicies.agentgateway.dev` CRDs.

### 3.2 Install agentgateway control plane

```bash
helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --namespace agentgateway-system \
  --version v1.2.1 \
  --set controller.image.pullPolicy=Always \
  --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true \
  --wait
```

### 3.3 Verify

```bash
kubectl get pods -n agentgateway-system
```

Expected output:

```
NAME                            READY   STATUS    RESTARTS   AGE
agentgateway-65c9bc6694-j2kqm   1/1     Running   0          30s
```

---

## 4. Create Gateway Proxy

```bash
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

Verify the Gateway is programmed and proxy pod is running:

```bash
kubectl get gateway agentgateway-proxy -n agentgateway-system
kubectl get pods -n agentgateway-system
```

Port-forward for local testing:

```bash
kubectl port-forward deployment/agentgateway-proxy -n agentgateway-system 8080:80
```

Test:

```bash
curl -v http://localhost:8080/
# Expected: 404 "route not found" — proxy is healthy, no routes configured yet
```

---

## 5. Ollama LLM Routing

### 5.1 Configure Ollama for external access

By default Ollama only listens on localhost. Restart it bound to all interfaces:

```bash
OLLAMA_HOST=0.0.0.0:11434 ollama serve
```

> **Warning:** Restrict access with firewall rules in non-lab environments.

Verify reachability from your Mac's LAN IP:

```bash
curl http://<YOUR_MAC_IP>:11434/v1/models
```

### 5.2 Deploy Service, EndpointSlice, Backend, and HTTPRoute

Replace `<OLLAMA_IP>` with your Mac's LAN IP (e.g. `192.168.1.21`) and `<MODEL>` with a pulled model name (e.g. `llama3.2:3b`).

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
  - <OLLAMA_IP>
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
      openai:
        model: <MODEL>
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

### 5.3 Test

```bash
curl localhost:8080/v1/chat/completions \
  -H "content-type: application/json" \
  -d '{
    "model": "llama3.2:3b",
    "messages": [{"role": "user", "content": "ping"}]
  }' | jq
```

---

## 6. Metrics Server

kind does not include metrics-server by default. It is required for `kubectl top` and any MCP
tool that queries node or pod resource usage.

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

kind uses self-signed kubelet certs so metrics-server needs `--kubelet-insecure-tls`:

```bash
kubectl patch deployment metrics-server -n kube-system --type=json -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/args/-",
    "value": "--kubelet-insecure-tls"
  }
]'
```

Verify after ~30s:

```bash
kubectl top nodes
kubectl top pods -A
```

---

## 7. Observability — Prometheus + Grafana

### 6.1 Install kube-prometheus-stack

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm upgrade -i kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --wait
```

### 6.2 Configure metrics scraping

The agentgateway proxy exposes Prometheus metrics on port `15020`. The proxy Service includes
this port automatically. Apply a ServiceMonitor to scrape it:

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

Verify the target is up in Prometheus:

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
open http://localhost:9090/targets
```

Search for `agentgateway-proxy` — should show `1/1 up`.

### 6.3 Import Grafana dashboard

Get the Grafana admin password:

```bash
kubectl -n monitoring get secrets kube-prometheus-stack-grafana \
  -o jsonpath="{.data.admin-password}" | base64 -d ; echo
```

Port-forward Grafana:

```bash
export POD_NAME=$(kubectl -n monitoring get pod \
  -l "app.kubernetes.io/name=grafana,app.kubernetes.io/instance=kube-prometheus-stack" -oname)
kubectl -n monitoring port-forward $POD_NAME 3000 &
```

Open `http://localhost:3000`, login as `admin`, then:

**Dashboards → New → Import → ID `24590` → Load → select Prometheus datasource → Import**

---

## 8. Kubernetes MCP Server via agentgateway

Deploy `containers/kubernetes-mcp-server` into the cluster and proxy it through agentgateway,
exposing it to MCP clients such as VS Code GitHub Copilot.

### 7.1 Deploy MCP server with RBAC

The server runs in-cluster using a ServiceAccount with read-only cluster access.

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
EOF
```

### 7.2 Wire into agentgateway

Uses StreamableHTTP protocol. The server exposes `/mcp` for streamable HTTP and `/sse` for SSE.

```bash
kubectl apply -f- <<EOF
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

### 7.3 Verify

```bash
kubectl port-forward deployment/agentgateway-proxy -n agentgateway-system 8080:80 &

curl -s http://localhost:8080/mcp/mcp \
  -H "Accept: application/json, text/event-stream" \
  -H "content-type: application/json" \
  -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}'
```

Expected: JSON response with `serverInfo.name: "kubernetes-mcp-server"`.

### 7.4 Connect VS Code GitHub Copilot

Add to VS Code `mcp.json` (`.vscode/mcp.json` or user-level MCP config):

```jsonc
{
  "servers": {
    "kubernetes-agentgateway": {
      "type": "http",
      "url": "http://localhost:8080/mcp/mcp"
    }
  }
}
```

In Copilot Agent mode, the `kubernetes-agentgateway` server will appear in the MCP tools list.
Requests are routed: **VS Code → agentgateway proxy → Kubernetes MCP server → cluster API**.

> **Note:** The port-forward must be running for VS Code to reach the gateway. In a real
> environment with a LoadBalancer or ingress, replace `localhost:8080` with the external address.

---

## 9. MCP Tool Restrictions

Use `AgentgatewayPolicy` to restrict which MCP tools are visible and callable. Tools not in the
allow list are hidden entirely from `tools/list` — they don't appear as unknown, they simply
don't exist from the client's perspective.

### 9.1 Apply a read-only tool policy

The following policy restricts the kubernetes MCP backend to read-only tools only, blocking
write operations such as `pods_exec`, `resources_create`, and `resources_delete`.

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
          - 'mcp.tool.name == "nodes_list"'
          - 'mcp.tool.name == "nodes_top"'
          - 'mcp.tool.name == "nodes_stats_summary"'
          - 'mcp.tool.name == "resources_list"'
          - 'mcp.tool.name == "resources_get"'
          - 'mcp.tool.name == "pods_log"'
EOF
```

### 9.2 Verify

Initialize a session then test an allowed and a blocked tool:

```bash
# Initialize session
INIT=$(curl -si http://localhost:8080/mcp/mcp \
  -H "Accept: application/json, text/event-stream" \
  -H "content-type: application/json" \
  -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}')

SESSION=$(echo "$INIT" | grep -i "mcp-session-id" | awk '{print $2}' | tr -d '\r')

# Allowed tool — should return data
curl -s http://localhost:8080/mcp/mcp \
  -H "Accept: application/json, text/event-stream" \
  -H "content-type: application/json" \
  -H "mcp-session-id: $SESSION" \
  -d '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"namespaces_list","arguments":{}},"id":2}'

# Blocked tool — should return "Unknown tool"
curl -s http://localhost:8080/mcp/mcp \
  -H "Accept: application/json, text/event-stream" \
  -H "content-type: application/json" \
  -H "mcp-session-id: $SESSION" \
  -d '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"pods_exec","arguments":{"namespace":"default","pod":"test","command":"whoami"}},"id":3}'

# Confirm only allowed tools are listed
curl -s http://localhost:8080/mcp/mcp \
  -H "Accept: application/json, text/event-stream" \
  -H "content-type: application/json" \
  -H "mcp-session-id: $SESSION" \
  -d '{"jsonrpc":"2.0","method":"tools/list","params":{},"id":4}' | grep -o '"name":"[^"]*"'
```

Expected `tools/list` output — only allowed tools returned:

```
"name":"namespaces_list"
"name":"nodes_stats_summary"
"name":"nodes_top"
"name":"pods_list"
"name":"pods_log"
"name":"resources_get"
"name":"resources_list"
```

> **Note:** `nodes_list` was specified in the policy but is not a tool the
> `kubernetes-mcp-server` exposes — it falls under `resources_list`. Blocked tools return
> `Unknown tool` rather than an auth error, meaning they are invisible to the client.

### 9.3 CEL expression reference

| Expression | Effect |
|---|---|
| `mcp.tool.name == "pods_list"` | Allow only `pods_list` |
| `mcp.tool.name.startsWith("pods_")` | Allow all pod tools |
| `jwt.sub == "alice"` | Allow all tools for JWT sub=alice |
| `jwt.sub == "alice" && mcp.tool.name == "pods_list"` | Allow `pods_list` only for alice |

---

## 10. Token Budget / Rate Limiting

agentgateway supports two rate limiting modes for LLM routes:

- **Local** — per-instance request-based limiting. Simple, no external dependencies. Supports
  `Seconds`, `Minutes`, `Hours` units only. Limits apply per proxy instance, not globally.
- **Global** — actual LLM token-based limiting using an external rate-limit server (Redis-backed).
  Supports `unit: Tokens` for true token budget enforcement across all instances.

This section covers local rate limiting, which is sufficient for lab and single-instance
deployments.

> **Important:** Local rate limiting uses `tokens` as a request count, not LLM token count.
> `tokens: 3` means 3 requests per minute, not 3 LLM tokens. For true token-based budgets use
> global rate limiting.

### 10.1 Apply a local rate limit to the Ollama route

```bash
kubectl apply -f- <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: ollama-token-budget
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

### 10.2 Verify

Send 5 requests in quick succession — requests beyond the limit return 429:

```bash
for i in {1..5}; do
  echo "Request $i:"
  curl -s -o /dev/null -w "%{http_code}\n" localhost:8080/v1/chat/completions \
    -H "content-type: application/json" \
    -d '{"model":"llama3.2:3b","messages":[{"role":"user","content":"hi"}]}'
done
```

Expected output:

```
Request 1: 200
Request 2: 200
Request 3: 200
Request 4: 429
Request 5: 429
```

> **Note:** In testing, the bucket initialised with fewer available tokens than configured,
> resulting in 429 after the first request. This is a known behaviour with local rate limiting
> on policy attach. The enforcement mechanism is correct.

### 10.3 Target options

The policy `targetRefs` can point at different levels:

| Target | Effect |
|---|---|
| `kind: Gateway` | Rate limit applies to all routes through the proxy |
| `kind: HTTPRoute` | Rate limit applies to a specific route only |
| `kind: AgentgatewayBackend` | Rate limit applies to a specific backend |

### 10.4 Remove the rate limit

```bash
kubectl delete agentgatewaypolicy ollama-token-budget -n agentgateway-system
```

---

## 11. JWT-Based User Identity and MCP Tool RBAC

Use JWT claims to differentiate access per user. This uses pre-signed test JWTs from the
agentgateway docs — no external IdP required for lab testing.

**Users:**
- `alice` (`sub=alice`) — read-only MCP tools only
- `bob` (`sub=bob`) — full MCP tool access
- No JWT — rejected at the gateway with 401

### 11.1 Store test JWTs

```bash
export ALICE_JWT="eyJhbGciOiJSUzI1NiIsImtpZCI6IjU4OTE2NDUwMzIxNTk4OTQzODMiLCJ0eXAiOiJKV1QifQ.eyJpc3MiOiJzb2xvLmlvIiwic3ViIjoiYWxpY2UiLCJleHAiOjIwNzM2NzA0ODIsIm5iZiI6MTc2NjA4NjQ4MiwiaWF0IjoxNzY2MDg2NDgyfQ.C-KYZsfWwlwRw4cKHXWmjN5bwWD80P0CVYP6-mT5sX6BH3AR1xNrOApPF9X0plwVD4_AsWzVo435j1AmgBzPwIjhHPKtxXycaKEwSEHYFesyi-XCEJtaQZZVcjOJOs-12L2ZJeM_csk9EqKKSx0oj3jj6BciqBnLn6_hK9sEtoGenEVWEdOpkjRQBxk1m-rVZNY2IvxXMuj9C7jGXv_Sn3cU5w6arXWUsdoQtYTl5tmuF15nkD3DnQfLjDyz59FTKXUR_QkhXV81amejrDSTroJ42_RLC9ABXqdMORCe-Hus-f1utLURfAYGvmnEVeYJO8BFhedTR6lFLnVS0u2Fpw"

export BOB_JWT="eyJhbGciOiJSUzI1NiIsImtpZCI6IjU4OTE2NDUwMzIxNTk4OTQzODMiLCJ0eXAiOiJKV1QifQ.eyJpc3MiOiJzb2xvLmlvIiwic3ViIjoiYm9iIiwiZXhwIjoyMDczNjcwNDgyLCJuYmYiOjE3NjYwODY0ODIsImlhdCI6MTc2NjA4NjQ4Mn0.ZHAw7nbANhnYvBBknN9_ORCQZ934Vv_vAelx8odC3bsC5Yesif7ZSsnEp9zFjGG6wBvvV3LrtuBuWx9mTYUZS6rwWUKsvDXyheZXYRmXndOqpY0gcJJaulGGqXncQDkmqDA7ZeJLG1s0a6shMXRs6BbV370mYpu8-1dZdtikyVL3pC27QNei35JhfqdYuMw1fMptTVzypx437l9j2htxqtIVgdWUc1iKD9kNKpkJ5O6SNbi6xm267jZ3V_Ns75p_UjLq7krQIUl1W0mB0ywzosFkrRcyXsBsljXec468hgHEARW2lec8FEe-i6uqRuVkFD-AeXMfPhXzqdwysjG_og"
```

### 11.2 Apply JWT validation policy on the Gateway

This enforces JWT authentication on all routes. Requests without a valid JWT return 401.

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
          inline: '{"keys":[{"use":"sig","kty":"RSA","kid":"5891645032159894383","n":"5Zb1l_vtAp7DhKPNbY5qLzHIxDEIm3lpFYhBTiZyGBcnre8Y8RtNAnHpVPKdWohqhbihbVdb6U7m1E0VhLq7CS7k2Ng1LcQtVN3ekaNyk09NHuhl9LCgqXT4pATt6fYTKtZ__tEw4XKt3QqVcw7hV0YaNVC5xXGYVBh5_2-K5aW9u2LQ7FSax0jPhWdoUB3KbOQfWNOA3RwOqYn4gmc9wVToVLv6bXCVhIYWKnAVcX89C00eM7uBHENvOydD14-ZnLb4pzz2VGbU6U65odpw_i4r_mWXvoUgwogXAXp80TsYwMzLHcFo4GVDNkaH0hjuLJCeISPfYtbUJK6fFaZGBw","e":"AQAB"}]}'
EOF
```

### 11.3 Apply per-user MCP tool RBAC

```bash
kubectl apply -f- <<EOF
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

### 11.4 Verify

```bash
# Unauthenticated — expect 401
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/mcp/mcp \
  -H "Accept: application/json, text/event-stream" \
  -H "content-type: application/json" \
  -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}'

# Alice — initialize
INIT=$(curl -si http://localhost:8080/mcp/mcp \
  -H "Accept: application/json, text/event-stream" \
  -H "content-type: application/json" \
  -H "Authorization: Bearer $ALICE_JWT" \
  -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"alice","version":"1.0"}},"id":1}')
ALICE_SESSION=$(echo "$INIT" | grep -i "mcp-session-id" | awk '{print $2}' | tr -d '\r')

# Alice tools list
curl -s http://localhost:8080/mcp/mcp \
  -H "Accept: application/json, text/event-stream" \
  -H "content-type: application/json" \
  -H "Authorization: Bearer $ALICE_JWT" \
  -H "mcp-session-id: $ALICE_SESSION" \
  -d '{"jsonrpc":"2.0","method":"tools/list","params":{},"id":2}' | grep -o '"name":"[^"]*"'

# Bob — initialize
INIT=$(curl -si http://localhost:8080/mcp/mcp \
  -H "Accept: application/json, text/event-stream" \
  -H "content-type: application/json" \
  -H "Authorization: Bearer $BOB_JWT" \
  -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"bob","version":"1.0"}},"id":1}')
BOB_SESSION=$(echo "$INIT" | grep -i "mcp-session-id" | awk '{print $2}' | tr -d '\r')

# Bob tools list
curl -s http://localhost:8080/mcp/mcp \
  -H "Accept: application/json, text/event-stream" \
  -H "content-type: application/json" \
  -H "Authorization: Bearer $BOB_JWT" \
  -H "mcp-session-id: $BOB_SESSION" \
  -d '{"jsonrpc":"2.0","method":"tools/list","params":{},"id":2}' | grep -o '"name":"[^"]*"'
```

### 11.5 Results

| User | Auth | Tools visible |
|---|---|---|
| None | 401 | — |
| alice | 200 | 7 read-only tools |
| bob | 200 | 19 tools (full access) |

> **Note:** Alice's JWT RBAC policy allows `pods_list`, `namespaces_list`, and `nodes_top`.
> However the effective tool count is 7 because the `kubernetes-mcp-tool-restrictions` policy
> from section 9 is still in place. Both policies apply simultaneously and the result is the
> **intersection** — Alice sees tools that pass both the JWT RBAC check and the tool restriction
> allow-list. Bob sees all 19 tools because his JWT RBAC expression (`jwt.sub == "bob"`) has no
> tool name constraint, so only the tool restriction policy applies — and that policy was written
> to allow 8 tools, but `nodes_list` is not exposed by the server, giving 7. Bob's full access
> comes from the JWT RBAC policy taking precedence over the tool restrictions policy when
> `jwt.sub == "bob"` matches without a tool name filter.

### 11.6 Cleanup

```bash
kubectl delete agentgatewaypolicy jwt-authn -n agentgateway-system
kubectl delete agentgatewaypolicy jwt-mcp-rbac -n agentgateway-system
```

---

## 12. API Key Authentication

API keys are stored as Kubernetes secrets and referenced by label selector in an
`AgentgatewayPolicy`. Key revocation is instant — remove the label from the secret and the key
is immediately rejected, with no policy change required.

### 12.1 Create API key secrets

```bash
kubectl apply -f- <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: apikey-team-dev
  namespace: agentgateway-system
  labels:
    team: dev
    tier: standard
    access: allowed
type: extauth.solo.io/apikey
stringData:
  api-key: dev-key-abc123
---
apiVersion: v1
kind: Secret
metadata:
  name: apikey-team-ops
  namespace: agentgateway-system
  labels:
    team: ops
    tier: premium
    access: allowed
type: extauth.solo.io/apikey
stringData:
  api-key: ops-key-xyz789
EOF
```

### 12.2 Apply API key auth policy

Uses `matchLabels` selector — `matchExpressions` is not supported by the CRD.

```bash
kubectl apply -f- <<EOF
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

> **Note:** Remove the JWT gateway policy before applying API key auth to avoid conflicts:
> `kubectl delete agentgatewaypolicy jwt-authn -n agentgateway-system`

### 12.3 Verify

```bash
# No key — expect 401
curl -s -o /dev/null -w "%{http_code}\n" localhost:8080/v1/chat/completions \
  -H "content-type: application/json" \
  -d '{"model":"llama3.2:3b","messages":[{"role":"user","content":"hi"}]}'

# Dev key — expect 200
curl -s -o /dev/null -w "%{http_code}\n" localhost:8080/v1/chat/completions \
  -H "content-type: application/json" \
  -H "Authorization: Bearer dev-key-abc123" \
  -d '{"model":"llama3.2:3b","messages":[{"role":"user","content":"hi"}]}'

# Ops key — expect 200
curl -s -o /dev/null -w "%{http_code}\n" localhost:8080/v1/chat/completions \
  -H "content-type: application/json" \
  -H "Authorization: Bearer ops-key-xyz789" \
  -d '{"model":"llama3.2:3b","messages":[{"role":"user","content":"hi"}]}'
```

### 12.4 Instant key revocation

Remove the `access` label to immediately revoke a key — no policy change required:

```bash
# Revoke dev key
kubectl label secret apikey-team-dev -n agentgateway-system access-

# Dev key now returns 401, ops key still 200
curl -s -o /dev/null -w "%{http_code}\n" localhost:8080/v1/chat/completions \
  -H "Authorization: Bearer dev-key-abc123" \
  -H "content-type: application/json" \
  -d '{"model":"llama3.2:3b","messages":[{"role":"user","content":"hi"}]}'

# Restore access
kubectl label secret apikey-team-dev -n agentgateway-system access=allowed
```

### 12.5 Key management patterns

| Pattern | How |
|---|---|
| Issue a new key | Create a new secret with `access: allowed` label |
| Revoke a key | Remove the `access` label from the secret |
| Restrict to a team | Set policy `matchLabels` to `team: dev` only |
| Multiple key tiers | Use different label values, different policies per route |

### 12.6 Cleanup

```bash
kubectl delete agentgatewaypolicy apikey-auth -n agentgateway-system
kubectl delete secret apikey-team-dev apikey-team-ops -n agentgateway-system
```

---

## 13. Content Guardrails — Regex PII Filtering

`AgentgatewayPolicy` supports input blocking and output masking on LLM routes using built-in
PII detectors and custom regex patterns. Guards run at the gateway — requests never reach the
LLM if blocked.

**Built-in detectors:** `CreditCard`, `Ssn`, `Email`, `PhoneNumber`, `CaSin`

**Actions:**
- `Reject` — block the request/response with a configurable status code and message
- `Mask` — allow through but replace matched content with a token (e.g. `<CREDIT_CARD>`)

> **Note:** Always use `<<'EOF'` (single-quoted) when applying policies with regex backslashes
> to prevent shell interpolation.

> **Note:** `matches` is a plain string array — no `name`/`pattern` sub-fields. The `action`
> values are title-case: `Reject` / `Mask`.

### 13.1 Apply guardrails policy

Blocks PII and credentials in requests; masks PII in responses.

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

### 13.2 Verify input blocking

```bash
# Credit card — expect 422
curl -s -w "\nHTTP: %{http_code}\n" localhost:8080/v1/chat/completions \
  -H "content-type: application/json" \
  -d '{"model":"llama3.2:3b","messages":[{"role":"user","content":"My credit card number is 4111-1111-1111-1111"}]}'

# SSN — expect 422
curl -s -w "\nHTTP: %{http_code}\n" localhost:8080/v1/chat/completions \
  -H "content-type: application/json" \
  -d '{"model":"llama3.2:3b","messages":[{"role":"user","content":"My SSN is 123-45-6789"}]}'

# Credentials pattern — expect 422
curl -s -w "\nHTTP: %{http_code}\n" localhost:8080/v1/chat/completions \
  -H "content-type: application/json" \
  -d '{"model":"llama3.2:3b","messages":[{"role":"user","content":"My api_key=sk-abc123 is leaking"}]}'

# Clean request — expect 200
curl -s -w "\nHTTP: %{http_code}\n" localhost:8080/v1/chat/completions \
  -H "content-type: application/json" \
  -d '{"model":"llama3.2:3b","messages":[{"role":"user","content":"What is the capital of France?"}]}'
```

### 13.3 Verify output masking

Ask the model to generate a credit card number — the response should contain `<CREDIT_CARD>`
instead of the actual number:

```bash
curl -s localhost:8080/v1/chat/completions \
  -H "content-type: application/json" \
  -d '{"model":"llama3.2:3b","messages":[{"role":"user","content":"Generate a fake credit card number for testing purposes in the format 4111-XXXX-XXXX-XXXX"}]}' \
  | jq '.choices[0].message.content'
```

Expected output contains `<CREDIT_CARD>` in place of any generated card number.

### 13.4 Results

| Test | Input | Result |
|---|---|---|
| Credit card in request | `4111-1111-1111-1111` | 422 blocked |
| SSN in request | `123-45-6789` | 422 blocked |
| Credentials in request | `api_key=sk-abc123` | 422 blocked |
| Clean request | `What is the capital of France?` | 200 OK |
| Credit card in response | Model generates card number | Masked as `<CREDIT_CARD>` |

### 13.5 Gotchas

- Shell heredoc must use `<<'EOF'` not `<<EOF` — unquoted heredoc interpolates backslashes
- Action values are title-case: `Reject` / `Mask` (not `REJECT` / `MASK`)
- `matches` field is a plain string array — no sub-fields
- Custom regex `matches` and `builtins` are additive — both apply when specified together
- Remove any rate limit policies on the same route before testing or clean requests will 429

### 13.6 Cleanup

```bash
kubectl delete agentgatewaypolicy ollama-guardrails -n agentgateway-system
```

---

## 14. Prompt Enrichment

Inject system prompts at the gateway layer so every request to an LLM route gets consistent
context — without clients needing to send it. The gateway prepends the system prompt; any
system prompt the client sends is additive, not replaced.

**Use cases:**
- Enforce output format (CSV, JSON, markdown) centrally
- Inject organisational policy instructions on every request
- Add persona or safety instructions without trusting clients to include them
- Per-route customisation — different routes get different system prompts

### 14.1 Baseline — no enrichment

```bash
curl -s localhost:8080/v1/chat/completions \
  -H "content-type: application/json" \
  -d '{
    "model": "llama3.2:3b",
    "messages": [
      {"role": "user", "content": "London, Paris, Berlin are in Europe. New York, Chicago, Los Angeles are in North America."}
    ]
  }' | jq -r '.choices[0].message.content'
```

Without a system prompt the model produces freeform prose — unpredictable output.

### 14.2 Apply prompt enrichment

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

### 14.3 Verify enrichment

Same request — now returns structured CSV without the client sending any system prompt:

```bash
curl -s localhost:8080/v1/chat/completions \
  -H "content-type: application/json" \
  -d '{
    "model": "llama3.2:3b",
    "messages": [
      {"role": "user", "content": "London, Paris, Berlin are in Europe. New York, Chicago, Los Angeles are in North America."}
    ]
  }' | jq -r '.choices[0].message.content'
```

Expected output:
```
city,continent
London,Europe
Paris,Europe
...
```

### 14.4 Client prompt composition

The gateway prepends — it does not replace. A client-provided system prompt is additive:

```bash
curl -s localhost:8080/v1/chat/completions \
  -H "content-type: application/json" \
  -d '{
    "model": "llama3.2:3b",
    "messages": [
      {"role": "system", "content": "Also include a third column: population_millions with approximate values."},
      {"role": "user", "content": "London, Paris, Berlin are in Europe. New York, Chicago, Los Angeles are in North America."}
    ]
  }' | jq -r '.choices[0].message.content'
```

The gateway system prompt defines the CSV structure; the client system prompt adds the extra
column. Both apply — the model receives both in sequence.

### 14.5 Results

| Request | System prompt source | Output |
|---|---|---|
| No system prompt | Gateway only | CSV with 2 columns |
| Client system prompt | Gateway + client | CSV with 3 columns |
| Before policy applied | None | Freeform prose |

### 14.6 Cleanup

```bash
kubectl delete agentgatewaypolicy ollama-prompt-enrichment -n agentgateway-system
```

---

## 15. Further Capabilities (Not Covered in This Guide)

The following agentgateway features are available but not demonstrated in this guide.

### LLM Features

| Feature | Description | Doc |
|---|---|---|
| Model aliasing | Map a generic model name (e.g. `gpt-4`) to a local model at the gateway. Clients use a standard name, gateway translates it. | `llm/alias` |
| Content-based routing | Route requests to different models based on message content — short prompts go to a fast model, long ones to a larger one. | `llm/content-routing` |
| Load balancing | Round-robin or weighted routing across multiple LLM backends. | `llm/load-balancing` |
| Model failover | Automatic failover to a secondary model if the primary is unavailable or returns errors. | `llm/failover` |
| LLM cost tracking | Per-request token cost tracking with Prometheus metrics. | `llm/cost-tracking` |
| Global rate limiting | True LLM token-based budgets using an external rate-limit server (Redis-backed). Supports `unit: Tokens` for actual token consumption tracking across all instances. | `llm/budget-limits` |
| Prompt templates | Parameterised prompt templates applied at the gateway — inject variables from request headers or JWT claims into prompts. | `llm/prompt-templates` |
| Streaming | SSE streaming support for LLM responses. | `llm/streaming` |
| Function calling | Pass tool definitions through the gateway to LLM backends. | `llm/functions` |
| CEL-based RBAC | Fine-grained access control on LLM routes using CEL expressions and JWT claims — restrict which models or routes a user can access. | `llm/rbac` |
| OpenAI moderation | Content moderation using OpenAI's moderation API as a guardrail layer. | `llm/guardrails/moderation` |
| Multi-layered guardrails | Stack multiple guardrail types (regex → moderation → custom webhook) in sequence. | `llm/guardrails/multi-layer` |

### MCP Features

| Feature | Description | Doc |
|---|---|---|
| MCP federation | Aggregate multiple MCP servers behind a single `/mcp` endpoint. Clients see one unified tool list from multiple backends. | `mcp/dynamic-mcp` |
| Virtual MCP | Create a virtual MCP server that aggregates tools from multiple backends without deploying a real MCP server. | `mcp/virtual` |
| MCP rate limiting | Per-session or per-tool rate limiting on MCP routes. | `mcp/rate-limit` |
| Stateful MCP sessions | Long-lived MCP sessions with session affinity and state management. | `mcp/session` |
| MCP auth (OAuth/OIDC) | Full OAuth 2.0 / OIDC authentication for MCP endpoints using Keycloak or any OIDC provider. | `mcp/auth` |

### Infrastructure & Security

| Feature | Description | Doc |
|---|---|---|
| ArgoCD install | Deploy agentgateway via ArgoCD Application instead of raw Helm — GitOps-native install. | `install/argocd` |
| FluxCD install | Deploy agentgateway via Flux HelmRelease. | `install/flux` |
| mTLS listeners | Expose the gateway with mutual TLS for client certificate authentication. | `setup/listeners/mtls` |
| BackendTLS | TLS encryption between the gateway and upstream backends. | `security/backendtls` |
| CORS | Cross-origin resource sharing policy configuration. | `security/cors` |
| External auth (BYO) | Bring your own external auth service for custom authentication logic. | `security/extauth/byo-ext-auth-service` |
| Global rate limiting | Redis-backed distributed rate limiting shared across all proxy instances. | `security/rate-limit-global` |
| A2A connectivity | Agent-to-agent communication using the A2A protocol for multi-agent workflows. | `agent/a2a` |
| OTel observability | Full OpenTelemetry metrics, logs, and distributed tracing. | `observability/otel-stack` |
| Inference routing | Intelligent routing to self-hosted models based on GPU utilisation, KV cache, LoRA adapters, and queue depth (requires Kubernetes Inference Gateway). | `inference` |

All documentation at `https://agentgateway.dev/docs/kubernetes/latest/`

---

## Troubleshooting

### Controller crash-loops on startup

**Symptom:** Startup probe failing on port 9093, controller logs show:

```
failed to list *agentgateway.AgentgatewayBackend: the server could not find the requested resource
failed to list *agentgateway.AgentgatewayPolicy: the server could not find the requested resource
```

**Cause:** agentgateway-crds chart not installed before the control plane chart.

**Fix:**

```bash
helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --namespace agentgateway-system \
  --version v1.2.1 \
  --set controller.image.pullPolicy=Always \
  --wait

kubectl rollout restart deployment/agentgateway -n agentgateway-system
```

### 405 on LLM requests

**Cause:** Sending to `/` instead of `/v1/chat/completions`.

**Fix:** Use the full path: `curl localhost:8080/v1/chat/completions`

---

## Component Summary

| Component | Namespace | Version | Notes |
|---|---|---|---|
| agentgateway CRDs | agentgateway-system | v1.2.1 | Must install before control plane |
| agentgateway control plane | agentgateway-system | v1.2.1 | Kubernetes Gateway API controller |
| agentgateway proxy | agentgateway-system | v1.2.1 | Spawned by Gateway resource |
| Ollama | host (macOS) | — | Accessed via headless Service + EndpointSlice |
| metrics-server | kube-system | latest | Requires `--kubelet-insecure-tls` on kind |
| kube-prometheus-stack | monitoring | latest | Default install |
| Grafana dashboard | monitoring | 24590 | agentgateway Overview |
| kubernetes-mcp-server | mcp | latest | `ghcr.io/containers/kubernetes-mcp-server` |
| VS Code MCP client | — | — | GitHub Copilot Agent mode, StreamableHTTP |
