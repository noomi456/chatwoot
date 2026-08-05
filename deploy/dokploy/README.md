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

## Deployment contract

1. GitHub Actions must pass lint and ChatRing branding tests.
2. GitHub Actions removes `enterprise/` and `spec/enterprise/` before building.
3. Deploy the full immutable `sha-<40-character-commit>` GHCR tag.
4. Generate all secrets outside Git and save them in Dokploy.
5. Deploy and wait for `prepare` to exit successfully, then require healthy Rails/PostgreSQL/Redis and running Sidekiq.
6. Verify `/health`, login, dashboard, widget, handoff, persistence, restart, and backup/restore behavior.

## Rollback

Set `CHATRING_IMAGE` to the previous verified full-commit tag and redeploy. Do not roll back PostgreSQL after a migration unless the release explicitly documents a compatible database rollback. Preserve the three named volumes.

## Backup and restore

Install `backup-conversation-core.sh` as `/usr/local/sbin/backup-chatring-conversation-core`, then install and enable the provided systemd service and timer. The root-only environment at `/etc/chatring/r2-backup.env` supplies the encrypted Restic repository and bucket-scoped R2 credentials. It may also override `CHATRING_POSTGRES_CONTAINER`, `CHATRING_RAILS_CONTAINER`, `CHATRING_POSTGRES_DATABASE`, `CHATRING_POSTGRES_USERNAME`, and `CHATRING_BACKUP_STAGING` when the Dokploy application identity differs from the initial staging deployment.

Each run stores a PostgreSQL custom-format dump, the Rails storage volume, checksums, immutable image identity, and record counts. `restore-test-conversation-core.sh` restores the latest snapshot into a temporary database, validates both checksums, reads the storage archive, compares record counts, and removes the temporary database. A backup does not pass the Phase 1 gate until this restore test succeeds.

## AgentBot acceptance probe

`phase1-test-adapter.py` is a disposable acceptance harness, not a deployable ChatRing service. It validates timestamped webhook signatures, delivery-ID deduplication, inbound-only processing, outgoing-event loop prevention, deterministic API replies, and human-only suppression after handoff. Run it only against disposable staging data and remove its container and credentials after the test.
