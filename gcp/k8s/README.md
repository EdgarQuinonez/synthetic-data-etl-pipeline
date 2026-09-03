# GKE Deployment (plain manifests)

Deploys Apache NiFi to a GKE cluster using `kubectl apply` with plain YAML
(no Helm). The NiFi pod runs `cloud-sql-proxy` as a sidecar so the flow's DBCP
URL (`jdbc:postgresql://127.0.0.1:5432/synthetic`) resolves in-pod.

## Architecture

```
synthetic-data-gen (tail -F + curl POST)
   → nginx-ingress VM → reverse tunnel → NiFi ListenHTTP (:19090)   [in pod]
   → NiFi PutDatabaseRecord → jdbc:postgresql://127.0.0.1:5432/synthetic
   → cloud-sql-proxy sidecar (127.0.0.1:5432) → Cloud SQL synthetic-postgres
```

## Files

| File | Purpose |
|---|---|
| `namespace.yaml` | namespace `pipeline` |
| `statefulset.yaml` | NiFi StatefulSet + `seed-conf` init + `cloud-sql-proxy` sidecar + PVCs |
| `service.yaml` | ClusterIP exposing 8443 (HTTPS) + 19090 (ListenHTTP) |
| `deploy.sh` | full orchestration: cluster, Cloud SQL, image push, config, apply, verify |

## Deploy

```bash
gcp/k8s/deploy.sh deploy
```

The script:

1. Creates GKE cluster `e2e-pipeline` (us-central1, e2-standard-2 x1) if absent
   and sets kubeconfig.
2. Starts Cloud SQL `synthetic-postgres` if stopped.
3. Tags + pushes `synthetic-nifi:2.11.0` to
   `gcr.io/data-etl-pipeline-506215/synthetic-nifi:2.11.0`.
4. Generates ConfigMap `nifi-conf` and Secrets `nifi-conf-secret`,
   `sql-proxy-sa` from `/opt/nifi/conf` and `~/.config/gcloud/sql-proxy-sa.json`
   (sources are overridable via `NIFI_CONF` / `SQL_PROXY_SA`).
5. `kubectl apply -f` all manifests.
6. Verifies the sidecar logs `Ready for new connections` and that port 5432 is
   reachable in-pod.

Secrets are never committed — they are generated at deploy time and applied
via `kubectl apply -f -`.

## Manual verify / access

```bash
kubectl get pods -n pipeline
kubectl logs e2e-pipeline-0 -n pipeline -c cloud-sql-proxy   # expect "Ready for new connections"

# port-forward to reach the UI / ListenHTTP
kubectl port-forward svc/e2e-pipeline -n pipeline 8443:8443 19090:19090
curl -k https://localhost:8443/nifi
curl -i -X POST --data-binary 'test' http://localhost:19090/synthetic
```

## Status / teardown

```bash
gcp/k8s/deploy.sh status
gcp/k8s/deploy.sh teardown            # delete namespace
gcp/k8s/deploy.sh teardown --purge    # + delete GKE cluster
```

## Notes

- Probes are `exec` (`curl -ksS https://localhost:8443/nifi`) because NiFi 2.x
  (Jetty 10+) rejects pod-IP SNI — see `.ai/sandbox/012-nifi-sni-probe-fix.md`.
- `NIFI_WEB_HTTPS_HOST=0.0.0.0` so the HTTPS connector binds all interfaces
  (required for port-forward; see `.ai/sandbox/011-fix-on-nifi-never-ready.md`).
- `seed-conf` init container runs as root to `chown` the PVC-backed `/conf` and
  `/repos` to UID/GID 1000; main containers run as 1000
  (see `.ai/sandbox/009-claude-debug.md`).
- PVCs use GKE default storage class `standard` (pd-standard).