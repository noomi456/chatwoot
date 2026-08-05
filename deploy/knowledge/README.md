# ChatRing Phase 2A Knowledge Execution

This Compose project runs only the pinned DocsGPT API and ingestion worker. Firecrawl remains a cloud extraction dependency. ChatRing Rails owns source manifests, publication pointers, rollback, and the evidence boundary.

## Required private deployment values

- `DOCSGPT_IMAGE` — immutable image built from DocsGPT commit `616e6fe9c435bbc6bb472636db6b3ee2b9bcaf66`.
- `CHATRING_CORE_NETWORK` — the private Conversation Core Compose network.
- `DOCSGPT_POSTGRES_URI` — SQLAlchemy URI for a dedicated DocsGPT database and role.
- `DOCSGPT_PGVECTOR_CONNECTION_STRING` — libpq URI for the same dedicated database.
- `DOCSGPT_CELERY_BROKER_URL` — existing private Redis, dedicated logical database.
- `DOCSGPT_CELERY_RESULT_BACKEND` — existing private Redis, different logical database.
- `DOCSGPT_CACHE_REDIS_URL` — existing private Redis, different logical database.

No service declares `ports`. Rails reaches `http://docs-gpt-backend:7091` on the shared private network.

## Render and verify

Supply all required values through the deployment platform, then run `docker compose config`. Reject the deployment if any required-variable guard fails or if the rendered configuration contains a host port.

After startup, verify the backend health endpoint from the Rails container, confirm the worker is consuming `docsgpt` and `parsing`, and run the ChatRing `chatring:knowledge` tasks for a real map, crawl, ingest, publish, retrieve, and rollback proof.
