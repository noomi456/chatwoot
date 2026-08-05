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
- Use dedicated Redis logical databases for Celery and cache state.
- Store all secret values only in the deployment platform environment; the Compose file contains required-variable guards only.
- Pin `DOCSGPT_IMAGE` to the verified upstream release image; do not use `latest`.
- Keep `VECTOR_STORE=pgvector`, local `all-mpnet-base-v2` embeddings, classic retrieval, and GraphRAG disabled.

## Verification

- Confirm both containers use the same image digest and approved upstream commit.
- Confirm the API health check passes only on the private Docker network.
- Confirm no service publishes a host port.
- Confirm ingestion creates chunks in the dedicated DocsGPT database.
- Confirm a ChatRing-published version retrieves only source references in its stored manifest.
