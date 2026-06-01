# AI Gateways on Kubernetes: agentgateway vs Bifrost — A Platform Engineer's Hands-On Comparison

*A deep dive into two open-source AI gateway projects, tested on kind with Ollama, Prometheus, and VS Code MCP integration.*

---

## Background

AI gateways are becoming a standard layer in platform engineering stacks. As LLM usage grows across teams, the need to centralise authentication, rate limiting, observability, content governance, and MCP tool access becomes unavoidable. Two projects have stood out in my lab work: **Bifrost** (by Maxim) and **agentgateway** (a Linux Foundation project, originally from Solo.io).

I spent time deploying both on local kind clusters, integrating them with Ollama for local inference, wiring up Prometheus/Grafana observability, and connecting VS Code GitHub Copilot via MCP. This post documents what I found — architecture differences, feature parity, operational characteristics, and where each one makes sense.

---

## What Both Projects Do

At their core, both are Kubernetes-deployable AI gateways that:

- Provide a unified OpenAI-compatible API endpoint over multiple LLM providers
- Enforce authentication and access control on LLM traffic
- Support local model inference via Ollama
- Expose Prometheus metrics
- Support MCP (Model Context Protocol) for tool connectivity

The similarities end there.

---

## Bifrost

Bifrost (`maximhq/bifrost`) is a **provider-aggregation gateway with a built-in web UI**. Its primary value proposition is unifying multiple LLM providers behind a single endpoint with virtual key management.

### Architecture

Bifrost deploys as a **StatefulSet** (single pod by default, PostgreSQL-backed for HA). The chart requires an explicit image tag and an encryption key secret — sensible defaults for a production-minded tool. Configuration is primarily done through the **web UI**, not YAML — you add providers, create virtual keys, and set routing rules through a browser.

```bash
helm repo add bifrost https://maximhq.github.io/bifrost/helm-charts
kubectl create secret generic bifrost-encryption-key \
  --namespace ai-gateway \
  --from-literal=encryption-key="$(openssl rand -base64 32)"
helm install bifrost bifrost/bifrost \
  --namespace ai-gateway \
  --set image.tag=v1.4.24 \
  --set bifrost.encryptionKeySecret.name=bifrost-encryption-key \
  --set bifrost.encryptionKeySecret.key=encryption-key
```

### Key Features

**Virtual keys** are Bifrost's flagship feature. Each key can be scoped to specific models, given a token budget, and assigned to a team or tool. The `x-bf-vk` header carries the key — completely decoupled from the actual provider API key. This is the right pattern for multi-tenant LLM access.

**Provider routing** supports OpenAI, Anthropic, Bedrock, Vertex, Azure, Ollama, and others. You configure fallback chains through the UI — if OpenAI fails, route to Anthropic, then to local Ollama. This works well and the failover is automatic.

**Semantic caching** via Qdrant is a genuinely differentiated feature — cache LLM responses at the vector level so semantically similar queries hit the cache. In my testing this required a separate Qdrant deployment but worked as advertised.

**MCP gateway** — listed as a capability, with tool calls proxied through Bifrost's endpoint. In practice this is less mature than agentgateway's MCP implementation.

### Observability

Bifrost exposes `/metrics` with standard Prometheus metrics. A ServiceMonitor wires it into kube-prometheus-stack cleanly. The built-in dashboard (accessible on port 8080) shows request volume, provider breakdowns, and virtual key usage.

> 📸 **[SCREENSHOT 1 — bifrost-dashboard.png]**
> *Bifrost built-in analytics dashboard showing request volume, token usage, cost tracking, model usage breakdown, and latency percentiles across providers. Note the Cache Hit Rate panel (top right) and the multi-model breakdown in the Model Usage chart.*

The request log view provides per-request visibility — provider, model, latency, and token counts with input/output breakdown:

> 📸 **[SCREENSHOT 2 — bifrost-logs.png]**
> *Bifrost live request log showing per-request provider routing (Anthropic, OpenAI), model selection, latency, and token counts. The red row indicates a failed/slow request (216s — a local Ollama model under load). Total cost tracked at $0.70 across 95 requests.*

### Limitations I Hit

- Configuration is **UI-first, not YAML-first** — difficult to GitOps. No CRDs, no Helm values for policy management.
- The StatefulSet pattern means persistence is required even in dev — the SQLite default needs a PVC.
- MCP support is functional but not Kubernetes-native — no CRDs, no Gateway API integration.
- Policy enforcement (rate limits, content filtering) is less granular — no CEL expressions, no per-route policy stacking.

---

## agentgateway

agentgateway (`agentgateway/agentgateway`, Linux Foundation) is a **Kubernetes-native AI and MCP proxy built on the Gateway API**. It is architecturally closer to Envoy/Istio than to a traditional API gateway — the control plane pushes xDS configuration to proxy pods dynamically.

### Architecture

agentgateway deploys as two components: a **controller** (manages configuration via CRDs and xDS) and one or more **proxy pods** (spawned dynamically from `Gateway` resources). The proxy is a Rust binary; the controller is Go. Configuration is entirely through Kubernetes resources — no web UI required for policy management.

