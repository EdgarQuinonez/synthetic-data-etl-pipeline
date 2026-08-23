#!/usr/bin/env bash
set -uo pipefail

PROJECT="data-etl-pipeline-506215"
ZONE="us-central1-a"
SOURCE_VM="synthetic-data-gen"
INGRESS_VM="nginx-ingress"
SQL_INSTANCE_NAME="synthetic-postgres"
SQL_PROXY_INSTANCE="data-etl-pipeline-506215:us-central1:synthetic-postgres"
NIFI_HOME="/opt/nifi"
NIFI_WEB_PORT="8443"
NIFI_HTTP_PORT="19090"
SQL_PROXY_BIN="/home/glowbo/bin/cloud-sql-proxy"
SQL_PROXY_SA="/home/glowbo/.config/gcloud/sql-proxy-sa.json"
SQL_PROXY_PORT="5432"
SSH_KEY="$HOME/.ssh/google_compute_engine"
TUNNEL_USER="glowbo"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/home/glowbo/projects/dev-logs/synthetic-data-etl-pipeline/logs"
PID_DIR="$LOG_DIR/run"
PIPELINE_LOG="$LOG_DIR/pipeline.log"
SQL_PROXY_LOG="$LOG_DIR/sql-proxy.log"
TUNNEL_LOG="$LOG_DIR/tunnel.log"
TUNNEL_PID="$PID_DIR/tunnel.pid"
SQL_PROXY_PID="$PID_DIR/sql-proxy.pid"

mkdir -p "$LOG_DIR" "$PID_DIR"

FAILED=()
INGRESS_IP=""

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
  fi
  INGRESS_IP="$(gcloud compute instances describe "$INGRESS_VM" --zone "$ZONE" \
    --format="value(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null)"
  log "ingress external IP: ${INGRESS_IP:-unresolved}"
}

check_cloud_sql() {
  local state i
  state="$(gcloud sql instances describe "$SQL_INSTANCE_NAME" --format="value(state)" 2>/dev/null)"
  if [ "$state" = "RUNNABLE" ]; then
    record "Cloud SQL $SQL_INSTANCE_NAME ($state)" ok
    return 0
  fi
  log "Cloud SQL not RUNNABLE (state=$state), activating"
  gcloud sql instances patch "$SQL_INSTANCE_NAME" --activation-policy=ALWAYS >/dev/null 2>&1
  for i in $(seq 1 15); do
    state="$(gcloud sql instances describe "$SQL_INSTANCE_NAME" --format="value(state)" 2>/dev/null)"
    [ "$state" = "RUNNABLE" ] && break
    sleep 2
  done
  if [ "$state" = "RUNNABLE" ]; then
    record "Cloud SQL $SQL_INSTANCE_NAME (started)" ok
    return 0
  fi
  record "Cloud SQL $SQL_INSTANCE_NAME (state=$state)" fail
  return 1
}

check_sql_proxy() {
  if is_listening "$SQL_PROXY_PORT" && pid_alive "$SQL_PROXY_PID"; then
    record "cloud-sql-proxy (port $SQL_PROXY_PORT)" ok
    return 0
  fi
  if is_listening "$SQL_PROXY_PORT"; then
    record "cloud-sql-proxy (port $SQL_PROXY_PORT)" ok
    return 0
  fi
  log "starting cloud-sql-proxy"
  nohup "$SQL_PROXY_BIN" "$SQL_PROXY_INSTANCE" --credentials-file "$SQL_PROXY_SA" \
    --address 127.0.0.1 --port "$SQL_PROXY_PORT" >> "$SQL_PROXY_LOG" 2>&1 &
  echo $! > "$SQL_PROXY_PID"
  if wait_for_port "$SQL_PROXY_PORT" 30; then
    record "cloud-sql-proxy (started)" ok
    return 0
  fi
  record "cloud-sql-proxy" fail
  return 1
}

check_nifi() {
  if is_listening "$NIFI_WEB_PORT" && is_listening "$NIFI_HTTP_PORT"; then
    record "NiFi (web $NIFI_WEB_PORT, ListenHTTP $NIFI_HTTP_PORT)" ok
    return 0
  fi
  log "starting NiFi"
  "$NIFI_HOME/bin/nifi.sh" start >/dev/null 2>&1
  if wait_for_port "$NIFI_WEB_PORT" 180 && wait_for_port "$NIFI_HTTP_PORT" 120; then
    record "NiFi (started)" ok
    return 0
  fi
  record "NiFi" fail
  return 1
}

tunnel_remote_state() {
  remote_cmd "$INGRESS_VM" "ss -tln 2>/dev/null | grep -q ':$NIFI_HTTP_PORT ' && echo TUNNEL_UP || echo TUNNEL_DOWN" | grep TUNNEL_
}

tunnel_proc_pid() {
  pgrep -f "autossh.*-R $NIFI_HTTP_PORT:127.0.0.1:$NIFI_HTTP_PORT" 2>/dev/null | head -1
}

