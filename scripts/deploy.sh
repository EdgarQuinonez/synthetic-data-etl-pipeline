#!/usr/bin/env bash
# =============================================================
# Universal Deploy Script for the Synthetic-Data ETL Pipeline
# =============================================================
# Supports: Docker Compose (local/on-prem) and Kubernetes via minikube
#
# Usage:
#   ./scripts/deploy.sh local          # Docker Compose (NiFi)
#   ./scripts/deploy.sh k8s            # Kubernetes via Helm into minikube
#   ./scripts/deploy.sh status         # Show deployment status
#   ./scripts/deploy.sh teardown       # Remove deployment (--purge to drop namespace)
#   ./scripts/deploy.sh pf-stop        # Stop kubectl port-forward only
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
HELM_CHART="$PROJECT_DIR/helm/e2e-pipeline"
RELEASE_NAME="${PIPELINE_RELEASE_NAME:-e2e-pipeline}"
NAMESPACE="${PIPELINE_NAMESPACE:-pipeline}"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
NIFI_CONF="$PROJECT_DIR/nifi/data/conf"
SQL_PROXY_SA="${SQL_PROXY_SA:-$HOME/.config/gcloud/sql-proxy-sa.json}"
SQL_PROXY_INSTANCE="${SQL_PROXY_INSTANCE:-data-etl-pipeline-506215:us-central1:synthetic-postgres}"
NIFI_WEB_PORT="8443"
NIFI_HTTP_PORT="19090"
NIFI_IMAGE="synthetic-nifi:2.11.0"
LOG_DIR="/home/glowbo/projects/dev-logs/synthetic-data-etl-pipeline/logs"
PID_DIR="$LOG_DIR/run"
PF_LOG="$LOG_DIR/nifi-pf.log"
PF_PID="$PID_DIR/nifi-pf.pid"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

mkdir -p "$PID_DIR"

log()  { echo -e "${GREEN}[DEPLOY]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1" >&2; }

is_listening() {
  ss -tln 2>/dev/null | grep -q ":$1 "
}

wait_for_port() {
  local port="$1" timeout="${2:-120}" i
  for i in $(seq 1 $((timeout / 2))); do
    is_listening "$port" && return 0
    sleep 2
  done
  return 1
}

# ----- Prerequisite checks -----
check_docker() {
  command -v docker >/dev/null 2>&1 || { err "Docker not found."; exit 1; }
  docker info >/dev/null 2>&1 || { err "Docker daemon not running."; exit 1; }
  log "Docker: OK"
}

check_kubectl() {
  command -v kubectl >/dev/null 2>&1 || { err "kubectl not found."; exit 1; }
  kubectl cluster-info >/dev/null 2>&1 || { err "Cannot connect to cluster (run 'minikube start')."; exit 1; }
  log "kubectl: OK ($(kubectl config current-context 2>/dev/null))"
}

check_helm() {
  command -v helm >/dev/null 2>&1 || { err "Helm not found (install: sudo pacman -S helm)."; exit 1; }
  log "Helm: $(helm version --short)"
}

check_minikube() {
  command -v minikube >/dev/null 2>&1 || { err "minikube not found."; exit 1; }
  log "minikube: $(minikube version --short 2>/dev/null)"
}

ensure_config() {
  if [ ! -f "$NIFI_CONF/nifi.properties" ]; then
    log "Syncing NiFi config from /opt/nifi..."
    bash "$PROJECT_DIR/nifi/sync-config.sh"
  fi
}

ensure_minikube() {
  if ! minikube status >/dev/null 2>&1; then
    log "Starting minikube..."
    minikube start --driver=docker
  fi
  log "minikube: running"
}

load_image() {
  log "Ensuring image $NIFI_IMAGE is available to minikube..."
  minikube image load "$NIFI_IMAGE" >/dev/null 2>&1 || true
}

ensure_namespace() {
  kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE" >/dev/null
  log "namespace: $NAMESPACE"
}

stop_compose_nifi() {
  if is_listening "$NIFI_WEB_PORT" || is_listening "$NIFI_HTTP_PORT"; then
    warn "docker-compose NiFi holds ports $NIFI_WEB_PORT/$NIFI_HTTP_PORT; stopping it"
    docker compose -f "$COMPOSE_FILE" stop >/dev/null 2>&1 || true
    sleep 2
  fi
}