```bash
# Install CRDs first — controller crash-loops without them
helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --namespace agentgateway-system --create-namespace --version v1.2.1

# Control plane
helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --namespace agentgateway-system --version v1.2.1 \
  --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true

# Proxy — spawned by creating a Gateway resource
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

> **Gotcha:** Installing the control plane before the CRDs causes a crash-loop. The controller waits indefinitely for `agentgatewaybackends.agentgateway.dev` and `agentgatewaypolicies.agentgateway.dev` to exist. Install CRDs first.

### Key Features

**LLM routing via AgentgatewayBackend** — Ollama, OpenAI, Anthropic, Gemini, Azure, Bedrock, Vertex, vLLM all supported. For Ollama (running outside the cluster on macOS), you need a headless Service and EndpointSlice to give it a stable in-cluster DNS name:

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: ollama
  namespace: agentgateway-system
spec:
  ai:
    provider:
      openai:           # Ollama exposes OpenAI-compatible API
        model: llama3.2:3b
      host: ollama.agentgateway-system.svc.cluster.local
      port: 11434
```

**AgentgatewayPolicy** is the core governance primitive — a single CRD that handles JWT authentication, API key auth, rate limiting, content guardrails, prompt enrichment, MCP tool access, and CEL-based RBAC. Policies stack — multiple policies on the same target apply in sequence.

**MCP proxy** is first-class. The `AgentgatewayBackend` supports an `mcp` spec, with `HTTPRoute` routing MCP traffic to backends. Both StreamableHTTP and SSE transports are supported. VS Code GitHub Copilot connects via a single `settings.json` entry:

```json
{
  "mcp": {
    "servers": {
      "kubernetes-agentgateway": {
        "type": "http",
        "url": "http://localhost:8080/mcp/mcp"
      }
    }
  }
}
```

> 📸 **[SCREENSHOT 3 — VS_Code_Copilot_with_pod_list.png]**
> *VS Code GitHub Copilot Agent mode — the `kubernetes-agentgateway` MCP server (proxied through agentgateway) returning a full pod list across all namespaces. The tool call `Pods: List` shows the MCP server name in the attribution. 19 pods, all Running.*

**Content guardrails** with built-in PII detectors (`CreditCard`, `Ssn`, `Email`, `PhoneNumber`) and custom regex. Input blocking returns 422; output masking replaces matched content with tokens like `<CREDIT_CARD>`. Applied at the route level with no external dependency:

```yaml
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
        response:
          message: "Request blocked: PII detected"
          statusCode: 422
      response:
      - regex:
          action: Mask
          builtins:
          - CreditCard
```

> 📸 **[SCREENSHOT 4 — Screenshot_2026-05-31_at_17_30_55.png]**
> *Terminal — agentgateway content guardrails in action: credit card number (4111-1111-1111-1111), SSN (123-45-6789), and credentials pattern (api_key=sk-abc123) all blocked with HTTP 422. Clean request (capital of France) passes with HTTP 200. No changes to client code.*

**JWT-based RBAC with CEL** — validate JWTs inline (no external IdP required for testing) and use CEL expressions to control access per user. Different tool sets per JWT claim, different model access per team:

```yaml
backend:
  mcp:
    authorization:
      action: Allow
      policy:
        matchExpressions:
        - 'jwt.sub == "bob"'
        - 'jwt.sub == "alice" && mcp.tool.name == "pods_list"'
```

> 📸 **[SCREENSHOT 5 — Screenshot_2026-05-31_at_17_33_47.png]**
> *Terminal — JWT-based MCP tool RBAC: Alice (sub=alice, read-only) sees 3 tools (namespaces_list, nodes_top, pods_list). Bob (sub=bob, full access) sees 19 tools including pods_exec, pods_delete, resources_create_or_update, and resources_delete. Same gateway, same MCP server, different JWT claims.*

**Prompt enrichment** — inject system prompts at the gateway without clients needing to send them. The gateway prepends; client-provided system prompts are additive:

```yaml
backend:
  ai:
    prompt:
      prepend:
      - role: system
        content: "Always respond in structured CSV format."
```

> 📸 **[SCREENSHOT 6a — Screenshot_2026-05-31_at_17_36_59.png]**
> *Terminal — WITHOUT prompt enrichment: same user message produces freeform prose ("That's partially correct! While it's true..."). The model has no instructions on output format.*

> 📸 **[SCREENSHOT 6b — Screenshot_2026-05-31_at_17_37_33.png]**
> *Terminal — WITH prompt enrichment: identical user message now returns structured CSV (city,continent). The gateway injected the system prompt transparently — the client sent no system prompt. This is the same request, different gateway policy.*

### Observability

The proxy pod exposes Prometheus metrics on port 15020 (the `metrics` named port on the proxy Service). The ServiceMonitor label must match the kube-prometheus-stack release label. Grafana dashboard ID `24590` covers requests, latency, token usage, MCP tool calls, and Tokio runtime metrics. Token usage (input/output) per route is tracked natively — no separate cost-tracking integration required.

