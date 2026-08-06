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
- Website ingestion uses one Firecrawl map followed by an exact batch scrape of only policy-accepted mapped URLs. Excluded routes remain in the manifest with a reason and must not consume scrape credits.
- Before provider upload, enforce a persisted source policy covering discovery-ceiling saturation, allowed origins/paths, successful status and content type, canonical aliases, meaningful content, soft-404/login detection, language, corpus size, exact-content deduplication and source authority.
- DocsGPT is a private replaceable execution dependency. ChatRing uses scoped service authentication and one isolated provider source per knowledge version; provider-side answer Agents and legacy search API keys are not part of the retrieval contract.
- Production evidence must include numeric provider score, score kind, rank, exact source/version binding and retrieval configuration identity. Reject scoreless or off-manifest results and represent insufficient evidence as an empty typed outcome.
- Only one worker may claim a knowledge-version build. Publication and rollback require validation and append-only publication events; provider cleanup failures remain durable and retryable.
- `ChatRing::AssistantSpike` is a non-production deterministic boundary proof only. It may reuse the CE AgentBot sender contract and normal Message/Conversation/Sidekiq delivery lifecycle, while remaining disabled unless its explicit spike configuration is active.
- Do not import or mirror Enterprise implementations.
- Use installation configuration or the frontend branding helper for product identity instead of scattered hard-coded replacements.

## Work Guidance

- Prefer the smallest upstream-compatible CE patch.
- Keep customer-visible strings in the existing i18n/configuration paths where available.

## Verification

- Exercise login, onboarding, dashboard, inbox, widget, survey, and transactional email surfaces in the deployed image.
- Confirm API, webhook, WebSocket, and message-delivery contracts remain unchanged.
- For Phase 2A, prove discovery saturation and origin rejection, page-quality/source-authority rules, manifest reconciliation, scored retrieval, unsupported-query abstention, concurrent build claims, authenticated provider calls, validated publication/rollback, durable cleanup, and rejection of hits outside the published manifest.
- For the Assistant spike, prove idempotent retries, newest-message suppression, pending-to-open human takeover, normal `SendReplyJob` delivery, and identical persisted output in the Inbox and Classic Widget.

## Child DOX Index

- `javascript/AGENTS.md` — frontend branding, entrypoints, widgets, and frontend verification.
