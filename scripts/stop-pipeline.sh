#!/usr/bin/env bash
set -uo pipefail

PROJECT="data-etl-pipeline-506215"
ZONE="us-central1-a"
SOURCE_VM="synthetic-data-gen"
INGRESS_VM="nginx-ingress"
SQL_INSTANCE_NAME="synthetic-postgres"
NIFI_WEB_PORT="8443"
NIFI_HTTP_PORT="19090"
SQL_PROXY_PORT="5432"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NIFI_COMPOSE="$REPO_DIR/docker-compose.yml"
LOG_DIR="/home/glowbo/projects/dev-logs/synthetic-data-etl-pipeline/logs"
PID_DIR="$LOG_DIR/run"
PIPELINE_LOG="$LOG_DIR/pipeline.log"
TUNNEL_PID="$PID_DIR/tunnel.pid"
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

wait_port_down() {
  local port="$1" timeout="${2:-60}" i
  for i in $(seq 1 $((timeout / 2))); do
    if ! is_listening "$port"; then
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

stop_nifi() {
  if ! is_listening "$NIFI_WEB_PORT" && ! is_listening "$NIFI_HTTP_PORT"; then
    record "NiFi (not running)" ok
    return 0
  fi
  log "stopping NiFi (docker compose)"
  docker compose -f "$NIFI_COMPOSE" stop >/dev/null 2>&1
  if wait_port_down "$NIFI_WEB_PORT" 180 && wait_port_down "$NIFI_HTTP_PORT" 60; then
    record "NiFi (stopped)" ok
    return 0
  fi
  record "NiFi (ports still up)" fail
  return 1
}

stop_tunnel() {
  local proc_pid
  proc_pid="$(pgrep -f "autossh.*-R $NIFI_HTTP_PORT:127.0.0.1:$NIFI_HTTP_PORT" 2>/dev/null | head -1)"
  if [ -z "$proc_pid" ] && ! pid_alive "$TUNNEL_PID"; then
    record "reverse tunnel (not running)" ok
    return 0
  fi
  log "stopping reverse tunnel"
  [ -n "$proc_pid" ] && kill "$proc_pid" 2>/dev/null || true
  [ -f "$TUNNEL_PID" ] && kill "$(cat "$TUNNEL_PID")" 2>/dev/null || true
  pkill -f "autossh.*$NIFI_HTTP_PORT" 2>/dev/null || true
  sleep 2
  if ! pgrep -f "autossh.*-R $NIFI_HTTP_PORT" >/dev/null 2>&1; then
    record "reverse tunnel (stopped)" ok
    return 0
  fi
  record "reverse tunnel (still running)" fail
  return 1
}

stop_sql_proxy() {
  if ! is_listening "$SQL_PROXY_PORT" && ! pid_alive "$SQL_PROXY_PID"; then
    record "cloud-sql-proxy (not running)" ok
    return 0
  fi
  log "stopping cloud-sql-proxy"
  [ -f "$SQL_PROXY_PID" ] && kill "$(cat "$SQL_PROXY_PID")" 2>/dev/null || true
  pkill -f "cloud-sql-proxy" 2>/dev/null || true
  if wait_port_down "$SQL_PROXY_PORT" 30; then
    record "cloud-sql-proxy (stopped)" ok
    return 0
  fi
  record "cloud-sql-proxy (port still up)" fail
  return 1
}

stop_source_services() {
  local st
  st="$(remote_cmd "$SOURCE_VM" "systemctl is-active synthetic-gen.service synthetic-stream.service" | tr '\n' ' ')"
  if [ "$st" = "inactive inactive " ] || [ -z "$st" ]; then
    record "source services on $SOURCE_VM (not running)" ok
    return 0
  fi
  log "stopping source services on $SOURCE_VM (state='$st')"
  remote_cmd "$SOURCE_VM" "sudo systemctl stop synthetic-gen.service synthetic-stream.service" >/dev/null
  sleep 2
  st="$(remote_cmd "$SOURCE_VM" "systemctl is-active synthetic-gen.service synthetic-stream.service" | tr '\n' ' ')"
  if [ "$st" = "inactive inactive " ]; then
    record "source services on $SOURCE_VM (stopped)" ok
    return 0
  fi
  record "source services on $SOURCE_VM (state='$st')" fail
  return 1
}

cleanup_pids() {
  rm -f "$TUNNEL_PID" "$SQL_PROXY_PID"
  log "removed pid files"
}

main() {
  log "=== synthetic-data-etl-pipeline stop ==="
  stop_nifi
  stop_tunnel
  stop_sql_proxy
  stop_source_services
  cleanup_pids
  log "=== summary ==="
  if [ "${#FAILED[@]}" -eq 0 ]; then
    log "all components stopped"
    return 0
  fi
  log "failed: ${FAILED[*]}"
  return 1
}

main "$@"