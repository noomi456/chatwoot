# Dokploy deployment

This is the Phase 1 ChatRing Conversation Core runtime. Dokploy stores the real environment values and deploys `compose.yml` as a raw Docker Compose application.

## Topology

- `rails`: ChatRing-branded Chatwoot CE web/API/widget runtime.
- `sidekiq`: background jobs from the exact same immutable image.
- `prepare`: one-shot database creation and migration gate.
- `postgres`: dedicated PostgreSQL 16 with pgvector available for Chatwoot CE compatibility.
- `redis`: private persistent cache and queue state.

No service publishes a host port. Dokploy attaches the public `app-staging.chatring.ai` route to the `rails` service on port 3000; Cloudflare remains the only web ingress.

The Rails health check stays on the private HTTP listener and supplies `X-Forwarded-Proto: https`, matching Cloudflare/Traefik's trusted external scheme without attempting TLS directly against Puma.

## Deployment contract

1. GitHub Actions must pass lint and ChatRing branding tests.
2. GitHub Actions removes `enterprise/` and `spec/enterprise/` before building.
3. Deploy the full immutable `sha-<40-character-commit>` GHCR tag.
4. Generate all secrets outside Git and save them in Dokploy.
5. Deploy and wait for `prepare` to exit successfully, then require healthy Rails/PostgreSQL/Redis and running Sidekiq.
6. Verify `/health`, login, dashboard, widget, handoff, persistence, restart, and backup/restore behavior.

## Rollback

Set `CHATRING_IMAGE` to the previous verified full-commit tag and redeploy. Do not roll back PostgreSQL after a migration unless the release explicitly documents a compatible database rollback. Preserve the three named volumes.
