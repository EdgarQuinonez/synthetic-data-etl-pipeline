#!/usr/bin/env bash
# =============================================================
# Deploy NiFi to GKE (plain kubectl apply manifests)
# =============================================================
# Creates the GKE cluster, starts Cloud SQL, pushes the NiFi image
# to GCR, generates ConfigMap/Secrets from the local NiFi config,
# applies gcp/k8s/*.yaml, and verifies the cloud-sql-proxy sidecar
# can reach the Cloud SQL instance.
#
# Usage:
#   ./deploy.sh            # full deploy + verify
#   ./deploy.sh status     # show deployment + connection status
#   ./deploy.sh teardown   # delete namespace (--purge to delete cluster too)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$SCRIPT_DIR"

PROJECT_ID="data-etl-pipeline-506215"
REGION="us-west1"
CLUSTER_NAME="e2e-pipeline"
NAMESPACE="pipeline"
INSTANCE="data-etl-pipeline-506215:us-central1:synthetic-postgres"
SQL_INSTANCE_NAME="synthetic-postgres"
SQL_ZONE="us-central1-a"

IMAGE_NAME="synthetic-nifi:2.11.0"
IMAGE_GCR="gcr.io/$PROJECT_ID/synthetic-nifi:2.11.0"
CLOUD_SQL_PROXY_IMAGE="gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.25.2"

NIFI_CONF="${NIFI_CONF:-/opt/nifi/conf}"
SQL_PROXY_SA="${SQL_PROXY_SA:-$HOME/.config/gcloud/sql-proxy-sa.json}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[DEPLOY]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1" >&2; }

check_prereqs() {
  command -v gcloud >/dev/null 2>&1 || { err "gcloud not found."; exit 1; }
  command -v kubectl >/dev/null 2>&1 || { err "kubectl not found."; exit 1; }
  command -v docker >/dev/null 2>&1 || { err "docker not found."; exit 1; }
  log "prereqs: OK"
}

check_conf() {
  [ -f "$NIFI_CONF/nifi.properties" ] || { err "NiFi config not found at $NIFI_CONF"; exit 1; }
  [ -f "$SQL_PROXY_SA" ] || { err "cloud-sql-proxy SA key not found at $SQL_PROXY_SA"; exit 1; }
  log "config: $NIFI_CONF + $SQL_PROXY_SA"
}

ensure_cluster() {
  if ! gcloud container clusters describe "$CLUSTER_NAME" --region="$REGION" >/dev/null 2>&1; then
    log "Creating GKE cluster $CLUSTER_NAME (this takes several minutes)..."
    gcloud container clusters create "$CLUSTER_NAME" \
      --region="$REGION" \
      --machine-type=e2-standard-2 \
      --num-nodes=1 \
      --tags=nifi-gke
  else
    log "GKE cluster $CLUSTER_NAME already exists"
  fi
  gcloud container clusters get-credentials "$CLUSTER_NAME" --region="$REGION" >/dev/null
  log "kubeconfig: $(kubectl config current-context)"
}

ensure_cloud_sql() {
  local state
  state="$(gcloud sql instances describe "$SQL_INSTANCE_NAME" \
    --format='value(state)' 2>/dev/null)"
  if [ "$state" = "STOPPED" ]; then
    log "Starting Cloud SQL instance $SQL_INSTANCE_NAME..."
    gcloud sql instances start "$SQL_INSTANCE_NAME"
  elif [ "$state" = "RUNNABLE" ] || [ "$state" = "RUNNING" ]; then
    log "Cloud SQL instance $SQL_INSTANCE_NAME already running"
  else
    err "unexpected Cloud SQL state: '$state'"
    exit 1
  fi
}

push_image() {
  docker image inspect "$IMAGE_GCR" >/dev/null 2>&1 \
    || docker tag "$IMAGE_NAME" "$IMAGE_GCR"
  log "Pushing $IMAGE_GCR..."
  docker push "$IMAGE_GCR"
}

ensure_namespace() {
  kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 \
    || kubectl create namespace "$NAMESPACE" >/dev/null
  log "namespace: $NAMESPACE"
}

create_config() {
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

apply_manifests() {
  log "Applying manifests..."
  kubectl apply -f "$K8S_DIR/namespace.yaml"
  kubectl apply -f "$K8S_DIR/service.yaml"
  kubectl apply -f "$K8S_DIR/statefulset.yaml"
}

wait_ready() {
  log "Waiting for StatefulSet to become ready..."
  kubectl rollout status "statefulset/$CLUSTER_NAME" -n "$NAMESPACE" --timeout=600s
}

verify_proxy() {
  local pod
  pod="$(kubectl get pod -n "$NAMESPACE" -l app=$CLUSTER_NAME -o jsonpath='{.items[0].metadata.name}')"
  [ -n "$pod" ] || { err "no pod found in namespace $NAMESPACE"; return 1; }
  log "Verifying cloud-sql-proxy in pod $pod..."

  echo
  kubectl logs "$pod" -n "$NAMESPACE" -c cloud-sql-proxy --tail=20
  echo

  if kubectl logs "$pod" -n "$NAMESPACE" -c cloud-sql-proxy --tail=50 2>/dev/null \
      | grep -q "Ready for new connections"; then
    log "SUCCESS: cloud-sql-proxy connected to $INSTANCE"
  else
    err "cloud-sql-proxy did not log 'Ready for new connections'; see logs above"
    return 1
  fi

  log "Testing TCP connect to 127.0.0.1:5432 from the nifi container..."
  if kubectl exec "$pod" -n "$NAMESPACE" -c nifi -- \
      bash -c 'exec 3<>/dev/tcp/127.0.0.1/5432' 2>/dev/null; then
    log "SUCCESS: port 5432 reachable in-pod"
  else
    err "could not reach 127.0.0.1:5432 in-pod"
    return 1
  fi
}

show_status() {
  kubectl get pods,svc,pvc -n "$NAMESPACE" 2>/dev/null || warn "no deployment in namespace $NAMESPACE"
}

teardown() {
  if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    kubectl delete namespace "$NAMESPACE" --timeout=120s
  fi
  if [ "${1:-}" = "--purge" ]; then
    if gcloud container clusters describe "$CLUSTER_NAME" --region="$REGION" >/dev/null 2>&1; then
      gcloud container clusters delete "$CLUSTER_NAME" --region="$REGION" --quiet
    fi
  fi
  log "Teardown complete."
}

deploy() {
  check_prereqs
  check_conf
  ensure_cluster
  ensure_cloud_sql
  push_image
  ensure_namespace
  create_config
  apply_manifests
  wait_ready
  verify_proxy
  log "Deploy complete."
  show_status
}

case "${1:-deploy}" in
  deploy)   deploy ;;
  status)   check_prereqs; show_status ;;
  teardown) teardown "${2:-}" ;;
  *)
    echo "Usage: $0 [deploy|status|teardown [--purge]]"
    ;;
esac