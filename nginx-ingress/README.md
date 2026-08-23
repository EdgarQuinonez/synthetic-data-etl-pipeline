# nginx-ingress

A single e2-micro VM in the same GCP project that acts as the HTTP ingress point for the
synthetic data pipeline. It runs nginx, receives streamed log lines from the
`random-synthetic-data-generator` VM, and reverse-proxies them to Apache NiFi's `ListenHTTP`
processor over an autossh reverse tunnel.

## Architecture

```
synthetic-data-gen (tail -F /var/log/synthetic.log + curl POST)
   → http://nginx-ingress:80/synthetic          (internal DNS / internal IP)
   → nginx reverse proxy → 127.0.0.1:19090
   → autossh -R reverse tunnel (on your local machine)
   → NiFi ListenHTTP (127.0.0.1:19090, base path /synthetic)
```

## Create the VM

```bash
gcloud compute instances create nginx-ingress \
  --zone=us-central1-a \
  --machine-type=e2-micro \
  --image-family=debian-12 \
  --image-project=debian-cloud \
  --tags=http-ingress \
  --metadata-from-file=startup-script=startup.sh
```

The startup script installs nginx and writes `/etc/nginx/sites-available/synthetic`
(see `nginx-synthetic.conf`) with:

```
location /synthetic { proxy_pass http://127.0.0.1:19090; }
```

## Allow HTTP traffic

```bash
gcloud compute firewall-rules create allow-http-80 \
  --allow=tcp:80 \
  --source-ranges=0.0.0.0/0 \
  --target-tags=http-ingress
```

## Reverse tunnel (local machine → ingress VM)

NiFi's `ListenHTTP` runs on your local machine on port `19090`. The ingress VM proxies to
`127.0.0.1:19090`, so the reverse tunnel must map the ingress VM's localhost:19090 back to
your machine.

```bash
brew install autossh   # first time only

autossh -M 0 -N \
  -o "ServerAliveInterval=30" \
  -o "ServerAliveCountMax=3" \
  -o "ExitOnForwardFailure=yes" \
  -i ~/.ssh/google_compute_engine \
  -R 19090:127.0.0.1:19090 \
  glowbo@<NGINX_INGRESS_EXTERNAL_IP>
```

Run it under `nohup`/a systemd user unit to keep it persistent. Add the host to
`~/.ssh/known_hosts` first if SSH complains:

```bash
ssh-keyscan -H <NGINX_INGRESS_EXTERNAL_IP> >> ~/.ssh/known_hosts
```

## NiFi ListenHTTP

- Listening Port: `19090`
- Base Path: `/synthetic`
- Ingest → SplitText → ExtractText → RouteOnAttribute → ReplaceText (JSON) → PutDatabaseRecord

## Verify

```bash
# nginx is up
curl -s -o /dev/null -w '%{http_code}\n' http://<NGINX_INGRESS_EXTERNAL_IP>/synthetic

# source VM streams (check nginx access log on the ingress VM)
gcloud compute ssh nginx-ingress --zone us-central1-a \
  --command "tail /var/log/nginx/access.log"

# rows landing in Cloud SQL (through the local cloud-sql-proxy)
PGPASSWORD='<NIFI_DB_PW>' psql -h 127.0.0.1 -U nifi -d synthetic \
  -c "SELECT count(*) FROM synthetic_logs;"
```