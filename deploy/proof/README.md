# Isolated Web Widget production proof

This harness exercises the server-side v2.2 Section 13 Web Widget path against
separate Rails, Sidekiq, PostgreSQL, Redis, DocsGPT API/worker and provider-proxy
processes. It never connects to staging data and publishes only a loopback Rails
port. The connected-browser ActionCable/rendering lane remains a separate required
release-gate check; a successful driver run alone is not full Section 13 proof.

The source image must be the immutable image built from the exact reviewed commit.
`Dockerfile` derives a clearly labelled proof-only image and changes only the
compile-time public-response gate. External-runtime mode remains false. The proof
image must never be promoted or deployed.

Create a root-owned `0600` environment file from `.env.example`. Generate new
database, Redis, Rails, encryption and DocsGPT secrets for every run. Copy only the
approved development OpenAI key from the secret store; do not print or commit it.
Pin all source images by digest.

Run from the repository root:

```sh
deploy/proof/run.sh /root/chatring-proof.env \
  ghcr.io/noomi456/chatring-conversation-core@sha256:SOURCE_DIGEST \
  SOURCE_COMMIT PROOF_COMMIT
```

The cleanup trap removes all proof containers, networks and volumes. The JSON result
records grounded reply/citation persistence and refresh, native handoff, native
template precedence, concurrency, human takeover, AI-first serialization, provider
recovery, unbound Widget behavior and KnowledgeIndex pin protection. Staging's public
gate remains closed.
