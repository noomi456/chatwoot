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
- hardened native RealtimeKit Website calls and Twilio PSTN Voice
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
audited upstream develop: a4eae9710ab49e7dc98d64a7e713fd1f77c451f8

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
- Web Widget, Email, WhatsApp Cloud, Facebook Messenger, Twilio SMS and Instagram have native CE ingress, Contact/Conversation/Message and provider-delivery paths. ChatRing needs narrow scheduling, eligibility, output and certification adapters—not provider transports.
- Twilio SMS is native CE, but its current inbound and delivery-status controllers do not validate `X-Twilio-Signature`; durable SID deduplication, monotonic status, bounded MMS fetch and STOP/consent enforcement are also required before Sales certification.
- Facebook and Instagram native senders may apply Meta's `HUMAN_AGENT` tag globally. AI-originated Messages must never receive that tag.
- Cloudflare RealtimeKit is a genuine native CE integration that persists an ordinary `integrations/dyte` Message and issues participant tokens. Its current Widget controller can resolve a meeting Message by Inbox rather than by the authenticated contact's conversations, so authorization, credential encryption, timeouts, participant roles and concurrent participant state are release blockers before reuse.
- Native RealtimeKit meeting creation directly persists the agent integration Message and does not currently pass through ChatRing's managed-conversation human-takeover boundary. Agent call start/accept must invoke native `Conversations::AssignmentService` under the existing serialization order and win safely against a pending AITurn.
- Twilio PSTN Voice and WhatsApp Calling backends are Enterprise-only despite CE schema/UI fragments. They cannot be imported. Twilio PSTN Voice is a separately bounded, independently implemented CE capability that remains subordinate to native Chatwoot ownership.
- The donor `IncomingCallBanner` is useful visual reference. Its separate Supabase/Deepgram/Gemini WebSocket voice server is AI voice architecture and must not be copied into the human-call runtime.

Exact audited native/donor seams:

| Capability | Current authority paths |
|---|---|
| Shared native delivery | `app/models/message.rb`, `app/jobs/send_reply_job.rb`, channel-native send services |
| Web Widget | `app/controllers/api/v1/widget/messages_controller.rb`, `app/models/channel/web_widget.rb`, `app/listeners/action_cable_listener.rb` |
| Email | `app/mailboxes/application_mailbox.rb`, `app/mailboxes/reply_mailbox.rb`, `app/mailboxes/imap/imap_mailbox.rb`, `app/services/email/send_on_email_service.rb` |
| WhatsApp Cloud | `app/controllers/webhooks/whatsapp_controller.rb`, `app/jobs/webhooks/whatsapp_events_job.rb`, `app/services/whatsapp/incoming_message_base_service.rb`, `app/services/whatsapp/send_on_whatsapp_service.rb` |
| Facebook Messenger | `config/initializers/facebook_messenger.rb`, `app/jobs/webhooks/facebook_events_job.rb`, `app/builders/messages/facebook/message_builder.rb`, `app/services/facebook/send_on_facebook_service.rb` |
| Twilio SMS | `app/controllers/twilio/callback_controller.rb`, `app/services/twilio/incoming_message_service.rb`, `app/services/twilio/send_on_twilio_service.rb`, `app/services/twilio/delivery_status_service.rb` |
| Instagram | `app/controllers/webhooks/instagram_controller.rb`, `app/jobs/webhooks/instagram_events_job.rb`, `app/builders/messages/instagram/`, `app/services/instagram/` |
| RealtimeKit | `config/integration/apps.yml`, `lib/dyte.rb`, `lib/integrations/dyte/processor_service.rb`, account/widget Dyte controllers and native integration-Message renderers |
| Twilio Voice edition boundary | CE schema/channel fragments plus Enterprise-only runtime under `enterprise/app/controllers/twilio/voice_controller.rb`, `enterprise/app/services/voice/` and `enterprise/app/models/call.rb` |
| cqalerts3-code donor | `src/pages/dashboard/Engagement.tsx`, `src/pages/dashboard/Playbooks.tsx`, `src/components/voice/IncomingCallBanner.tsx`, `voice-server/README.md` at the pinned donor commit |

Locked v1 choices are Web Widget first; Twilio SMS, Email, WhatsApp Cloud, Facebook Messenger and Instagram when available; Cloudflare RealtimeKit for Website human calls; and Twilio for PSTN Voice. This is static source/product verification, not runtime certification. Deployed credentials, Meta app approval, phone-number capabilities and every provider path still require runtime audit in the implementation PR that uses them.
