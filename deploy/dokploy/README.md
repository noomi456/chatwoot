# Dokploy deployment

This is the Phase 1 ChatRing Conversation Core runtime. Dokploy stores the real environment values and deploys `compose.yml` as a raw Docker Compose application.

## Topology

- `rails`: ChatRing-branded Chatwoot CE web/API/widget runtime.
- `sidekiq`: background jobs from the exact same immutable image.
- `prepare`: one-shot database creation and migration gate.
- `postgres`: dedicated PostgreSQL 16 with pgvector available for Chatwoot CE compatibility.
- `redis`: private persistent cache and queue state.

No service publishes a host port. Dokploy attaches the public `app-staging.chatring.ai` route to the `rails` service on port 3000; Cloudflare remains the only web ingress.

Cloudflare terminates TLS and the Tunnel uses private HTTP to Traefik/Puma, so `FORCE_SSL` remains `false` at Rails. HTTPS redirection belongs at the Cloudflare edge; enabling Rails origin redirection on this topology causes a same-URL redirect loop. The Rails health check stays on the private HTTP listener and supplies `X-Forwarded-Proto: https` for compatibility.

## Trusted client IPs

The host Cloudflare Tunnel reaches Traefik's `web` entry point through the Docker host gateway. Traefik must trust forwarded client-IP headers only from that proven gateway; otherwise Rails sees every public visitor as `172.17.0.1` and Rack::Attack applies the login/IP throttle globally.

The staging gateway is `172.17.0.1/32`. Configure `/etc/dokploy/traefik/traefik.yml` as follows and restart only `dokploy-traefik`:

```yaml
entryPoints:
  web:
    address: :80
    forwardedHeaders:
      trustedIPs:
        - "172.17.0.1/32"
```

Before changing the shared entry point, back up the existing file and validate the candidate with the exact deployed Traefik image. After restart, require all of the following:

- `/health` and the public application route return HTTP 200.
- Rails logs the real client address rather than `172.17.0.1`.
- A forged forwarding-header request through Cloudflare is rejected and does not reach Rails.
- Five failed login attempts from one client make its sixth request return HTTP 429 while a separate client still receives the normal authentication response.
- Direct HTTP and HTTPS connections to the VPS origin remain blocked.

This trust rule is valid only while the Tunnel-to-Traefik source is `172.17.0.1`. Re-resolve and retest the gateway after changing the Docker network, Cloudflare Tunnel origin, or Traefik entry point; do not broaden the CIDR or enable insecure forwarded headers.

## Deployment contract

1. GitHub Actions must pass lint and ChatRing branding tests.
2. GitHub Actions removes `enterprise/` and `spec/enterprise/` before building.
3. Deploy the full immutable `sha-<40-character-commit>` GHCR tag.
4. Generate all secrets outside Git and save them in Dokploy.
5. Deploy and wait for `prepare` to exit successfully, then require healthy Rails/PostgreSQL/Redis and running Sidekiq.
6. Verify `/health`, login, dashboard, widget, handoff, persistence, restart, and backup/restore behavior.

Phase 2A does not run a scheduled Firecrawl crawl/Monitor or hourly knowledge lifecycle reconciler. A user Add/Re-run/Delete
command enqueues the bounded extraction and hidden DocsGPT index replacement needed to finish that command. Retired provider
indexes are deleted by a delayed, idempotent Sidekiq job after the one-hour in-flight safety window.

## Rollback

Set `CHATRING_IMAGE` to the previous verified full-commit tag and redeploy. Do not roll back PostgreSQL after a migration unless the release explicitly documents a compatible database rollback. Preserve the three named volumes.

## Backup and restore

Install `backup-conversation-core.sh` as `/usr/local/sbin/backup-chatring-conversation-core`, then install and enable the provided systemd service and timer. The root-only environment at `/etc/chatring/r2-backup.env` supplies the encrypted Restic repository and bucket-scoped R2 credentials. It may also override `CHATRING_POSTGRES_CONTAINER`, `CHATRING_RAILS_CONTAINER`, `CHATRING_POSTGRES_DATABASE`, `CHATRING_POSTGRES_USERNAME`, and `CHATRING_BACKUP_STAGING` when the Dokploy application identity differs from the initial staging deployment.

Each run stores a PostgreSQL custom-format dump, the Rails storage volume, checksums, immutable image identity, and record counts. `restore-test-conversation-core.sh` restores the latest snapshot into a temporary database, validates both checksums, reads the storage archive, compares record counts, and removes the temporary database. A backup does not pass the Phase 1 gate until this restore test succeeds.

## AgentBot acceptance probe

`phase1-test-adapter.py` is a disposable acceptance harness, not a deployable ChatRing service. It validates timestamped webhook signatures, delivery-ID deduplication, inbound-only processing, outgoing-event loop prevention, deterministic API replies, and human-only suppression after handoff. Run it only against disposable staging data and remove its container and credentials after the test.
