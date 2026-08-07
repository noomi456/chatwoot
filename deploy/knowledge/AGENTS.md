# Phase 2A Knowledge Execution Deployment

## Purpose

Own the private DocsGPT API and ingestion worker used by ChatRing's versioned knowledge control plane.

## Ownership

- The immutable DocsGPT image pinned to the approved upstream commit.
- DocsGPT API and Celery ingestion worker only.
- Private connection to the existing PostgreSQL/pgvector and Redis services through isolated credentials and Redis databases.
- Persistent source-file volumes required for ingestion.

## Local Contracts

- Do not deploy the DocsGPT frontend or its final-answer generation path.
- Do not expose a host port or attach the API to Dokploy/Traefik.
- Use a dedicated PostgreSQL database and role; never use the Chatwoot application database or role.
- Provision `CREATE EXTENSION vector` in the dedicated DocsGPT database before ingestion; the pgvector image alone does not install it per database.
- Use dedicated Redis logical databases for Celery and cache state.
- Store all secret values only in the deployment platform environment; the Compose file contains required-variable guards only.
- Configure the same high-entropy `DOCSGPT_INTERNAL_KEY` for the API and worker; pinned DocsGPT denies worker index registration when it is absent.
- Require both the shared `DOCSGPT_INTERNAL_KEY` and an independently signed ChatRing-to-DocsGPT service credential for retrieval and mutation operations, scoped to the tenant, knowledge version, content binding, operation, and provider source. Private Docker networking is not authentication.
- Build the approved DocsGPT source commit in CI, functionally test the ChatRing-derived image, and pin `DOCSGPT_IMAGE` to that immutable derived image digest; do not use mutable tags or `latest`.
- Source deletion must remove pgvector data, stored files, the DocsGPT source row, and ingest-progress state. Use only the narrow signed maintenance endpoint for expired idempotency housekeeping; do not enable DocsGPT's broad Celery Beat scheduler.
- Preserve the one-shot root volume initializer; the pinned DocsGPT image runs as non-root UID/GID 994 and cannot write fresh root-owned named volumes otherwise.
- Keep `VECTOR_STORE=pgvector`, local `all-mpnet-base-v2` embeddings, classic retrieval, and GraphRAG disabled.
- Do not expose legacy `POST /api/search` as ChatRing's production retrieval seam. Use the pinned DocsGPT Dispatcher with visible scores through a bounded private endpoint. Hybrid retrieval or reranking requires a fixed-corpus evaluation decision first.

## Verification

- Confirm both containers use the same image digest and approved upstream commit.
- Confirm the API health check passes only on the private Docker network.
- Confirm no service publishes a host port.
- Confirm ingestion creates chunks in the dedicated DocsGPT database.
- Confirm a ChatRing-published version retrieves only source references in its stored manifest.
- Confirm retrieval returns numeric score, score kind and effective configuration, supports zero accepted results, and rejects missing, wrong-tenant and wrong-version service credentials.
- Confirm deletion is idempotent, removes ingest-progress state, and the signed maintenance endpoint rejects altered scope.
