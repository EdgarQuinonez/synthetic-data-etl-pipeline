#!/usr/bin/env bash
set -uo pipefail

NIFI_BASE="https://localhost:8443"
DB_URL="${DB_URL:-jdbc:postgresql://127.0.0.1:5432/synthetic}"
DB_DRIVER="org.postgresql.Driver"
DB_USER="nifi"
DB_PASSWORD="${NIFI_DB_PASSWORD:-Vhc8wf/6pNkZKS9vPBr+iAYC}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="$REPO_DIR/docker-compose.proxy.yml"
SERVICE_NAME="Cloud SQL DBCP verify (probe)"

nifi_creds() {
  docker compose -f "$COMPOSE_FILE" logs nifi 2>/dev/null |
    grep -E 'Generated (Username|Password)' |
    sed -E 's/.*\[(.*)\]/\1/' |
    tail -2
}

NIFI_USERNAME=""
NIFI_PASSWORD=""
while IFS= read -r line && [ -z "$NIFI_USERNAME" ]; do
  NIFI_USERNAME="$line"
done < <(nifi_creds)
NIFI_PASSWORD="$(nifi_creds | tail -1)"

if [ -z "$NIFI_USERNAME" ] || [ -z "$NIFI_PASSWORD" ]; then
  echo "error: could not find generated NiFi credentials in container logs" >&2
  exit 1
fi
echo "nifi user: $NIFI_USERNAME"

login() {
  curl -sk -X POST "$NIFI_BASE/nifi-api/access/token" \
    --data-urlencode "username=$NIFI_USERNAME" \
    --data-urlencode "password=$NIFI_PASSWORD" \
    -w '\n%{http_code}'
}

TOKEN_RESP="$(login)"
TOKEN="$(echo "$TOKEN_RESP" | head -1)"
CODE="$(echo "$TOKEN_RESP" | tail -1)"
if [ "$CODE" != "201" ]; then
  echo "error: NiFi login failed (HTTP $CODE)" >&2
  exit 1
fi
echo "login: HTTP $CODE (token acquired)"

create_service() {
  curl -sk -X POST "$NIFI_BASE/nifi-api/controller/controller-services" \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    -d "$(cat <<JSON
{
  "revision": { "version": 0 },
  "component": {
    "type": "org.apache.nifi.dbcp.DBCPConnectionPool",
    "name": "$SERVICE_NAME",
    "properties": {
      "Database Connection URL": "$DB_URL",
      "Database Driver Class Name": "$DB_DRIVER",
      "Database User": "$DB_USER",
      "Password": "$DB_PASSWORD"
    }
  }
}
JSON
)"
}

CREATE_RESP="$(create_service)"
SERVICE_ID="$(echo "$CREATE_RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])' 2>/dev/null)"
if [ -z "$SERVICE_ID" ]; then
  echo "error: failed to create DBCPConnectionPool:" >&2
  echo "$CREATE_RESP" >&2
  exit 1
fi
echo "created DBCPConnectionPool id=$SERVICE_ID"

get_version() {
  echo "$1" | python3 -c 'import sys,json;print(json.load(sys.stdin)["revision"]["version"])'
}

ENABLE_RESP="$(curl -sk -X PUT "$NIFI_BASE/nifi-api/controller-services/$SERVICE_ID/run-status" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d "$(cat <<JSON
{ "revision": { "version": $(get_version "$CREATE_RESP") }, "state": "ENABLED" }
JSON
)")"

echo "enable: HTTP $(echo "$ENABLE_RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin)["component"].get("state",""))' 2>/dev/null) (async)"

STATE=""
VALIDATION=""
VER="$ENABLE_RESP"
for i in $(seq 1 30); do
  CURRENT="$(curl -sk "$NIFI_BASE/nifi-api/controller-services/$SERVICE_ID" \
    -H "Authorization: Bearer $TOKEN")"
  STATE="$(echo "$CURRENT" | python3 -c 'import sys,json;print(json.load(sys.stdin)["component"].get("state",""))' 2>/dev/null)"
  VALIDATION="$(echo "$CURRENT" | python3 -c 'import sys,json;d=json.load(sys.stdin);print("; ".join(d["component"].get("validationErrors") or []))' 2>/dev/null)"
  if [ "$STATE" = "ENABLED" ] || [ "$STATE" = "DISABLED" ]; then
    break
  fi
  sleep 2
done
VER="$CURRENT"

echo "final state=$STATE"
if [ -n "$VALIDATION" ]; then
  echo "validationErrors: $VALIDATION"
fi

DISABLE_RESP="$(curl -sk -X PUT "$NIFI_BASE/nifi-api/controller-services/$SERVICE_ID/run-status" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d "$(cat <<JSON
{ "revision": { "version": $(get_version "$VER") }, "state": "DISABLED" }
JSON
)")"

curl -sk -X DELETE "$NIFI_BASE/nifi-api/controller-services/$SERVICE_ID?version=$(get_version "$DISABLE_RESP")" \
  -H "Authorization: Bearer $TOKEN" -o /dev/null -w "cleanup: delete HTTP %{http_code}\n"

if [ "$STATE" = "ENABLED" ] && [ -z "$VALIDATION" ]; then
  echo "RESULT: DBCP connection to Cloud SQL verified"
  exit 0
fi
echo "RESULT: DBCP verification FAILED"
exit 1