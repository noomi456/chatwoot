# Application Boundary

## Purpose

Own ChatRing's customer- and agent-facing Community Edition application behavior while preserving the proven Chatwoot operational kernel.

## Ownership

- Rails-rendered login, onboarding, Super Admin, email, and layout surfaces.
- Supported CE application behavior and API compatibility.
- Child ownership for frontend runtime and branding helpers under `app/javascript/`.

## Local Contracts

- Customer-visible identity is ChatRing; internal Chatwoot model, route, event, and database contracts remain compatible.
- Phase 1 behavior remains the conventional Chatwoot conversation foundation. Phase 2 control-plane modules may extend it only through ChatRing-owned CE code; external extraction, retrieval and model systems remain replaceable dependencies and may not become conversation or delivery authorities.
- `ChatRing::Knowledge` owns provider-neutral evidence objects and knowledge-provider adapters. Providers return supporting evidence to the future Brain and never create Chatwoot Messages themselves.
- One `ChatRing::Workspace` maps one-to-one to a Chatwoot Account and owns one canonical business Knowledge Base shared by every Assistant and Inbox in that account. Knowledge ownership is never per Inbox.
- The administrator controls content only through Add, row-level Re-run, and Delete. No scheduled Firecrawl crawl/Monitor, user-visible publication/version workflow, or second Update Knowledge action may change the catalog.
- The Webpages input accepts either a complete website or one exact page. Complete websites use Firecrawl Map, pre-scrape filtering of operational, policy, Help/Docs, and Blog routes, and exact batch scrape of the remaining pages as one user Add command. Any excluded page can still be added explicitly through the exact-page input, which uses Firecrawl Scrape directly. An explicit row Re-run always scrapes that page with `maxAge: 0`.
- The Files input sends supported validated documents to Firecrawl Parse. Files and website pages converge into one account Training Materials catalog and one DocsGPT index; Q&A and Images remain later, separate knowledge views.
- DocsGPT is a private replaceable execution dependency. ChatRing uses scoped service authentication and one isolated provider source per hidden account index; provider-side answer Agents and legacy search API keys are not part of the retrieval contract.
- Production evidence must include a finite numeric provider score, score kind, rank, exact hidden-index binding, a verified provider chunk-content hash, canonical source URL and title, retrieved heading path, normalized page heading outline, safe source-derived CTA candidates, and retrieval configuration identity. Reject scoreless, non-finite, hash-mismatched, or off-manifest results and represent insufficient evidence as an empty typed outcome.
- Successful extraction updates that material snapshot and queues exactly one hidden replacement index from all active Training Materials. A manifest digest prevents duplicate builds and prevents an older build from replacing newer user changes.
- Delete tombstones the exact row immediately, so retrieval rejects it before provider cleanup. Re-run preserves the last active snapshot on extraction failure. Deleting the final row returns typed `insufficient_evidence`.
- Hidden provider-index snapshots are immutable and atomically swapped only after ingestion/provenance validation. Keep only the active index and a short-lived retired index; cleanup is an idempotent delayed Sidekiq job, not an hourly lifecycle/lease system.
- Account destruction must retain an independently executable provider tombstone before Workspace records cascade. Inbox destruction must not affect account knowledge.
- `ChatRing::AssistantSpike` is a non-production deterministic boundary proof only. It may reuse the CE AgentBot sender contract and normal Message/Conversation/Sidekiq delivery lifecycle, while remaining disabled unless its explicit spike configuration is active.
- Do not import or mirror Enterprise implementations.
- Use installation configuration or the frontend branding helper for product identity instead of scattered hard-coded replacements.

## Work Guidance

- Prefer the smallest upstream-compatible CE patch.
- Keep customer-visible strings in the existing i18n/configuration paths where available.

## Verification

- Exercise login, onboarding, dashboard, inbox, widget, survey, and transactional email surfaces in the deployed image.
- Confirm API, webhook, WebSocket, and message-delivery contracts remain unchanged.
- For Phase 2A, prove account ownership and cross-tenant isolation; two-Inbox sharing; Website A plus Website B plus files; direct-page scrape; fresh row Re-run; immediate Delete; stale-index rejection; partial page success; truthful Training Materials state; real PDF/DOCX parsing; scored retrieval/abstention; authenticated provider calls; and idempotent obsolete-index cleanup.
- For the Assistant spike, prove idempotent retries, newest-message suppression, pending-to-open human takeover, normal `SendReplyJob` delivery, and identical persisted output in the Inbox and Classic Widget.

## Child DOX Index

- `javascript/AGENTS.md` — frontend branding, entrypoints, widgets, and frontend verification.
