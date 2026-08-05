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
- ChatRing owns account/inbox-scoped source manifests, staged knowledge versions, the single published-version pointer, rollback, and provider-source-to-canonical-source binding. A Firecrawl or DocsGPT completion flag alone is never authority to publish.
- Website ingestion uses Firecrawl map followed by an exact bounded batch scrape of the mapped URLs. Publication requires every normalized mapped URL to have non-empty extracted Markdown in the staged version.
- DocsGPT is a private replaceable execution dependency. Its API key identifies a provider-side retrieval agent for one knowledge version; that secret is encrypted at rest and never exposed by status tasks or logs.
- `ChatRing::AssistantSpike` is a non-production deterministic boundary proof only. It may reuse the CE AgentBot sender contract and normal Message/Conversation/Sidekiq delivery lifecycle, while remaining disabled unless its explicit spike configuration is active.
- Do not import or mirror Enterprise implementations.
- Use installation configuration or the frontend branding helper for product identity instead of scattered hard-coded replacements.

## Work Guidance

- Prefer the smallest upstream-compatible CE patch.
- Keep customer-visible strings in the existing i18n/configuration paths where available.

## Verification

- Exercise login, onboarding, dashboard, inbox, widget, survey, and transactional email surfaces in the deployed image.
- Confirm API, webhook, WebSocket, and message-delivery contracts remain unchanged.
- For Phase 2A, prove map/exact-batch manifest completeness, idempotent document uploads, provider-source binding, atomic publication, rollback, and rejection of retrieval hits outside the published manifest.
- For the Assistant spike, prove idempotent retries, newest-message suppression, pending-to-open human takeover, normal `SendReplyJob` delivery, and identical persisted output in the Inbox and Classic Widget.

## Child DOX Index

- `javascript/AGENTS.md` — frontend branding, entrypoints, widgets, and frontend verification.
