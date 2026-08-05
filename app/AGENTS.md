# Application Boundary

## Purpose

Own ChatRing's customer- and agent-facing Community Edition application behavior while preserving the proven Chatwoot operational kernel.

## Ownership

- Rails-rendered login, onboarding, Super Admin, email, and layout surfaces.
- Supported CE application behavior and API compatibility.
- Child ownership for frontend runtime and branding helpers under `app/javascript/`.

## Local Contracts

- Customer-visible identity is ChatRing; internal Chatwoot model, route, event, and database contracts remain compatible.
- Brain/RAG, AI Navigator, microsites, Voice AI, Playbooks, and Skills are not implemented in Phase 1 application code.
- Do not import or mirror Enterprise implementations.
- Use installation configuration or the frontend branding helper for product identity instead of scattered hard-coded replacements.

## Work Guidance

- Prefer the smallest upstream-compatible CE patch.
- Keep customer-visible strings in the existing i18n/configuration paths where available.

## Verification

- Exercise login, onboarding, dashboard, inbox, widget, survey, and transactional email surfaces in the deployed image.
- Confirm API, webhook, WebSocket, and message-delivery contracts remain unchanged.

## Child DOX Index

- `javascript/AGENTS.md` — frontend branding, entrypoints, widgets, and frontend verification.
