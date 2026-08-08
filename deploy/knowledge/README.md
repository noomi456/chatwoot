# Private DocsGPT execution

This Compose project runs only the pinned DocsGPT API and ingestion worker. Firecrawl remains the extraction dependency. ChatRing Rails owns the account Workspace, canonical Training Materials catalog, active hidden-index pointer, and evidence boundary.

Required secrets and endpoints:

- `DOCSGPT_IMAGE` — immutable ChatRing-derived image digest.
- `DOCSGPT_POSTGRES_URI` and `DOCSGPT_PGVECTOR_CONNECTION_STRING` — dedicated DocsGPT database credentials.
- `DOCSGPT_CELERY_BROKER_URL`, `DOCSGPT_CELERY_RESULT_BACKEND`, and `DOCSGPT_CACHE_REDIS_URL` — isolated Redis databases.
- `DOCSGPT_INTERNAL_KEY` — shared high-entropy API/worker credential.
- `DOCSGPT_JWT_SECRET` — user-authentication secret used only for DocsGPT ingestion APIs.
- `DOCSGPT_SERVICE_SECRET` — independent HMAC key scoping private retrieval and deletion to an account, hidden index, binding digest, operation, and provider source.

No service publishes a host port. Do not deploy the DocsGPT frontend, final-answer Agent path, broad Celery Beat scheduler, or legacy `/api/search` route as ChatRing's evidence seam.

After startup, verify the private health endpoint, ingestion worker, one account-level mixed website/file index, scored supported retrieval, zero-result abstention, wrong-scope rejection, and idempotent obsolete-source deletion. Public AI responses remain disabled until Architecture v2.1 Sections 15 and 21.7 pass.