> 📸 **[SCREENSHOT 7 — Prometheus_targets.png]**
> *Prometheus target health — `serviceMonitor/monitoring/agentgateway-proxy/0` showing 1/1 UP, scraping http://10.244.0.7:15020/metrics every 15s with 7ms scrape duration. Labels show namespace, pod, and service attribution.*

> 📸 **[SCREENSHOT 8 — Grafana_dashboard.png]**
> *Grafana agentgateway Overview dashboard (ID 24590) — showing total requests, P95 latency (20.5ms), MCP tool calls, request rate by route (kubernetes-mcp and ollama), status code breakdown (200, 422, 429), and response throughput. The 422 spike corresponds to the guardrails test; 429 corresponds to the rate limiting test.*

### Limitations I Hit

- **No web UI for live config inspection** (Kubernetes mode). The standalone binary has an admin UI at `localhost:15000/ui` but this isn't exposed in the Kubernetes deployment.
- **SSE transport for MCP requires session pre-negotiation** — StreamableHTTP is simpler and works better for request/response tool calls.
- **Local rate limiting uses request counts, not token counts** — true token-based budgets require an external Redis-backed rate-limit server.
- **`matchExpressions` not supported in `secretSelector`** for API key auth — use a shared label on secrets and `matchLabels` instead.
- **Heredoc backslash handling** — regex patterns in `AgentgatewayPolicy` must use `<<'EOF'` (single-quoted) to prevent shell interpolation.

---

## Head-to-Head Comparison

| Capability | Bifrost | agentgateway |
|---|---|---|
| **Deployment model** | StatefulSet, PVC required | Deployment (controller) + dynamic proxy pods |
| **Configuration** | Web UI + Helm values | Kubernetes CRDs (GitOps-native) |
| **LLM providers** | 10+ including Ollama | 10+ including Ollama |
| **Authentication** | Virtual keys (`x-bf-vk` header) | API keys (K8s secrets), JWT, mTLS |
| **Rate limiting** | Per-virtual-key budget | Local (request-based) or global (token-based, Redis) |
| **Content filtering** | Not built-in | Built-in PII detectors + custom regex, input/output |
| **MCP support** | Basic, non-native | First-class: CRDs, HTTPRoute, StreamableHTTP/SSE |
| **Per-user tool access** | Not available | CEL-based RBAC on MCP tools via JWT claims |
| **Prompt enrichment** | Not available | Native via AgentgatewayPolicy |
| **Semantic caching** | Yes (Qdrant) | Not available |
| **Observability** | `/metrics` + built-in dashboard | `/metrics` (port 15020) + Grafana dashboard 24590 |
| **GitOps compatibility** | Limited — UI-driven config | Full — all config is Kubernetes resources |
| **Gateway API** | No | Yes (v1.5.0 standard) |
| **Kubernetes-nativeness** | Moderate | High |
| **MCP + VS Code integration** | Functional | Tested and documented |
| **Open source licence** | MIT | Apache 2.0 (Linux Foundation) |

---

## When to Use Each

**Use Bifrost when:**
- You want a **fast, UI-driven setup** with minimal YAML
- **Semantic caching** is a priority — Qdrant integration is unique
- You need **multi-provider failover** and want to configure it visually
- Your team is less Kubernetes-native and prefers a dashboard-first workflow
- You need a quick demo environment without writing CRDs

**Use agentgateway when:**
- You operate a **GitOps-first platform** — all config as Kubernetes resources
- **MCP is a first-class concern** — tool access control, multiple MCP servers, VS Code integration
- You need **content governance** — PII filtering, prompt injection, per-user RBAC
- You're running on **Gateway API** infrastructure and want consistent policy patterns
- You want **prompt enrichment** centrally managed at the gateway layer
- You're building a platform with **multiple teams/users** needing differentiated access

---

## My Setup

For reference, the full stack I tested against:

- **Cluster:** kind (`kind-devops-lab`), single node
- **Local inference:** Ollama on macOS (M3), `llama3.2:3b`, `qwen3-coder:30b`
- **Observability:** kube-prometheus-stack (default install), Grafana dashboard 24590
- **MCP server:** `ghcr.io/containers/kubernetes-mcp-server:latest` deployed in-cluster
- **MCP client:** VS Code GitHub Copilot Agent mode
- **Metrics server:** Required for `nodes_top` — needs `--kubelet-insecure-tls` on kind

---

## Final Thoughts

Both projects are solid. Bifrost wins on **ease of initial setup and semantic caching**. agentgateway wins on **Kubernetes-nativeness, MCP maturity, and policy depth**.

For platform engineering teams running GitOps workflows who need to govern AI tool access across multiple teams, agentgateway is the more complete solution today. The Gateway API foundation means policy patterns are consistent with the rest of your ingress/egress infrastructure, and the MCP integration is production-ready enough to wire directly into VS Code.

Bifrost's UI-first approach and semantic caching make it a better fit for smaller teams who want to get something running quickly without deep Kubernetes investment.

Both are worth having in your lab. The comparison sharpens your thinking about what an AI gateway actually needs to do in a real platform context.

---

*Full setup guide with all YAML, tested commands, and troubleshooting notes available on request.*

*All testing performed on a personal lab environment. No production systems or client environments were involved.*
