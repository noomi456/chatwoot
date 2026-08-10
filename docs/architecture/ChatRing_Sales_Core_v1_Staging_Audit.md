# ChatRing Sales Core v1 Staging Audit

## Decision

The staged direction is recommended.

Sales Core v1 should ship before AI Navigator and Microsites.

## Why

The current ChatRing Knowledge path stores and uploads markdown text. It does not yet provide a first-class website-image catalog, media upload/review UI, image retrieval, structured visual entities, or a safe visual-artifact pipeline.

AI Navigator and Microsites therefore have real prerequisites that are separate from reliable chat, Playbooks, native Tools and human voice.

## Sales Core v1

- native Chatwoot lifecycle and Automation completion
- shared Brain and text Business Knowledge
- Inbox-scoped Tool policies used by free-form and Playbook modes
- Inbox-owned phrase-triggered Playbooks
- Engagement starter pills in the current Chatwoot Website Widget
- native actions and omni-channel certification
- RealtimeKit Website calls and one PSTN provider
- complete administration and production proof

## Later Visual Sales stage

- website image extraction and administrator uploads
- media approval/description/disablement
- source-linked Sales Entities
- AI Navigator
- explicit Playbook buttons
- Microsite generation, rendering and sharing
- embedded calendar and approved Website host actions

## Key model correction

Playbooks are Inbox-owned in Sales Core v1. Tool definitions remain shared, but Tool availability, configuration and rendering are Inbox-specific. Free-form Brain and Playbooks use the same Tool system; Playbooks receive a narrower allowlist.

Engagements remain Website starter pills only. They do not store Playbook IDs or Tool actions.

## Verification record — 2026-08-10

This staging decision was rechecked before adoption against the current sources below.

```text
ChatRing / Chatwoot authority
repository: noomi456/chatwoot
foundation merge: 401a33f35a4edda131edf51ed829a6b2fbbcec61

cqalerts3-code donor
repository: cqalerts3-code/bottree-dark-custom-bots-f6b3cac4
commit: 99d37267d01997ca23ae7ff776ca11ee319bdb6b
```

Verified current-source facts:

- `KnowledgeDocument` stores Markdown and DocsGPT upload sends `text/markdown`; no first-class Website media catalog, Sales Entity, AI Navigator or Microsite runtime exists.
- Native Chatwoot owns Contacts, Conversations, Messages, AgentBot assignment, Automations, Campaigns, Widget delivery and the existing RealtimeKit/Dyte human-call seam.
- No implemented `BrainInvocation`, `ToolExecution`, Inbox Playbook, Engagement, Sales Entity or Microsite ChatRing model exists yet; every one requires a fresh native-first classification before implementation.
- The cqalerts3-code Engagement surface stores ordinary starter labels/prompts and page rules. Its Playbook surface separately stores phrase triggers, guided content and execution tools. Its heuristic runtime and separate Supabase/voice architecture remain donor examples only.
- Expertise.ai public documentation likewise distinguishes static conversation starters from trigger/step/branch/Tool Playbooks. Its personalized Microsites require AI Nav plus images, links, interactive tools and embedded scheduling, confirming that visual sales has separate prerequisites.

This is static source/product verification, not runtime certification. RealtimeKit configuration, the selected PSTN provider, enabled channels and every future native seam still require deployed-state audit in the implementation PR that uses them.
