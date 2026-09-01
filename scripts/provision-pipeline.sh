#!/usr/bin/env bash
set -uo pipefail

PROJECT="data-etl-pipeline-506215"
ZONE="us-central1-a"
SOURCE_VM="synthetic-data-gen"
INGRESS_VM="nginx-ingress"
SQL_INSTANCE_NAME="synthetic-postgres"
SQL_DB_NAME="synthetic"
SQL_USER_NAME="nifi"
SQL_USER_PASSWORD="Vhc8wf/6pNkZKS9vPBr+iAYC"
SQL_ROOT_PASSWORD="data-etl-pipeline-dev-2026"
SQL_TIER="db-f1-micro"
SQL_REGION="us-central1"
SQL_DATABASE_VERSION="POSTGRES_16"
FIREWALL_RULE="allow-http-80"
NIFI_HOME="/opt/nifi"
SQL_PROXY_BIN="/home/glowbo/bin/cloud-sql-proxy"
SQL_PROXY_SA="/home/glowbo/.config/gcloud/sql-proxy-sa.json"
SQL_PROXY_PORT="5432"
SQL_PROXY_INSTANCE="$PROJECT:$SQL_REGION:$SQL_INSTANCE_NAME"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="/home/glowbo/projects/dev-logs/synthetic-data-etl-pipeline/logs"
PID_DIR="$LOG_DIR/run"
PIPELINE_LOG="$LOG_DIR/pipeline.log"
SQL_PROXY_PID="$PID_DIR/sql-proxy.pid"

mkdir -p "$LOG_DIR" "$PID_DIR"

FAILED=()

log() {
  local msg="[$(date '+%F %T')] $*"
  echo "$msg"
  echo "$msg" >> "$PIPELINE_LOG"
}

record() {
  if [ "$2" = "ok" ]; then
    log "OK   $1"
  else
    log "FAIL $1"
    FAILED+=("$1")
  fi
}

is_listening() {
  ss -tln 2>/dev/null | grep -q ":$1 "
}

wait_for_port() {
  local port="$1" timeout="${2:-60}" i
  for i in $(seq 1 $((timeout / 2))); do
    if is_listening "$port"; then
      return 0
    fi
    sleep 2
  done
  return 1
}