check_tunnel() {
  local state proc_pid
  state="$(tunnel_remote_state)"
  proc_pid="$(tunnel_proc_pid)"
  if [ "$state" = "TUNNEL_UP" ] && [ -n "$proc_pid" ]; then
    echo "$proc_pid" > "$TUNNEL_PID"
    record "reverse tunnel ($TUNNEL_USER@$INGRESS_IP)" ok
    return 0
  fi
  if [ -z "$INGRESS_IP" ]; then
    record "reverse tunnel (no ingress IP)" fail
    return 1
  fi
  log "starting reverse tunnel to $TUNNEL_USER@$INGRESS_IP (remote=$state proc=$proc_pid)"
  if [ -n "$proc_pid" ]; then
    kill "$proc_pid" 2>/dev/null || true
    sleep 1
  fi
  ssh-keyscan -H "$INGRESS_IP" >> "$HOME/.ssh/known_hosts" 2>/dev/null
  nohup autossh -M 0 -N \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -o ExitOnForwardFailure=yes \
    -o StrictHostKeyChecking=accept-new \
    -i "$SSH_KEY" \
    -R "$NIFI_HTTP_PORT:127.0.0.1:$NIFI_HTTP_PORT" \
    "$TUNNEL_USER@$INGRESS_IP" >> "$TUNNEL_LOG" 2>&1 &
  echo $! > "$TUNNEL_PID"
  state=""
  for i in $(seq 1 15); do
    state="$(tunnel_remote_state)"
    [ "$state" = "TUNNEL_UP" ] && break
    sleep 2
  done
  proc_pid="$(tunnel_proc_pid)"
  [ -n "$proc_pid" ] && echo "$proc_pid" > "$TUNNEL_PID"
  if [ "$state" = "TUNNEL_UP" ]; then
    record "reverse tunnel (started)" ok
    return 0
  fi
  record "reverse tunnel (remote state=$state)" fail
  return 1
}

check_nginx() {
  local st
  st="$(remote_cmd "$INGRESS_VM" "systemctl is-active nginx" | tail -1)"
  if [ "$st" = "active" ]; then
    record "nginx on $INGRESS_VM" ok
    return 0
  fi
  log "restarting nginx on $INGRESS_VM"
  remote_cmd "$INGRESS_VM" "sudo systemctl restart nginx" >/dev/null
  sleep 2
  st="$(remote_cmd "$INGRESS_VM" "systemctl is-active nginx" | tail -1)"
  if [ "$st" = "active" ]; then
    record "nginx on $INGRESS_VM (restarted)" ok
    return 0
  fi
  record "nginx on $INGRESS_VM (state=$st)" fail
  return 1
}

check_source() {
  local st
  st="$(remote_cmd "$SOURCE_VM" "systemctl is-active synthetic-gen.service synthetic-stream.service" | tr '\n' ' ')"
  if [ "$st" = "active active " ]; then
    record "source services on $SOURCE_VM" ok
    return 0
  fi
  log "restarting source services on $SOURCE_VM (state='$st')"
  remote_cmd "$SOURCE_VM" "sudo systemctl restart synthetic-gen.service synthetic-stream.service" >/dev/null
  sleep 2
  st="$(remote_cmd "$SOURCE_VM" "systemctl is-active synthetic-gen.service synthetic-stream.service" | tr '\n' ' ')"
  if [ "$st" = "active active " ]; then
    record "source services on $SOURCE_VM (restarted)" ok
    return 0
  fi
  record "source services on $SOURCE_VM (state='$st')" fail
  return 1
}

e2e_probe() {
  if [ -z "$INGRESS_IP" ]; then
    log "skip e2e probe (no ingress IP)"
    return 0
  fi
  local probe code n run_at
  run_at="$(date '+%s')"
  probe="$(date '+%Y-%m-%d %H:%M:%S,%3N') INFO kernel STARTUP-PROBE pipeline-verification run-at-$run_at"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST \
    --data-binary "$probe" "http://$INGRESS_IP/synthetic")"
  if [ "$code" = "200" ]; then
    record "e2e probe (nginx->tunnel->NiFi, HTTP $code)" ok
  else
    record "e2e probe (HTTP $code)" fail
    return 1
  fi
  if [ -n "${PGPASSWORD:-}" ]; then
    sleep 3
    n="$(PGPASSWORD="$PGPASSWORD" psql -h 127.0.0.1 -U nifi -d synthetic -tAc \
      "SELECT count(*) FROM synthetic_logs WHERE message LIKE '%run-at-$run_at%'" 2>/dev/null | tr -d ' ')"
    if [ "$n" = "1" ]; then
      record "e2e probe row in synthetic_logs" ok
    else
      record "e2e probe row in synthetic_logs (count=$n)" fail
    fi
  else
    log "skip DB row check (set PGPASSWORD to verify the probe row)"
  fi
}

main() {
  log "=== synthetic-data-etl-pipeline startup check ==="
  check_gcloud
  check_cloud_sql
  check_sql_proxy
  check_nifi
  check_tunnel
  check_nginx
  check_source
  e2e_probe
  log "=== summary ==="
  if [ "${#FAILED[@]}" -eq 0 ]; then
    log "all components OK"
    return 0
  fi
  log "failed: ${FAILED[*]}"
  return 1
}

main "$@"