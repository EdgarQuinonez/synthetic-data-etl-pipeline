# NiFi (Dockerized)

Apache NiFi 2.11.0 running in Docker for the synthetic data ETL pipeline.
The container reuses the existing standalone install at `/opt/nifi` as the
source of config, flow, and repositories.

## Architecture

```
synthetic-data-gen (tail -F + curl POST)
   → http://nginx-ingress:80/synthetic
   → nginx → 127.0.0.1:19090 (ingress VM)
   → autossh reverse tunnel → host 127.0.0.1:19090
   → NiFi ListenHTTP (/synthetic)  [in container]
   → NiFi PutDatabaseRecord → jdbc:postgresql://127.0.0.1:5432/synthetic
   → cloud-sql-proxy (host loopback) → Cloud SQL
```

The container uses **host networking** so the existing flow works unchanged:

- `ListenHTTP` binds host `127.0.0.1:19090` — reachable by the reverse tunnel.
- The DBCP URL `jdbc:postgresql://127.0.0.1:5432/synthetic` resolves to the
  host loopback where `cloud-sql-proxy` listens.
- HTTPS UI is overridden to bind `0.0.0.0:8443` (`NIFI_WEB_HTTPS_HOST`) so it
  is reachable from the Windows host via WSL2 localhost forwarding.

## One-time config sync

Config/flow/SSL files and NiFi repositories are copied from `/opt/nifi` into
`nifi/data/` (gitignored — contains keystore, sensitive props key, encrypted
DB password). Run `sync-config.sh` the first time (or whenever you change the
standalone install and want to refresh):

```bash
bash nifi/sync-config.sh             # copy only if data/conf is empty
bash nifi/sync-config.sh --force     # overwrite everything
```

## Build and run

```bash
docker compose -f docker-compose.yml up -d --build
```

Wait for ports then check:

```bash
ss -tln | grep -E ':(8443|19090) '
curl -k https://127.0.0.1:8443/nifi                      # UI (self-signed cert)
curl -i -X POST --data-binary 'test' http://127.0.0.1:19090/synthetic   # ListenHTTP
```

Stop:

```bash
docker compose -f docker-compose.yml stop
```

## Pipeline scripts

`scripts/start-pipeline.sh` / `scripts/stop-pipeline.sh` /
`scripts/teardown-pipeline.sh` manage NiFi via this compose file (at the repo
root); the port checks (8443, 19090) are unchanged. The full pipeline is
exercised end-to-end by `./scripts/start-pipeline.sh` (with `PGPASSWORD`).

## Notes

- First image pull/build is large (~2 GB); subsequent runs are cached.
- Host networking conflicts if another service occupies 8443 or 19090.
- The flow's DBCP URL assumes host loopback for `cloud-sql-proxy`. If you ever
  switch to bridge networking, update the DBCP `Database Connection URL` in the
  flow (e.g. to `host.docker.internal:5432`) and publish ports instead.
- The official image installs NiFi at `/opt/nifi/nifi-current` (`NIFI_HOME`).
  Volumes mount under that path; the PG driver is baked into both
  `/opt/nifi/nifi-current/lib` (classpath — needed by the top-level DBCP pool
  that has no "Database Driver Locations") and `/opt/nifi/lib`
  (the literal path referenced by the flow's root-group DBCP pool).