pid_alive() {
  [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null
}

remote_cmd() {
  local vm="$1" cmd="$2"
  gcloud compute ssh "$vm" --zone "$ZONE" --quiet --command "$cmd" 2>/dev/null
}

check_gcloud() {
  local cur
  cur="$(gcloud config get-value project 2>/dev/null)"
  if [ "$cur" = "$PROJECT" ]; then
    record "gcloud project ($PROJECT)" ok
  else
    record "gcloud project (got '$cur')" fail
    return 1
  fi
  if ! gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | grep -q .; then
    record "gcloud active account" fail
    return 1
  fi
  record "gcloud active account" ok
  return 0
}

ensure_firewall() {
  if gcloud compute firewall-rules describe "$FIREWALL_RULE" >/dev/null 2>&1; then
    record "firewall rule $FIREWALL_RULE (exists)" ok
    return 0
  fi
  log "creating firewall rule $FIREWALL_RULE"
  gcloud compute firewall-rules create "$FIREWALL_RULE" \
    --allow=tcp:80 \
    --source-ranges=0.0.0.0/0 \
    --target-tags=http-ingress >/dev/null 2>&1
  if gcloud compute firewall-rules describe "$FIREWALL_RULE" >/dev/null 2>&1; then
    record "firewall rule $FIREWALL_RULE (created)" ok
    return 0
  fi
  record "firewall rule $FIREWALL_RULE" fail
  return 1
}

ensure_cloud_sql() {
  local state
  state="$(gcloud sql instances describe "$SQL_INSTANCE_NAME" --format='value(state)' 2>/dev/null)"
  if [ "$state" = "RUNNABLE" ]; then
    record "Cloud SQL $SQL_INSTANCE_NAME (RUNNABLE)" ok
    return 0
  fi
  if [ -n "$state" ]; then
    record "Cloud SQL $SQL_INSTANCE_NAME (state=$state)" fail
    return 1
  fi
  log "creating Cloud SQL $SQL_INSTANCE_NAME ($SQL_TIER, $SQL_DATABASE_VERSION)"
  gcloud sql instances create "$SQL_INSTANCE_NAME" \
    --database-version="$SQL_DATABASE_VERSION" \
    --edition=enterprise \
    --region="$SQL_REGION" \
    --tier="$SQL_TIER" \
    --root-password="$SQL_ROOT_PASSWORD" \
    --activation-policy=ALWAYS >/dev/null 2>&1
  for i in $(seq 1 45); do
    state="$(gcloud sql instances describe "$SQL_INSTANCE_NAME" --format='value(state)' 2>/dev/null)"
    [ "$state" = "RUNNABLE" ] && break
    sleep 2
  done
  if [ "$state" = "RUNNABLE" ]; then
    record "Cloud SQL $SQL_INSTANCE_NAME (created)" ok
    return 0
  fi
  record "Cloud SQL $SQL_INSTANCE_NAME (state=$state)" fail
  return 1
}

ensure_sql_db() {
  if gcloud sql databases describe "$SQL_DB_NAME" --instance="$SQL_INSTANCE_NAME" >/dev/null 2>&1; then
    record "Cloud SQL database $SQL_DB_NAME (exists)" ok
    return 0
  fi
  log "creating database $SQL_DB_NAME"
  gcloud sql databases create "$SQL_DB_NAME" --instance="$SQL_INSTANCE_NAME" >/dev/null 2>&1
  if gcloud sql databases describe "$SQL_DB_NAME" --instance="$SQL_INSTANCE_NAME" >/dev/null 2>&1; then
    record "Cloud SQL database $SQL_DB_NAME (created)" ok
    return 0
  fi
  record "Cloud SQL database $SQL_DB_NAME" fail
  return 1
}

ensure_sql_user() {
  if gcloud sql users describe "$SQL_USER_NAME" --instance="$SQL_INSTANCE_NAME" >/dev/null 2>&1; then
    record "Cloud SQL user $SQL_USER_NAME (exists)" ok
    return 0
  fi
  log "creating user $SQL_USER_NAME"
  gcloud sql users create "$SQL_USER_NAME" --instance="$SQL_INSTANCE_NAME" --password="$SQL_USER_PASSWORD" >/dev/null 2>&1
  if gcloud sql users describe "$SQL_USER_NAME" --instance="$SQL_INSTANCE_NAME" >/dev/null 2>&1; then
    record "Cloud SQL user $SQL_USER_NAME (created)" ok
    return 0
  fi
  record "Cloud SQL user $SQL_USER_NAME" fail
  return 1
}

start_sql_proxy() {
  if is_listening "$SQL_PROXY_PORT"; then
    record "cloud-sql-proxy (port $SQL_PROXY_PORT)" ok
    return 0
  fi
  log "starting cloud-sql-proxy"
  nohup "$SQL_PROXY_BIN" "$SQL_PROXY_INSTANCE" --credentials-file "$SQL_PROXY_SA" \
    --address 127.0.0.1 --port "$SQL_PROXY_PORT" >> "$LOG_DIR/sql-proxy.log" 2>&1 &
  echo $! > "$SQL_PROXY_PID"
  if wait_for_port "$SQL_PROXY_PORT" 30; then
    record "cloud-sql-proxy (started)" ok
    return 0
  fi
  record "cloud-sql-proxy" fail
  return 1
}

ensure_table() {
  local owner n
  if ! start_sql_proxy; then
    return 1
  fi
  n="$(PGPASSWORD="$SQL_ROOT_PASSWORD" psql -h 127.0.0.1 -U postgres -d "$SQL_DB_NAME" -tAc \
    "SELECT 1 FROM pg_tables WHERE schemaname='public' AND tablename='synthetic_logs'" 2>/dev/null | tr -d ' ')"
  if [ "$n" = "1" ]; then
    record "table synthetic_logs (exists)" ok
    return 0
  fi
  log "creating table synthetic_logs"
  PGPASSWORD="$SQL_ROOT_PASSWORD" psql -h 127.0.0.1 -U postgres -d "$SQL_DB_NAME" -q \
    -c "ALTER DATABASE $SQL_DB_NAME OWNER TO $SQL_USER_NAME;" >/dev/null 2>&1
  PGPASSWORD="$SQL_USER_PASSWORD" psql -h 127.0.0.1 -U "$SQL_USER_NAME" -d "$SQL_DB_NAME" -q <<'SQL' >/dev/null 2>&1
CREATE TABLE IF NOT EXISTS synthetic_logs (
  id bigserial PRIMARY KEY,
  log_ts text,
  level character varying(10),
  source character varying(20),
  message text,
  record_type character varying(15),
  tx_id character varying(20),
  user_id character varying(20),
  amount text,
  currency character varying(4),
  merchant character varying(64),
  tx_status character varying(10),
  ingest_time timestamp with time zone NOT NULL DEFAULT now()
);
SQL
  n="$(PGPASSWORD="$SQL_USER_PASSWORD" psql -h 127.0.0.1 -U "$SQL_USER_NAME" -d "$SQL_DB_NAME" -tAc \
    "SELECT 1 FROM pg_tables WHERE schemaname='public' AND tablename='synthetic_logs'" 2>/dev/null | tr -d ' ')"
  if [ "$n" = "1" ]; then
    record "table synthetic_logs (created)" ok
    return 0
  fi
  record "table synthetic_logs" fail
  return 1
}

ensure_nginx_vm() {
  if gcloud compute instances describe "$INGRESS_VM" --zone "$ZONE" >/dev/null 2>&1; then
    record "VM $INGRESS_VM (exists)" ok
    return 0
  fi
  log "creating VM $INGRESS_VM"
  gcloud compute instances create "$INGRESS_VM" \
    --zone="$ZONE" \
    --machine-type=e2-micro \
    --image-family=debian-12 \
    --image-project=debian-cloud \
    --tags=http-ingress \
    --metadata-from-file=startup-script="$REPO_DIR/gcp/vms/nginx-ingress/startup.sh" >/dev/null 2>&1
  if gcloud compute instances describe "$INGRESS_VM" --zone "$ZONE" >/dev/null 2>&1; then
    record "VM $INGRESS_VM (created)" ok
    return 0
  fi
  record "VM $INGRESS_VM" fail
  return 1
}

ensure_source_vm() {
  if gcloud compute instances describe "$SOURCE_VM" --zone "$ZONE" >/dev/null 2>&1; then
    record "VM $SOURCE_VM (exists)" ok
    return 0
  fi
  log "creating VM $SOURCE_VM"
  gcloud compute instances create "$SOURCE_VM" \
    --zone="$ZONE" \
    --machine-type=e2-micro \
    --image-family=debian-12 \
    --image-project=debian-cloud \
    --metadata-from-file=startup-script="$REPO_DIR/gcp/vms/random-synthetic-data-generator/startup.sh" >/dev/null 2>&1
  if gcloud compute instances describe "$SOURCE_VM" --zone "$ZONE" >/dev/null 2>&1; then
    record "VM $SOURCE_VM (created)" ok
    return 0
  fi
  record "VM $SOURCE_VM" fail
  return 1
}

wait_vm_ready() {
  local vm="$1" cmd="$2" want="$3" st i
  for i in $(seq 1 60); do
    st="$(remote_cmd "$vm" "$cmd" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
    if [ "$st" = "$want" ]; then
      return 0
    fi
    sleep 4
  done
  return 1
}

verify_vms() {
  local ok=1
  if wait_vm_ready "$INGRESS_VM" "systemctl is-active nginx" "active"; then
    record "nginx on $INGRESS_VM" ok
  else
    record "nginx on $INGRESS_VM (not ready)" fail
    ok=0
  fi
  if wait_vm_ready "$SOURCE_VM" "systemctl is-active synthetic-gen.service synthetic-stream.service" "active active"; then
    record "source services on $SOURCE_VM" ok
  else
    record "source services on $SOURCE_VM (not ready)" fail
    ok=0
  fi
  return $ok
}

main() {
  log "=== synthetic-data-etl-pipeline provision ==="
  check_gcloud || return 1
  ensure_firewall
  ensure_cloud_sql || return 1
  ensure_sql_db
  ensure_sql_user
  ensure_table
  ensure_nginx_vm
  ensure_source_vm
  verify_vms
  log "=== summary ==="
  if [ "${#FAILED[@]}" -eq 0 ]; then
    log "provisioning complete"
    return 0
  fi
  log "failed: ${FAILED[*]}"
  return 1
}

main "$@"