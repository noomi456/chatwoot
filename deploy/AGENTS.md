# ChatRing CE Deployment

## Purpose

Own the reproducible Phase 1 deployment of ChatRing Conversation Core through Dokploy.

## Ownership

- Rails web and Sidekiq workers built from the same immutable ChatRing CE image.
- A dedicated PostgreSQL/pgvector database and Redis instance for Conversation Core.
- Persistent application storage and stateful-service volumes.
- Runtime CE enforcement, health checks, and deployment handoff documentation.

## Local Contracts

- Deploy only full-commit image tags; never deploy `latest`.
- Set `CW_EDITION=ce` and `DISABLE_ENTERPRISE=true` at runtime.
- Do not publish PostgreSQL, Redis, Rails, or Sidekiq host ports.
- Secrets exist only in Dokploy environment storage; never commit them or place them in Compose defaults.
- Rails, Sidekiq, and database preparation must share the same image and environment contract.
- Database preparation must complete successfully before Rails or Sidekiq starts.
- Keep Phase 2 services out of this Compose project.
- Keep `CHATRING_ASSISTANT_SPIKE_ENABLED` false by default. It may be true only during the bounded staging proof and must be returned to false after evidence capture.
- Keep `CHATRING_KNOWLEDGE_LIFECYCLE_RECONCILIATION_ENABLED` false during the first coordinated Rails/DocsGPT rollout. Review the read-only cleanup report before enabling the hourly lifecycle repair and daily narrow provider housekeeping jobs.
- A rollback changes only the immutable application image reference; persistent volumes remain attached.

## Verification

- Render the Compose file with every required variable supplied and reject missing variables.
- Confirm the running image records the expected Git commit.
- Confirm `enterprise/` and `spec/enterprise/` are absent from the running image.
- Confirm Rails reports healthy, Sidekiq runs, and PostgreSQL and Redis pass their health checks.
- Confirm no service in this topology publishes a host port.
- Confirm the public route passes through Cloudflare and Dokploy/Traefik.
- Confirm Traefik trusts forwarded client-IP headers only from the local Cloudflare Tunnel gateway, Rails records the real client IP, direct origin ingress remains blocked, and login throttling is isolated per client.
- Back up PostgreSQL and application storage through encrypted Restic/R2 snapshots, and require an isolated database restore plus checksum validation before treating backups as operational.

## Child DOX Index

- `knowledge/AGENTS.md` — isolated Phase 2A DocsGPT execution services and private-network deployment.
