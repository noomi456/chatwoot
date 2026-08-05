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
- A rollback changes only the immutable application image reference; persistent volumes remain attached.

## Verification

- Render the Compose file with every required variable supplied and reject missing variables.
- Confirm the running image records the expected Git commit.
- Confirm `enterprise/` and `spec/enterprise/` are absent from the running image.
- Confirm Rails reports healthy, Sidekiq runs, and PostgreSQL and Redis pass their health checks.
- Confirm no service in this topology publishes a host port.
- Confirm the public route passes through Cloudflare and Dokploy/Traefik.

## Child DOX Index

- No child DOX files currently required.
