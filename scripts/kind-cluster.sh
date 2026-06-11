#!/bin/zsh
# kind-cluster.sh — suspend and resume kind-devops-lab
# Usage:
#   ./kind-cluster.sh stop    — kill port-forwards, stop Docker containers
#   ./kind-cluster.sh start   — start containers, wait for cluster, restore port-forwards
#   ./kind-cluster.sh status  — show cluster and pod status

CLUSTER_NAME="kind"
CLUSTER_CONTEXT="kind-kind"

# ── Colours ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo "${GREEN}[INFO]${NC} $1"; }
warn()    { echo "${YELLOW}[WARN]${NC} $1"; }
error()   { echo "${RED}[ERROR]${NC} $1"; }

# ── Stop ───────────────────────────────────────────────────────────────────
stop_cluster() {
  info "Stopping kind cluster: $CLUSTER_NAME"

  info "Killing port-forwards..."
  pkill -f "kubectl port-forward" 2>/dev/null && info "Port-forwards killed" || warn "No port-forwards running"

  info "Stopping kind Docker containers..."
  docker ps --filter "label=io.x-k8s.kind.cluster=$CLUSTER_NAME" --format "{{.Names}}" | \
    xargs -r docker stop
  info "Cluster stopped. Docker containers are paused but data is preserved."
}

# ── Start ──────────────────────────────────────────────────────────────────
start_cluster() {
  info "Starting kind cluster: $CLUSTER_NAME"

  # Check Docker is running
  if ! docker info &>/dev/null; then
    error "Docker is not running. Start Docker Desktop first."
    exit 1
  fi

  # Start kind containers
  info "Starting kind Docker containers..."
  docker ps -a --filter "label=io.x-k8s.kind.cluster=$CLUSTER_NAME" --format "{{.Names}}" | \
    xargs -r docker start

  # Wait for API server
  info "Waiting for API server to be ready..."
  local retries=30
  until kubectl --context "$CLUSTER_CONTEXT" get nodes &>/dev/null 2>&1; do
    retries=$((retries - 1))
    if [[ $retries -eq 0 ]]; then
      error "API server did not become ready in time."
      exit 1
    fi
    echo -n "."
    sleep 3
  done
  echo ""
  info "API server is ready."

  # Wait for core pods
  info "Waiting for core pods to be ready..."
  kubectl --context "$CLUSTER_CONTEXT" wait --for=condition=Ready pods \
    --all -n kube-system --timeout=120s 2>/dev/null || warn "Some kube-system pods may still be starting"

  info "Cluster is up. Starting port-forwards..."
  start_port_forwards

  info "Done. Run './kind-cluster.sh status' to verify."
}

# ── Port Forwards ──────────────────────────────────────────────────────────
start_port_forwards() {
  # agentgateway proxy
  if kubectl --context "$CLUSTER_CONTEXT" get deployment agentgateway-proxy \
      -n agentgateway-system &>/dev/null; then
    kubectl --context "$CLUSTER_CONTEXT" port-forward \
      deployment/agentgateway-proxy -n agentgateway-system 8080:80 &>/dev/null &
    info "  agentgateway proxy → localhost:8080"
  else
    warn "  agentgateway-proxy not found, skipping"
  fi

  # Prometheus
  if kubectl --context "$CLUSTER_CONTEXT" get svc kube-prometheus-stack-prometheus \
      -n monitoring &>/dev/null; then
    kubectl --context "$CLUSTER_CONTEXT" port-forward \
      -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &>/dev/null &
    info "  Prometheus → localhost:9090"
  else
    warn "  Prometheus not found, skipping"
  fi

  # Grafana
  local grafana_pod
  grafana_pod=$(kubectl --context "$CLUSTER_CONTEXT" get pod -n monitoring \
    -l "app.kubernetes.io/name=grafana,app.kubernetes.io/instance=kube-prometheus-stack" \
    -oname 2>/dev/null | head -1)
  if [[ -n "$grafana_pod" ]]; then
    kubectl --context "$CLUSTER_CONTEXT" port-forward \
      -n monitoring "$grafana_pod" 3000:3000 &>/dev/null &
    info "  Grafana → localhost:3000"
  else
    warn "  Grafana pod not found, skipping"
  fi

  # OpenCost UI
  if kubectl --context "$CLUSTER_CONTEXT" get svc opencost-ui \
      -n opencost &>/dev/null; then
    kubectl --context "$CLUSTER_CONTEXT" port-forward \
      -n opencost svc/opencost-ui 9003:9090 &>/dev/null &
    info "  OpenCost UI → localhost:9003"
  else
    warn "  OpenCost UI not found, skipping"
  fi
}

# ── Status ─────────────────────────────────────────────────────────────────
status_cluster() {
  info "Cluster: $CLUSTER_NAME"
  echo ""

  echo "── Nodes ──────────────────────────────────────────"
  kubectl --context "$CLUSTER_CONTEXT" get nodes 2>/dev/null || error "Cluster not reachable"
  echo ""

  echo "── Pods (non-Running) ─────────────────────────────"
  kubectl --context "$CLUSTER_CONTEXT" get pods -A \
    --field-selector 'status.phase!=Running' 2>/dev/null | grep -v "Completed" || echo "  All pods Running"
  echo ""

  echo "── Port Forwards ──────────────────────────────────"
  pgrep -a kubectl 2>/dev/null | grep "port-forward" | awk '{print "  " $0}' || echo "  None running"
  echo ""

  echo "── Namespaces ─────────────────────────────────────"
  kubectl --context "$CLUSTER_CONTEXT" get ns 2>/dev/null
}

# ── Entry point ────────────────────────────────────────────────────────────
case "$1" in
  stop)    stop_cluster ;;
  start)   start_cluster ;;
  status)  status_cluster ;;
  *)
    echo "Usage: $0 {start|stop|status}"
    echo ""
    echo "  start   — start containers, wait for cluster, restore port-forwards"
    echo "  stop    — kill port-forwards, stop Docker containers (data preserved)"
    echo "  status  — show cluster, pod, and port-forward status"
    exit 1
    ;;
esac
