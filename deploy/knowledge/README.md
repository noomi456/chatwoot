# ChatRing Phase 2A Knowledge Execution

This Compose project runs only the pinned DocsGPT API and ingestion worker. Firecrawl remains a cloud extraction dependency. ChatRing Rails owns source manifests, publication pointers, rollback, and the evidence boundary.

The one-shot `docs-gpt-volume-init` service gives the pinned image's non-root `appuser` ownership of its three named volumes before the API starts. This is required for upload ingestion on a fresh volume; the long-running API and worker continue to run as `appuser`.

## Required private deployment values

- `DOCSGPT_IMAGE` — immutable image built from DocsGPT commit `616e6fe9c435bbc6bb472636db6b3ee2b9bcaf66`.
- `CHATRING_CORE_NETWORK` — the private Conversation Core Compose network.
- `DOCSGPT_POSTGRES_URI` — SQLAlchemy URI for a dedicated DocsGPT database and role.
- `DOCSGPT_PGVECTOR_CONNECTION_STRING` — libpq URI for the same dedicated database.
- `DOCSGPT_CELERY_BROKER_URL` — existing private Redis, dedicated logical database.
- `DOCSGPT_CELERY_RESULT_BACKEND` — existing private Redis, different logical database.
- `DOCSGPT_CACHE_REDIS_URL` — existing private Redis, different logical database.
- `DOCSGPT_INTERNAL_KEY` — a high-entropy secret shared only by the DocsGPT API and worker for pinned upstream internal endpoints.

Before starting this project, create the `vector` extension in the dedicated DocsGPT database using the PostgreSQL administrative role:

```sql
CREATE EXTENSION IF NOT EXISTS vector;
```

This must be checked in the dedicated DocsGPT database itself; having the pgvector-enabled PostgreSQL image does not automatically install the extension in every database.

No service declares `ports`. Rails reaches `http://docs-gpt-backend:7091` on the shared private network.

## Render and verify

Supply all required values through the deployment platform, then run `docker compose config`. Reject the deployment if any required-variable guard fails or if the rendered configuration contains a host port.

After startup, verify the `vector` extension exists in the dedicated database, the volume initializer exited successfully, the backend health endpoint responds from the Rails container, and the worker is consuming `docsgpt` and `parsing`. Then run the ChatRing `chatring:knowledge` tasks for a real map, crawl, ingest, publish, retrieve, and rollback proof.