create_secrets() {
  ensure_config
  log "Creating ConfigMap nifi-conf (non-sensitive conf)..."
  kubectl create configmap nifi-conf -n "$NAMESPACE" \
    --from-file="$NIFI_CONF/bootstrap.conf" \
    --from-file="$NIFI_CONF/logback.xml" \
    --from-file="$NIFI_CONF/state-management.xml" \
    --from-file="$NIFI_CONF/zookeeper.properties" \
    --from-file="$NIFI_CONF/authorizers.xml" \
    --from-file="$NIFI_CONF/users.xml" \
    --from-file="$NIFI_CONF/authorizations.xml" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  log "Creating Secret nifi-conf-secret (sensitive conf)..."
  kubectl create secret generic nifi-conf-secret -n "$NAMESPACE" \
    --from-file="$NIFI_CONF/nifi.properties" \
    --from-file="$NIFI_CONF/flow.json.gz" \
    --from-file="$NIFI_CONF/keystore.p12" \
    --from-file="$NIFI_CONF/truststore.p12" \
    --from-file="$NIFI_CONF/login-identity-providers.xml" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  log "Creating Secret sql-proxy-sa (cloud-sql-proxy credentials)..."
  kubectl create secret generic sql-proxy-sa -n "$NAMESPACE" \
    --from-file=sa.json="$SQL_PROXY_SA" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

pf_proc_pid() {
  pgrep -f "kubectl port-forward.*$RELEASE_NAME" 2>/dev/null | head -1
}

start_portforward() {
  local proc_pid
  proc_pid="$(pf_proc_pid)"
  if [ -n "$proc_pid" ]; then
    log "port-forward already running (pid $proc_pid)"
    return 0
  fi
  if is_listening "$NIFI_WEB_PORT" || is_listening "$NIFI_HTTP_PORT"; then
    warn "host ports $NIFI_WEB_PORT/$NIFI_HTTP_PORT in use; skipping port-forward"
    return 1
  fi
  log "Starting kubectl port-forward (${NIFI_HTTP_PORT} + ${NIFI_WEB_PORT})..."
  nohup kubectl port-forward "svc/$RELEASE_NAME" -n "$NAMESPACE" \
    "$NIFI_HTTP_PORT:$NIFI_HTTP_PORT" "$NIFI_WEB_PORT:$NIFI_WEB_PORT" \
    >> "$PF_LOG" 2>&1 &
  echo $! > "$PF_PID"
  if wait_for_port "$NIFI_WEB_PORT" 30 && wait_for_port "$NIFI_HTTP_PORT" 30; then
    log "port-forward up: https://127.0.0.1:$NIFI_WEB_PORT/nifi + ListenHTTP :$NIFI_HTTP_PORT"
    return 0
  fi
  err "port-forward failed to bind; see $PF_LOG"
  return 1
}

stop_portforward() {
  local proc_pid
  proc_pid="$(pf_proc_pid)"
  [ -n "$proc_pid" ] && kill "$proc_pid" 2>/dev/null || true
  [ -f "$PF_PID" ] && kill "$(cat "$PF_PID")" 2>/dev/null || true
  pkill -f "kubectl port-forward.*$RELEASE_NAME" 2>/dev/null || true
  rm -f "$PF_PID"
  log "port-forward stopped"
}

# ----- Docker Compose deployment -----
deploy_local() {
  log "Deploying with Docker Compose (local)..."
  check_docker
  ensure_config
  docker compose -f "$COMPOSE_FILE" build
  docker compose -f "$COMPOSE_FILE" up -d
  if wait_for_port "$NIFI_WEB_PORT" 240 && wait_for_port "$NIFI_HTTP_PORT" 120; then
    log "NiFi up: https://127.0.0.1:$NIFI_WEB_PORT/nifi (ListenHTTP :$NIFI_HTTP_PORT)"
  else
    err "NiFi ports not listening"
    return 1
  fi
}

# ----- Kubernetes deployment (minikube) -----
deploy_k8s() {
  log "Deploying to Kubernetes (minikube) via Helm..."
  check_docker
  check_kubectl
  check_helm
  check_minikube
  ensure_minikube
  load_image
  stop_compose_nifi
  ensure_namespace
  create_secrets

  helm upgrade --install "$RELEASE_NAME" "$HELM_CHART" \
    --namespace "$NAMESPACE" \
    --create-namespace \
    --timeout 10m \
    --wait

  kubectl rollout status "statefulset/$RELEASE_NAME" -n "$NAMESPACE" --timeout=300s
  start_portforward
  log "Deployment complete."
  kubectl get pods -n "$NAMESPACE"
}

# ----- Status & teardown -----
show_status() {
  log "Docker Compose:"
  docker compose -f "$COMPOSE_FILE" ps 2>/dev/null || echo "  (no compose deployment)"
  echo ""
  log "Kubernetes (namespace $NAMESPACE):"
  if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    helm list -n "$NAMESPACE" 2>/dev/null
    kubectl get pods,svc,pvc -n "$NAMESPACE" 2>/dev/null
  else
    echo "  (no k8s deployment)"
  fi
  echo ""
  if is_listening "$NIFI_WEB_PORT"; then
    log "NiFi UI reachable at https://127.0.0.1:$NIFI_WEB_PORT/nifi"
  fi
}

teardown() {
  warn "This will stop the deployment."
  read -rp "Continue? [y/N] " confirm
  [[ "$confirm" =~ ^[yY]$ ]] || { log "Cancelled."; exit 0; }

  stop_portforward

  if docker compose -f "$COMPOSE_FILE" ps 2>/dev/null | grep -q "Up\|running"; then
    log "Stopping Docker Compose..."
    docker compose -f "$COMPOSE_FILE" down
  fi

  if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    if helm list -n "$NAMESPACE" -q 2>/dev/null | grep -q .; then
      log "Removing Helm release..."
      helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" --timeout 120s
    fi
    if [ "${1:-}" = "--purge" ]; then
      log "Deleting namespace $NAMESPACE..."
      kubectl delete namespace "$NAMESPACE" --timeout=60s
    fi
  fi
  log "Teardown complete."
}

# ----- Main -----
case "${1:-help}" in
  local)    deploy_local ;;
  k8s)      deploy_k8s ;;
  status)   show_status ;;
  teardown) teardown "${2:-}" ;;
  pf-stop)  stop_portforward ;;
  *)
    echo "E2E Data Pipeline - Universal Deploy Script"
    echo ""
    echo "Usage: $0 <target>"
    echo ""
    echo "Targets:"
    echo "  local         Docker Compose (local/on-prem NiFi)"
    echo "  k8s           Kubernetes via Helm into minikube"
    echo "  status        Show deployment status"
    echo "  teardown      Remove deployment (--purge to delete namespace too)"
    echo "  pf-stop       Stop kubectl port-forward only"
    ;;
esac