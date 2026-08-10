# ChatRing Sales Core v1 Production Foundation - Staged AI Navigator Direction

## Purpose

PR #17 is merged and remains the native-lifecycle remediation package. It corrected the authority boundary, removed the parallel responder lifecycle, retained native AgentBot ownership, assignment, handoff, Message persistence and delivery, and kept public AI disabled. It is not the complete ChatRing Sales product.

This document now separates two complete product stages instead of forcing the entire visual-sales stack into the first production release.

## Stage A - ChatRing Sales Core v1

The immediate production objective is:

> **Build a production-ready sales AI layer across Chatwoot's native omnichannel Inbox foundation using the current Chatwoot Website Widget, one shared Brain, one text Business Knowledge Base, Inbox-owned Playbooks, Inbox-scoped Tools, Website Engagement starter pills, native Chatwoot actions, productive Automation coexistence, human voice/calls, and complete administration.**

Sales Core v1 is a complete commercial product. It must not be described as a prototype or as a temporary RAG bot.

It includes:

```text
native Chatwoot lifecycle and ownership
+
one shared sales Brain across the approved Inbox set
+
one canonical text Business Knowledge Base
+
correct Contact / Conversation context and speaker provenance
+
Inbox-owned phrase-triggered Playbooks
+
Tools available to both free-form Brain and Playbooks
+
Inbox-specific Tool availability and rendering policy
+
Engagement conversation-starter pills in the native Website Widget
+
native Chatwoot actions and productive Automation coexistence
+
human-to-human Website voice through native Cloudflare RealtimeKit
+
Twilio PSTN Voice through one independently audited CE adapter
+
sales-first administration, customization, analytics and navigation
+
production durability, idempotency and tenant isolation
```

Sales Core v1 does **not** require:

```text
AI Navigator
media-aware Knowledge ingestion
website-image management
structured Sales Entities for visual generation
Microsite generation or sharing
embedded visual calendars inside Microsites
website add-to-cart actions
AI voice receptionist
external business-event outbound automation
Shopify / WooCommerce order tracking
```

## Stage B - AI Navigator and Visual Sales

After Sales Core v1 is stable in production, a separately gated Visual Sales stage adds:

```text
media-aware Knowledge and approved website images
structured, source-linked Sales Entities
AI Navigator
explicit AI Navigator Playbook buttons
Microsite generation, validation and rendering
shareable Microsite snapshots
embedded booking/calendar components
approved Website host actions such as add to cart
visual-sales administration and analytics
```

This is not architecture debt. It is a separate product capability with different data, security, rendering and administration requirements.

## Locked Sales Core v1 channel and call scope — 2026-08-10

The approved first-release provider boundary is:

```text
Text/channel certification
1. Web Widget
2. Twilio SMS, Email, WhatsApp Cloud, Facebook Messenger and Instagram are then
   certified independently according to real provider/compliance readiness;
   Instagram requires a deployed Meta app and Inbox

Human calls
1. Cloudflare RealtimeKit through Chatwoot's native Website integration
2. Twilio for PSTN Voice
```

Twilio is the selected v1 SMS/PSTN provider. Telnyx is not part of v1. Twilio WhatsApp,
Bandwidth SMS, WhatsApp default/non-Cloud, API, Telegram, LINE, TikTok and X/Twitter are
not silently included merely because Chatwoot contains a model or provider path. They
require a later written scope decision and their own native-path certification.

Sales Core v1 therefore requires a configured WhatsApp Cloud Inbox before claiming
WhatsApp support. An existing default/non-Cloud WhatsApp Inbox remains native Chatwoot
functionality but is outside the v1 AI certification boundary unless a later written
decision replaces the provider scope after auditing that actual deployed path.

"Available" means the deployed CE runtime has the required provider credentials, app
approval, phone number/capabilities and feature configuration. Source availability alone
does not make a channel release-ready.

The source-verified classification is:

| Capability | Classification | Governing implementation boundary |
|---|---|---|
| Web Widget | NATIVE + EXTEND | Reuse native Widget ingress, Conversation/Message and ActionCable delivery; extend the already-scoped scheduling/serialization seam. |
| Twilio SMS | NATIVE + EXTEND | Reuse `Channel::TwilioSms`, native callback/job/services and `SendReplyJob`; harden provider authentication, deduplication, status, media and consent before AI certification. |
| Email | NATIVE + EXTEND/ADAPT | Reuse ActionMailbox/IMAP, native threading and Email delivery; add only channel eligibility, bounded context and email-safe output. |
| WhatsApp Cloud | NATIVE + EXTEND/ADAPT | Reuse Meta verification, native deduplication, Message persistence, templates/interactivity and delivery; enforce session/provider limits server-side. |
| Facebook Messenger | NATIVE + EXTEND/ADAPT | Reuse native Messenger ingress/delivery; AI must fail closed outside the allowed window and never use the `HUMAN_AGENT` tag. |
| Instagram | NATIVE + EXTEND/ADAPT when deployed | Reuse the configured direct or Facebook-linked native path; AI must never use the `HUMAN_AGENT` tag. |
| Cloudflare RealtimeKit | NATIVE + bounded EXTEND/ADAPT | Reuse native meeting, integration Message and participant-token flow after authorization, credential, timeout, role and takeover hardening. |
| Twilio PSTN Voice | ADAPT + NEW missing CE capability | Independently implement only the absent provider/call boundary from public Twilio contracts; preserve native Chatwoot Contact, Conversation, Message and assignment authority. |

## Locked development model, human-request and appointment behavior — 2026-08-10

Development and pre-production testing use `gpt-5.4`. The designated testing
credential lives only in the deployment secret store. It is never written to this
document, Git, Assistant/Draft/Version records, logs, prompts, fixtures or UI responses.
New Assistant drafts use `gpt-5.4`; a previously published legacy version may preserve
only its exact historical model until republished under the supported-model contract.

Chatwoot remains authoritative for human availability and transfer. The native inputs are:

```text
Inbox#out_of_office? / Inbox working hours
+ Inbox#available_agents
+ native Inbox membership, team and assignment-capacity policy
+ native Conversation ownership/assignment state
```

ChatRing must not create a second presence, roster, availability or assignment model.
An hours-only check is insufficient. A visitor may be told that a transfer completed
only after the guarded native Chatwoot path records the corresponding human assignment.

For a free-form explicit human request:

```text
inside native Inbox hours
+ at least one eligible online human
        ->
guarded native handoff / assignment
        ->
cancel or supersede the pending AI turn
        ->
human continues in the same native Conversation

outside hours OR no eligible online human
        ->
state the current unavailability truthfully
        ->
offer an appointment, callback request or approved calendar link
        ->
preserve the request in native Chatwoot Messages / approved Contact fields / private note
```

Availability is rechecked inside the final Conversation serialization boundary. A stale
precheck never authorizes a transfer claim. Native `Conversation#bot_handoff!`,
`Conversations::AssignmentService` and Chatwoot auto-assignment remain the mutation
authorities; ChatRing contributes only policy, guarded orchestration and audit.

An active Playbook normally continues its published goal, required questions, branches,
lead fields and next action. A side question is answered through the shared Business
Knowledge path, after which the exact pending Playbook step resumes. A repeated explicit
human request overrides the guided step: transfer only when native hours and eligible
human availability both pass; otherwise request any information required for follow-up
and offer the configured appointment/callback path.

Appointment intent is channel-neutral:

```text
Brain / Playbook -> request_appointment
        ->
Inbox capability renderer
        ->
embedded calendar only on an explicitly certified surface
OR approved calendar link
OR approved appointment-request form
```

The configured URL/provider and renderer belong to the Inbox Tool policy, not Assistant
prompt prose. The cqalerts3-code calendar URL fields, Playbook editor affordances,
`@share_booking_link` UX and form/modal patterns are product donors only. No donor
storage, Supabase orchestration, fixed URL, credential or React component is copied until
file-level license/provenance and native-boundary review permits it. Current source has
no native general calendar-booking runtime, so the bounded Tool configuration/renderer
is genuinely missing; all resulting customer/lead state remains native Chatwoot state.

The sequencing rule is:

```text
complete the native sales conversation foundation first
        ->
release and prove Sales Core v1
        ->
add media and visual artifacts
        ->
release AI Navigator / Visual Sales separately
```

## Product distinctions that must remain exact

```text
Engagement
= a Website conversation-starter pill that submits ordinary customer text

Playbook
= an Inbox-owned guided conversation triggered by a customer phrase
  or, later, an explicit AI Navigator Playbook button

Tool
= a typed capability available to the free-form Brain and/or a Playbook,
  subject to the current Inbox policy and renderer

Campaign
= native Chatwoot proactive/broadcast outreach

Automation
= native Chatwoot event-condition-action behavior

AI Navigator
= a later rich Website presentation surface

Microsite
= a later validated visual artifact rendered by AI Navigator
```

Do not merge these concepts in models, APIs, UI labels, prompts or documentation.

The governing engineering rule remains:

```text
AUDIT CHATWOOT FIRST
        ->
      REUSE
        ->
      EXTEND
        ->
       ADAPT
        ->
BUILD ONLY WHAT IS GENUINELY MISSING
```

The source roles remain:

```text
NATIVE AUTHORITY
-> deployed Chatwoot source/runtime and official Chatwoot documentation

PRODUCT / UX DONORS
-> Expertise.ai public product and documentation
-> cqalerts3-code donor repository

IMPLEMENTATION AUTHORITY
-> the audited Chatwoot-native ChatRing architecture in this repository
```

Expertise.ai and cqalerts3-code may be studied for product contracts, interaction models, schemas, validation ideas and UI references. A donor file may be clean-copied only when a file-level license/provenance, tenancy, security and native-boundary audit proves that it is implementation-neutral and can be rewired to native Chatwoot authority. Their storage, transport, orchestration, provider credentials, conversation/session state, Supabase tenancy and AI-voice architecture must not be copied into Chatwoot merely because they exist there.

The governing production rule remains:

```text
NO ARCHITECTURE-CRITICAL "WE WILL GENERALIZE THIS LATER"
```

This means Sales Core v1 must freeze the native authority, Brain/context, Tool policy, Inbox-specific Playbook, Automation arbitration, durability and channel-adapter contracts. It does **not** mean implementing AI Navigator, image extraction and Microsites before the first complete release.

---

# 1. Audit native Chatwoot before implementing each base component

Before creating or changing a ChatRing subsystem, inspect:

- the merged PR #17 implementation;
- the pinned Chatwoot CE source;
- relevant current upstream Chatwoot implementation;
- official current Chatwoot documentation;
- the actual deployed edition and feature flags;
- the real configured channel/provider path;
- Expertise.ai public product/documentation for the specific product contract being adapted;
- and the exact cqalerts3-code files used only as donor references.

Audit at least:

```text
Contact
ContactInbox
identifiers/channel identities
Web Widget setUser
HMAC identity validation
Contact reconciliation
custom/additional attributes
labels
companies
notes

Conversation lifecycle
Message lifecycle
attachments/media
structured Message content types
AgentBot lifecycle
assignment/handoff
Message Templates
working hours / out-of-office / greeting / email collection

Automations
Automation conditions
Automation Actions
Automation provenance
Automation recursion protection
sync/async event dispatch ordering

Campaigns
Macros
Canned Responses

Account/Public APIs
Client APIs
Webhooks
Widget SDK / JavaScript API

Website / Web Widget
Email
WhatsApp Cloud
WhatsApp non-Cloud/default provider
Twilio WhatsApp when enabled
Twilio SMS
Bandwidth/native SMS when enabled
Facebook Messenger
Instagram
Telegram
LINE
TikTok
X/Twitter when enabled
API Channel

Cloudflare RealtimeKit Website meeting integration
native Voice/Call models and edition restrictions
agent presence and Inbox membership
native call assignment/routing behavior

native structured cards/forms/articles/integration Messages
native calendar/integration seams, if any
native reports and dashboard surfaces

official AI Actions product contract
official Captain/Custom Tools product contract for comparison only
native integrations available in the deployed edition/version
```

For the staged Sales product layer, separately study and classify:

```text
Engagement conversation-starter pills

phrase-triggered Playbooks

explicit Playbook buttons near the AI Navigator input

Playbook steps, branches, validation and Playbook-to-Playbook transitions

AI Navigator / rich Website experience

Microsite generation, renderer, strict component schema and CTA policy

shareable Microsite snapshots

booking and calendar surfaces

Website human call invitation / request UI

selected PSTN provider: Twilio

sales-first navigation, terminology and analytics
```

For each desired ChatRing capability classify it as:

```text
NATIVE
Use Chatwoot unchanged.

EXTEND
Use the native model/service/event lifecycle with a narrow seam.

ADAPT
Independently implement a proven product contract or interaction pattern
from public documentation/donor references because it is not available
in the deployed Chatwoot edition.

NEW
The capability is genuinely absent and requires a ChatRing-owned component.
```

Do not design a new ChatRing subsystem before completing this classification.

The audit must identify the exact native model, callback, service, API, content type or provider path that will be reused. Statements such as "Chatwoot supports cards," "Chatwoot supports campaigns," or "Chatwoot supports voice" are insufficient without proving the exact deployed path and edition.

When donor sources conflict with Chatwoot or with one another:

```text
deployed Chatwoot source/runtime
→ wins for native ownership and implementation

approved ChatRing product direction
→ wins for scope

Expertise / cqalerts donors
→ remain references, never authority
```

Every implementation PR must state:

```text
native Chatwoot authority
→ native seam reused
→ donor concept studied, if any
→ NATIVE / EXTEND / ADAPT / NEW classification
→ minimal ChatRing extension
→ native Message/action/assignment/delivery path
```

---

# 2. Native ownership boundary is final

Chatwoot remains operational authority in both stages.

Chatwoot owns:

```text
Account / workspace tenancy

Inbox and channel/provider configuration

Contact
ContactInbox
channel identity
Widget HMAC identity validation
Contact reconciliation

Conversation
Message
attachments
native structured Message records

AgentBot integration identity
AgentBotInbox connection

agent/team membership
agent availability
assignment
human takeover
handoff
Conversation status

Message Templates
working hours
out-of-office
greeting
email collection

Automations
Automation conditions/actions
Automation provenance

Campaigns

provider/channel ingress
provider/channel delivery
delivery status

native APIs
native Webhooks

Cloudflare RealtimeKit integration where available
native Call lifecycle where available in the deployed edition
```

ChatRing must not recreate those systems.

## Sales Core v1 ownership

ChatRing owns only the sales-AI components that Chatwoot does not provide:

```text
Assistant configuration/versioning

normalized BrainInvocation

AITurn computation/audit

context policy/projection

Business Knowledge retrieval/evidence

AI reasoning and typed decisions

Tool registry and Inbox Tool policy

Tool authorization/execution/audit

AI/native-effect arbitration

Website Engagement starter configuration

InboxPlaybook definitions and immutable versions

Playbook execution state linked to native Conversation

Website visitor call-request coordination where Chatwoot lacks it

one Twilio PSTN Voice adapter where the audited CE deployment is insufficient

sales administration and ChatRing-specific conversion analytics

AI audit/idempotency
```

## Later Visual Sales ownership

The separately gated AI Navigator stage may add:

```text
KnowledgeMediaAsset and media review state

source-linked structured Sales Entities

AI Navigator configuration/rendering contract

Microsite artifact generation, validation, storage and sharing

visual Website Tool renderers

booking/calendar presentation integration

approved Website host-action adapters
```

These later components remain subordinate to the same native Contact, Conversation, Message, assignment and delivery authority.

The primary authority flow remains:

```text
native Chatwoot state/lifecycle
          ->
ChatRing sales reasoning / guided experience
          ->
authorized native Chatwoot Messages/actions/assignment
          ->
native delivery or audited Website/call presentation
```

Do not introduce:

```text
second Conversation store
second Message store
second Contact/customer model
second channel-identity model
second agent-presence model
second assignment state machine
second handoff meaning
second Automation engine
second Campaign engine
second generic operational workflow engine
second native channel transport
second delivery system
```

An InboxPlaybook is not a replacement operational workflow engine. It is a bounded, multi-turn AI conversation flow linked to one native Chatwoot Conversation. Operational effects requested by a Playbook still execute through native Chatwoot services.

A future Microsite is not a second website CMS or Conversation. It is a validated visual artifact linked to native Chatwoot records.

---

# 3. Build the shared Sales Brain kernel now

Do not finish Sales Core v1 with a Brain that fundamentally means:

```text
AITurn.trigger_message
        ->
prompt
        ->
LLM
```

Implement one normalized, channel-neutral Brain contract now.

Conceptually:

```text
BrainInvocation
├── assistant_version
├── trigger
│   ├── kind
│   ├── source
│   └── normalized payload
├── inbox_context
│   ├── inbox_id
│   ├── channel/provider facts
│   └── capability profile
├── model_context
├── trusted_runtime_context
├── knowledge_evidence
├── active_playbook_context, optional
├── available_tools
└── runtime_policy
```

The Brain is shared across:

```text
free-form customer questions

active Playbook turns

Playbook side questions

human-call offers or escalation decisions

explicit human requests and appointment decisions
```

The Brain is not split into WebsiteBrain, WhatsAppBrain, EmailBrain or PlaybookBrain.

## 3.1 Tools are available in free-form and Playbook modes

The same typed Tool registry serves both paths.

```text
Free-form Brain available Tools
=
Assistant policy
INTERSECT current Inbox Tool policy
INTERSECT current native/channel capability
INTERSECT runtime authorization
```

```text
Active Playbook available Tools
=
free-form available Tools
INTERSECT the published InboxPlaybookVersion Tool allowlist
INTERSECT the current step Tool allowlist
```

The model must never be shown a Tool that cannot be authorized or rendered in the current Inbox.

## 3.2 Typed Brain outcome

A Brain result may contain:

```text
customer-facing text

zero or more typed Tool requests

Playbook control
- continue
- pause for side question
- stop
- transition to an allowed next Playbook

human escalation / call offer

no action
```

The Brain does not emit:

```text
arbitrary HTML
arbitrary JavaScript
provider credentials
raw Chatwoot mutations
unvalidated URLs
channel-specific payload JSON
```

Application code validates and executes every Tool and native effect.

## 3.3 Presentation is not Brain logic

The Brain requests semantic capabilities such as:

```text
show_options
show_contact_form
request_appointment
request_human_call
```

The current Inbox renderer chooses the supported representation.

Examples:

```text
Website Widget
-> native input_select / form / card / link / call CTA

WhatsApp or social messaging
-> audited native interactive form when supported
-> otherwise numbered text or approved link fallback

Email
-> ordinary text, approved links or a concise structured question
```

Provider-specific rendering does not belong in the Assistant prompt or Playbook prose.

## 3.4 Visual tools are deferred without changing the kernel

The later AI Navigator phase may register additional Tools such as:

```text
generate_microsite
show_microsite
share_microsite
website_add_to_cart
```

Adding these Tools must not change BrainInvocation, Contact authority, Playbook execution or native Chatwoot commit rules.

---

# 4. AITurn, BrainInvocation, InboxPlaybookExecution and ToolExecution are separate concepts

Keep persistence responsibilities explicit.

## 4.1 AITurn

`ChatRing::AiTurn` remains the durable computation/audit record for one qualifying incoming customer Message.

It owns:

```text
trigger Message reference
Assistant and immutable version
Inbox/binding version
execution state
attempts
deadline
Knowledge evidence references
decision and failure state
customer-effect ledger relationship
```

It does not own Conversation status, assignment or delivery.

## 4.2 BrainInvocation

`BrainInvocation` is an immutable in-memory/value contract built from authoritative state.

```text
incoming native Message
        ->
AITurn
        ->
InboundInvocationBuilder
        ->
BrainInvocation
        ->
shared Brain
```

The Brain does not accept an ActiveRecord `AiTurn` as its fundamental API.

## 4.3 InboxPlaybookExecution

An InboxPlaybookExecution is durable state for a guided conversation spanning multiple native customer Messages.

```text
Conversation
+ InboxPlaybookVersion
+ current step
+ collected fields
+ pending question
+ transition history
+ status
```

It does not duplicate the native transcript. Every customer and AI/human utterance remains a Chatwoot Message.

At most one active InboxPlaybookExecution may control a Conversation.

## 4.4 ToolExecution

Each Tool request creates or reuses an auditable ToolExecution when the operation is not purely local and side-effect-free.

It records:

```text
AITurn / PlaybookExecution
ToolDefinition
Inbox Tool policy version
validated arguments
authorization result
renderer/executor selected
idempotency key
result or failure
```

Do not store credentials or unnecessary PII in ToolExecution.

## 4.5 InboxCapabilityProfile

The runtime derives an InboxCapabilityProfile from the exact native Inbox/channel/provider configuration.

It describes facts such as:

```text
structured options supported
forms supported
cards/media supported
approved link rendering
human-call CTA supported
booking-link rendering
message-length guidance
provider template/session restrictions
```

It is runtime capability data, not another channel transport.

## 4.6 Later visual artifacts

The AI Navigator phase may introduce a separate immutable visual-artifact record. It must not be added to AITurn or PlaybookExecution as a competing lifecycle.

---

# 5. Complete the Chatwoot-native context layer

Do not leave native context assembly as scattered prompt-building logic.

Create one reusable Chatwoot-context resolution/projection layer responsible for:

```text
Conversation

Inbox/channel metadata

Contact

ContactInbox

verified/identified state

selected labels

selected custom/additional attributes

company/account context where approved

native Conversation state

normalized Message history

speaker provenance

current Website page/referrer/UTM where available and approved

active PlaybookExecution state

human call/meeting history where native data exists

future approved visual-artifact references only when Visual Sales is enabled
```

The context resolver understands native Chatwoot data.

A separate context policy determines what becomes model-visible.

## Required speaker provenance

At minimum distinguish:

```text
customer
human_agent
managed_ai
native_template
automation
external_bot_or_system
playbook_generated_ai
```

Playbook-generated AI remains a managed ChatRing AI Message, but its Playbook provenance must be auditable.

Do not classify every outgoing Message as AI.

Automation-generated Messages must retain Automation provenance.

Native templates must retain template provenance.

Human replies must remain human replies.

External/system bot messages must not be presented as ChatRing's previous statements.

Private notes remain excluded from customer-facing model history by default.

---

# 6. Contact identity remains native; authorization remains server-side

Do not build parallel customer identity.

Use:

```text
Chatwoot Contact
+
ContactInbox
+
native channel identity
```

For Web Widget:

```text
setUser(identifier)
        ↓
native HMAC validation
        ↓
Chatwoot Contact
        ↓
ContactInbox
        ↓
trusted runtime identity
```

ChatRing consumes this trust result.

ChatRing does not create a second login/authentication system.

## Contact context policy

Implement a reusable allowlisted projection mechanism.

It must be capable of exposing selected fields such as:

```text
customer type
language
lead stage
plan/tier
region
company
selected labels
selected custom attributes
sales qualification fields
```

when explicitly authorized.

It must not automatically expose:

```text
name
email
phone
identifier
all custom attributes
all notes
all internal metadata
```

merely because Chatwoot stores them.

The runtime may use native Contact identity for dedupe, routing, call authorization and field updates without exposing it to the model.

Lead data collected by a Playbook must be written to approved native Contact attributes/notes through authorized native tools rather than trapped only inside hidden Playbook state.

---

# 7. One text Business Knowledge Base now; media-aware Knowledge later

Continue the current account-owned Knowledge/Retriever architecture for Sales Core v1.

The Workspace/Chatwoot Account owns one canonical Business Knowledge Base:

```text
one Workspace / Account
        ->
one Business Knowledge Base
        ->
all approved Assistants / Inboxes
        ->
free-form answers + Playbook side questions
```

Playbooks do not receive copied Knowledge Bases merely because they belong to different Inboxes.

Knowledge Scope may still restrict an Assistant or Inbox to approved source subsets.

The Brain receives relevant evidence, not an entire Knowledge Base dump.

## 7.1 Current implemented boundary is text/markdown

The current ChatRing KnowledgeDocument and DocsGPT path are text oriented:

```text
website/file extraction
        ->
KnowledgeDocument.markdown
        ->
text/markdown upload
        ->
markdown chunking and scored retrieval
```

Current Sales Core v1 must describe this truthfully.

It must not claim:

```text
website-image retrieval
image embeddings
image-aware answers
administrator image library
Microsite-ready media selection
```

unless those capabilities are implemented and verified.

## 7.2 Sales Core v1 Knowledge requirements

Complete and prove:

```text
workspace/account ownership enforcement

Knowledge scope enforcement

website/page/file ingestion

active/pinned index selection

AITurn index pinning

evidence persistence/audit

protection of indexes referenced by nonterminal executions

bounded retrieval context

source URL and source revision metadata

manual retrain/delete/status administration
```

The native Widget, Playbooks and omni-channel Brain use this text evidence.

## 7.3 Image/media capability is a separate Visual Sales dependency

AI Navigator and Microsites require an explicit media-aware Knowledge extension.

Do not treat image URLs embedded in markdown as a sufficient media architecture.

The later phase must audit and implement a source-linked model conceptually like:

```text
KnowledgeMediaAsset
├── workspace/account
├── Knowledge source/document/revision
├── source page URL
├── original asset URL
├── managed stored asset or approved remote reference
├── content type
├── width / height / byte size
├── content hash
├── alt text / caption
├── surrounding source text
├── role
│   ├── hero
│   ├── product
│   ├── gallery
│   ├── logo
│   └── supporting
├── approval / enabled state
├── safety / ownership result
└── provenance
```

Required media controls include:

```text
crawl and extract owned-domain images

allow administrator image upload, replacement and disablement

filter icons, tracking pixels and low-value assets

content-type and size validation

malware/content safety scanning where applicable

origin and redirect policy

hash dedupe

source-revision invalidation

human review and description editing

public/share eligibility policy
```

## 7.4 Structured Sales Entities belong to the later visual phase

Microsite pricing, product cards and visual comparisons require a structured source-linked projection such as SalesEntity.

That model is not required to release the text-first Sales Core v1.

When implemented, it must be derived from approved Knowledge sources and link exact facts and media to provenance. It must not become a second Knowledge Base.

## 7.5 No forced multimodal retrieval in the first media release

The first Visual Sales release may select approved images using:

```text
source-page association
entity association
role and relevance metadata
text/alt/caption matching
administrator approval
```

Image embeddings or a multimodal vector store are optional optimizations after the source-linked media pipeline is correct.

---

# 8. Automation and ChatRing remain peer decision-makers

Do not use the inaccurate simplification:

```text
Automation = WHEN
AI = WHAT
```

Native Chatwoot Automations can themselves:

```text
evaluate events/conditions

send public messages

send attachments

add notes

add/remove labels

change priority

assign agents/teams

change Conversation status

resolve/open/pending/snooze

send webhooks

perform other deterministic actions
```

ChatRing separately performs AI reasoning, executes Playbooks and may request overlapping native effects.

The actual architecture is:

```text
                   CHATWOOT EVENT
                         │
             ┌───────────┴───────────┐
             │                       │
             ▼                       ▼
     native Automations         ChatRing AI
     deterministic rules         Brain / Playbooks
             │                       │
             └───────────┬───────────┘
                         ▼
                   native Chatwoot
                    effects/state
```

Neither system replaces the other.

The production problem is deterministic arbitration when both affect the same customer turn.

Playbooks must not duplicate Automation conditions or become the place where operational rules such as assignment-on-label are reimplemented.

Example of productive composition:

```text
Playbook qualifies lead
        ↓
NativeTool adds label: qualified-lead
        ↓
Native Chatwoot Automation assigns Sales team
        ↓
ChatRing observes resulting native state
```

---

# 9. Automation arbitration is a production-foundation component

The existing broad `AutomationConflictClassifier` remains temporary containment.

It is not the final production arbitration mechanism.

Current ordering can be:

```text
incoming Message
      ↓
native template handling
      ↓
ChatRing scheduling
      ↓
asynchronous Automation evaluation
```

Therefore `post-template` is not necessarily `post-Automation`.

Before the public release gate opens, establish a deterministic native integration seam.

The required invariant is:

> **For one triggering customer event, ChatRing must know when relevant immediate native Automation evaluation/effects are complete, or must have an equivalent native serialization barrier that prevents a later Automation effect from racing an already-approved Brain/Playbook commit.**

Do not duplicate Automation evaluation.

Do not reimplement its conditions.

Do not re-run Automation rules inside ChatRing.

Extend the native lifecycle at the smallest safe point.

Playbook activation must occur only after the same native handling-completion contract used by free-form AI eligibility.

---

# 10. Automation effect policy must be based on actual effects

Classify Automation effects by what actually happened for the trigger.

## Orthogonal effects

Examples after source verification may include:

```text
labels
priority
private notes
non-responder metadata
```

These should normally coexist.

They may become part of the final Conversation/context snapshot seen by the Brain or current Playbook.

## Responder/lifecycle effects

Examples include:

```text
public send_message
public attachment

assignment changes

AgentBot ownership changes

status changes

resolve/open/pending/snooze
```

If one of these actually executes for the customer trigger, apply deterministic policy.

For example:

```text
Automation sends customer-facing response
→ Brain/Playbook response for that trigger must not race it.

Automation hands Conversation to human/open
→ current AITurn and Playbook step cannot later commit a public AI reply.

Automation only adds label/priority
→ AI may continue using updated state.
```

The exact precedence must be documented and tested.

## Indirect/external effects

Examples:

```text
send_webhook_event
future actions
indirect external side effects
```

Audit their real semantics before deciding whether they invalidate the AI turn or Playbook step.

Do not classify them only by name.

---

# 11. The final base must not rely on permanent broad Automation suppression

During implementation, the current conservative classifier may remain enabled.

Before Sales v1 foundation freeze:

```text
actual native Automation processing
        ↓
effect/provenance observation
        ↓
deterministic ChatRing eligibility/arbitration
        ↓
free-form Brain or Playbook execution/commit
```

must be proven.

The production foundation should not require customers to disable useful native Automations simply because ChatRing cannot determine whether they actually fired.

This is part of making ChatRing a native Chatwoot sales extension rather than a competing subsystem.

---

# 12. Build one Tool system with Inbox-scoped availability

Sales Core v1 does not require a generic administrator-defined external HTTP Tool platform.

It does require a typed Tool system because both free-form Brain conversations and InboxPlaybooks must perform native actions and present structured interactions.

## 12.1 Shared semantic Tool definitions

A ToolDefinition describes what a capability means, not how one provider renders it.

Conceptually:

```text
ToolDefinition
├── key
├── version
├── category
├── description
├── input schema
├── output schema
├── side-effect class
├── authorization policy
├── idempotency policy
└── supported renderer/executor families
```

## 12.2 Inbox Tool policy

Every native Chatwoot Inbox has an explicit Tool policy.

```text
InboxToolPolicy
├── inbox_id
├── enabled Tool versions
├── Tool-specific configuration
├── permitted native targets
├── renderer/fallback policy
├── hours/availability policy
└── published version
```

Tool availability is based on the exact Inbox and configured provider, not only the generic channel name.

## 12.3 Free-form and Playbook use the same Tools

Free-form Brain may call any Tool authorized by the current Inbox policy and Assistant policy.

An InboxPlaybookVersion declares a narrower Tool allowlist.

A Playbook step may declare a narrower subset again.

This gives:

```text
one Tool implementation
+
Inbox-specific availability
+
Playbook-specific control
```

without channel-specific prompts or duplicated Tool code.

## 12.4 Sales Core v1 Tool categories

### Native Chatwoot action Tools

These invoke audited native services:

```text
add_label
remove_label
set_priority
add_private_note
update_approved_contact_attribute
assign_team
assign_agent
handoff_to_human
change_conversation_status
resolve_conversation
```

### Conversational and Playbook Tools

```text
ask_question
show_options
mention_specifically
validate_business_email
capture_lead_field
stop_playbook
trigger_playbook
```

### Website/classic Widget Tools

```text
show_contact_form
request_appointment
recommend_page
request_human_call
```

Use Chatwoot's native interactive Message types where they fit.

### Deferred AI Navigator / visual Tools

```text
generate_microsite
show_microsite
share_microsite
website_add_to_cart
```

These must remain disabled until the Visual Sales stage and its media/artifact foundation pass.

## 12.5 Native and ChatRing Tool authority

```text
native Chatwoot action
-> native Chatwoot service remains authority

conversation UI Tool
-> ChatRing selects a typed request
-> native Message/rendering path presents it

human call Tool
-> native hours/presence/assignment plus audited call coordinator

future visual Tool
-> validated artifact/renderer only after Visual Sales release
```

The Brain never mutates Chatwoot records or renders provider payloads directly.

---

# 13. Tool execution and Inbox rendering must be production-safe

## 13.1 Authorization and identity

The model chooses a semantic operation.

The runtime supplies authoritative identity and scope:

```text
Workspace / Account
Inbox and provider
Conversation
Contact / ContactInbox
Assistant and version
active PlaybookVersion, when present
allowed agent/team IDs
native authorization policy
```

The model must not choose arbitrary Account, Contact, Conversation, agent, team or provider identifiers.

## 13.2 Rendering is selected after Tool authorization

```text
Brain or Playbook requests Tool
        ->
schema validation
        ->
Inbox Tool policy validation
        ->
runtime authorization
        ->
select native executor or channel renderer
        ->
create ordinary native Message/action
        ->
audit result
```

The Tool result is not considered customer-visible until the native Message/action commit succeeds.

## 13.3 Inbox rendering policy

For each enabled Inbox/provider, audit the exact output capability.

Examples:

```text
Website Widget
- input_select
- form
- cards
- articles
- approved links
- call CTA

WhatsApp / Facebook / Instagram
- use supported native interactive content where the exact provider permits
- otherwise use concise text, numbered choices or approved links

Email
- ordinary text and approved links
- do not assume button/form semantics

SMS
- concise numbered choices and links
```

Do not claim a structured experience from generic channel names. Provider behavior must be source-tested.

## 13.4 Fallback behavior

Every presentation Tool must define a safe fallback.

```text
show_options
-> native buttons/list when supported
-> otherwise numbered text

show_contact_form
-> native Widget form when supported
-> otherwise ask fields sequentially through the Playbook

request_appointment
-> certified embedded calendar on supported Website surfaces
-> otherwise approved link or appointment-request form

request_human_call
-> Website call CTA when supported
-> otherwise callback/booking/handoff fallback
```

If no safe rendering exists, the Tool is not included in `available_tools`.

## 13.5 Side-effect safety

Every Tool must declare:

```text
read-only / conversational / native mutation / customer-visible

retryable or not

idempotency key strategy

required confirmation

required identity assurance

terminal or nonterminal Playbook behavior
```

No unbounded autonomous Tool loop is permitted.

Sales Core v1 must define:

```text
maximum Tools per Brain turn
maximum Tools per Playbook step
maximum Playbook transition depth
maximum total invocation deadline
```

## 13.6 Publish-time validation

An InboxPlaybookVersion cannot publish when it references a Tool that is unavailable or unconfigured for that Inbox.

An Inbox Tool policy change must identify active published Playbooks that would become invalid and require explicit handling rather than silently breaking them.

---

# 14. Engagements are Website conversation-starter pills only

This definition is strict.

> **An Engagement is a configurable conversation-starter pill displayed in a Website chat surface.**

Sales Core v1 renders Engagements in the current native Chatwoot Website Widget.

The later AI Navigator may render the same Engagement records after its own release.

Engagements are not:

```text
Playbook definitions
Playbook IDs or bindings
Tool invocations
native Chatwoot Campaigns
Automations
proactive popup timers
Brain-selected actions
```

## 14.1 Engagement data model

Conceptually:

```text
EngagementSet
├── workspace/account
├── Website inbox_id
├── name
├── enabled
├── page URL visibility rules, optional
├── priority
└── EngagementStarters[]

EngagementStarter
├── label
├── submitted_text
├── display_order
├── enabled
└── optional appearance metadata
```

No Engagement record contains `playbook_id`, `tool_key` or an action enum.

## 14.2 Click behavior

```text
visitor clicks starter pill
        ->
Widget submits submitted_text as one ordinary customer Message
        ->
native Chatwoot Message lifecycle
        ->
normal ChatRing routing
```

If the submitted text happens to match a configured InboxPlaybook phrase, the normal Playbook phrase resolver may start it.

That does not create a persisted Engagement-to-Playbook relationship.

## 14.3 Configuration

Administrators may configure:

```text
default starter set per Website Inbox

page-specific starter visibility

display order

maximum visible pills

label and submitted text

Classic Widget enabled state

future AI Navigator visibility state
```

## 14.4 Proactive outreach remains Campaigns

Time-on-page, URL-triggered proactive messages and broadcasts remain native Chatwoot Campaign concerns where supported.

Do not copy donor UI that combines Engagement and proactive timing into one runtime model.

The Sales UI may place their settings near each other, but the persisted models and execution remain separate.

---

# 15. Playbooks are owned by one Inbox and triggered by customer phrases

This definition is strict.

> **An InboxPlaybook is a published, versioned, multi-turn sales conversation flow owned by one native Chatwoot Inbox. It starts when a customer phrase matches a configured trigger.**

Sales Core v1 deliberately uses Inbox-owned Playbooks rather than one published Playbook bound across many channels.

This simplifies:

```text
Tool validation
channel/provider rendering
copy length and tone
business-hour behavior
call/booking availability
trigger conflicts
administrator preview and testing
```

The execution engine remains shared across all Inboxes.

## 15.1 Model

Conceptually:

```text
InboxPlaybook
├── workspace/account
├── inbox_id
├── name
├── purpose / sales goal
├── draft version
└── published versions

InboxPlaybookVersion
├── immutable version
├── trigger phrases / synonyms
├── steps
├── branches
├── Tool allowlist
├── collected-field schema
├── completion outcomes
├── allowed next InboxPlaybooks
├── safety rules
├── capability snapshot
└── validation result
```

There is no separate multi-Inbox PlaybookBinding in Sales Core v1.

To reuse a flow in another Inbox, the administrator clones it and customizes/publishes the new Inbox-owned version.

A future template library may reduce editing duplication, but runtime versions remain Inbox-specific.

## 15.2 Phrase trigger

Example:

```text
Customer types:
"How much is internet?"
        ->
PhraseTriggerResolver inspects active published InboxPlaybooks
for this exact Inbox
        ->
Pricing Discovery Playbook starts
```

Trigger resolution must be bounded:

```text
normalized configured phrase or synonym
        ->
optional semantic match among this Inbox's published Playbooks only
        ->
confidence threshold and conflict margin
        ->
start one Playbook OR ask clarification OR use free-form Brain
```

Do not use uncontrolled bidirectional substring matching as production authority.

Simple greetings, acknowledgements and vague replies must not activate a Playbook.

## 15.3 AI Navigator Playbook buttons are later and separate

The later AI Navigator may display explicit buttons beside its input bar.

A button carries the exact published InboxPlaybookVersion identity.

It is not an Engagement pill.

This explicit-button trigger must be added without changing phrase-triggered Sales Core execution.

## 15.4 Runtime precedence

For each qualifying incoming customer Message:

```text
1. Complete native template and immediate Automation handling.

2. If an active InboxPlaybookExecution exists:
   continue it or answer a side question.

3. Else resolve configured phrase triggers for this Inbox.

4. Else use free-form Brain and Business Knowledge.
```

After AI Navigator is released, insert this deterministic step before phrase matching:

```text
trusted exact AI Navigator Playbook-button metadata
-> start that exact published InboxPlaybookVersion
```

Engagement is not a separate runtime branch. Its click has already created an ordinary customer Message.

## 15.5 Free-form Knowledge during a Playbook

A Playbook guides the sales goal; it does not disable the Business Knowledge Base.

When a visitor asks a side question:

```text
preserve pending Playbook step
        ->
answer from approved Business Knowledge
        ->
resume the pending Playbook question naturally
```

The Playbook controls required fields, branch choices and completion.

The Brain controls natural language and grounded explanation.

## 15.6 Human requests during free-form and Playbook execution

An explicit human request is policy input, not permission for the model to mutate
ownership. The server evaluates native Inbox hours and eligible online humans. If both
pass, the guarded native handoff/assignment path supersedes the AI turn and the Playbook
pauses or terminates according to its published policy. If either fails, the AI must not
claim a transfer; it explains current unavailability, collects any approved follow-up
fields, and requests an appointment/callback through the channel-neutral Tool.

A Playbook may ask for information required by the selected handoff/appointment path,
but it may not ignore repeated human requests merely to finish its qualification goal.
Every utterance remains an ordinary native Chatwoot Message and the human continues in
the same Conversation after native takeover.

---

# 16. InboxPlaybook validation, execution and transitions

## 16.1 Immutable publication

Draft InboxPlaybooks may be edited.

Published InboxPlaybookVersion records are immutable.

Each execution pins one published version.

Updating a Playbook must not mutate an active conversation's behavior.

## 16.2 Publish validation

At minimum validate:

```text
Inbox belongs to the same Account/Workspace

all step IDs are unique

all branch targets exist

all terminal paths stop, hand off, book, call or transition explicitly

no unreachable required step

all Tools are enabled by the current Inbox Tool policy

all Tool configuration exists

all Tools have a safe renderer/fallback for the Inbox/provider

collected-field names/types are approved

trigger phrases do not conflict beyond configured tolerance

maximum step count

maximum branch depth

maximum Tool count

maximum transition depth

no direct or indirect Playbook cycle
```

Natural-language authoring or AI-assisted generation may help administrators, but publication compiles to a validated typed version.

Raw prose is not runtime authority.

## 16.3 Execution state

One active InboxPlaybookExecution per Conversation.

Statuses may include:

```text
active
waiting_for_customer
paused_for_side_question
transitioning
completed
stopped
handed_off
superseded
failed
```

Execution state must survive worker restarts and customer delays.

Collected fields must be:

```text
schema validated
source attributed
written to approved native Contact attributes/notes when configured
available only where policy permits
excluded from model context when not required
```

## 16.4 Playbook-to-Playbook transition

Sales Core v1 may support an explicit typed transition:

```text
trigger_playbook(target_inbox_playbook_version_id, carry_fields[])
```

Required safeguards:

```text
same Workspace/Account
same native Inbox
published immutable target version
explicit source-version allowlist
no cycle
maximum transition depth
schema-compatible carried fields
one transition audit record
```

Cross-Inbox Playbook transition is not supported in v1.

Do not chain Playbooks by emitting text that happens to match another trigger phrase.

## 16.5 Human takeover and supersession

A human reply, native assignment change, terminal Automation response, expired deadline, disabled binding or newer customer turn may supersede the pending Playbook outcome.

A superseded execution must not later resume and send a stale Message.

---

# 17. Sales Core v1 Website experience uses the native Chatwoot Widget

Sales Core v1 intentionally does not require AI Navigator.

Its Website surfaces are:

```text
1. Current native Chatwoot Website Widget
2. Human Voice Call Banner / Call Surface
```

They share native Chatwoot identity, Contact, ContactInbox, Conversation, Message and agent state.

## 17.1 Current Widget capabilities to reuse

Audit and reuse native Chatwoot Widget capabilities before creating custom equivalents:

```text
branding and appearance controls
Widget SDK controls
identity/HMAC
pre-chat forms
interactive input_select messages
forms
cards
articles
attachments
Campaign messages
normal Conversation history
```

Sales Core enhancements may add:

```text
Engagement starter pills
Playbook-driven questions and options
approved contact forms
booking links
human-call CTA
sales-specific copy and navigation
```

All visitor input still creates ordinary native customer Messages.

## 17.2 Playbook rendering in the current Widget

Examples:

```text
ask_question
-> ordinary AI Message

show_options
-> native input_select when supported
-> otherwise numbered text

show_contact_form
-> native form / approved pre-chat fields when appropriate
-> otherwise sequential Playbook questions

request_appointment
-> certified embedded calendar, approved link or appointment-request form

request_human_call
-> Website Voice CTA
```

No Microsite renderer is required for Sales Core v1.

## 17.3 Voice banner/call surface

The Voice surface may:

```text
show an agent-initiated call invitation

show a visitor-initiated Talk to us launcher

show ringing / connecting / active / completed states

fall back to chat, booking or callback
```

It is human-to-human in Sales Core v1.

## 17.4 Classic Widget customization

Administrators need a Sales-oriented configuration surface for:

```text
appearance and brand settings
Engagement starters
page visibility
Playbook preview for this Inbox
available Tool preview
call CTA visibility
business-hour fallback
```

Reuse the native Widget builder and Inbox settings wherever they already provide the required control.

---

# 18. AI Navigator is a separately gated Visual Sales stage

Deferring AI Navigator is the correct sequence.

AI Navigator is not just another skin for the current Widget. Its main commercial value comes from visual artifacts, richer controls and contextual navigation, which depend on data and rendering capabilities that the current text-only Knowledge foundation does not yet provide.

## 18.1 Visual Sales prerequisites

Before AI Navigator can be released, complete:

```text
KnowledgeMediaAsset extraction and administrator uploads

media approval, description and disablement UI

source-linked structured Sales Entities

visual component and CTA schemas

safe artifact renderer

AI Navigator session integration with native Chatwoot Conversation

explicit Playbook-button metadata path

booking/calendar configuration

share policy

Visual Sales analytics
```

## 18.2 AI Navigator must reuse Sales Core

AI Navigator uses the same:

```text
Contact / ContactInbox
Conversation / Message history
AssistantVersion
BrainInvocation
Business Knowledge
InboxPlaybooks
Inbox Tool policy
native action authorization
Automation arbitration
voice/call policy
idempotency and audit
```

It must not create a second conversation or AI runtime.

## 18.3 Explicit Playbook buttons

AI Navigator may display selected InboxPlaybooks next to its input bar.

```text
[ How does it work ] [ Compare plans ] [ Book a demo ]
```

These buttons are generated from published InboxPlaybook configuration.

They are not Engagements.

A click sends exact trusted Playbook-version metadata through the native Chatwoot conversation path.

## 18.4 Release independence

Sales Core v1 may be generally available while AI Navigator remains behind a separate feature flag.

AI Navigator release must not require changing the already-proven Sales Core Brain, Playbook, Tool or native ownership contracts.

---

# 19. Microsites follow AI Navigator and the media foundation

Microsites are commercially valuable but are not a Sales Core v1 prerequisite.

They require a larger visual-artifact pipeline than text chat.

## 19.1 Later generation flow

```text
customer Message or InboxPlaybook step
        ->
Brain retrieves text evidence, approved media and Sales Entities
        ->
Brain requests generate_microsite
        ->
strict schema generation
        ->
server injects exact approved data and URLs
        ->
validation
        ->
immutable MicrositeArtifact linked to native records
        ->
ordinary AgentBot Message references artifact
        ->
AI Navigator renders it
```

## 19.2 Required artifact boundary

Conceptually:

```text
MicrositeArtifact
├── workspace/account
├── native conversation_id
├── native message_id / ai_turn_id
├── assistant_version_id
├── inbox_playbook_execution_id, optional
├── Knowledge revision
├── media/entity/evidence references
├── strict content_json
├── schema version
├── visibility
├── share state
└── audit metadata
```

No arbitrary LLM-generated HTML, CSS, JavaScript, selectors or iframe URLs are permitted.

## 19.3 Later components

The first Visual Sales release may support a bounded registry such as:

```text
hero
rich text
features grid
product/service cards
pricing cards
comparison table
image/video gallery
FAQ
booking section
contact section
CTA banner
```

Exact product names, prices, URLs, media and booking links come from approved source data or deterministic configuration.

## 19.4 Sharing

A shareable Microsite publishes an immutable sanitized snapshot.

It must not expose Contact PII, private transcript, credentials or internal IDs.

Search indexing requires explicit administrator opt-in.

## 19.5 Classic Widget behavior after Visual Sales release

The native Widget does not need inline Microsite rendering.

When useful, it may receive:

```text
a concise text summary
an approved rich card
or a safe Microsite share link
```

This keeps the Classic Widget stable while AI Navigator provides the premium visual experience.

---

# 20. Omnichannel sales chat uses one Brain, but Inbox-owned Playbooks and Tool policies

PR #17 was a Web Widget lifecycle remediation, but Website is not the final sales-channel boundary.

Before Sales Core v1 is called production-complete, certify the shared AI core across every Inbox/provider included in the approved Sales v1 channel set.

The approved Sales Core v1 inventory is:

```text
Website / Web Widget
Email
WhatsApp Cloud
Twilio SMS
Facebook Messenger
Instagram
```

Certification begins with the complete Web Widget sales-and-RealtimeKit vertical. The
remaining approved channels are then certified independently in the current product-
priority order determined by provider credentials, app approval, number availability,
compliance readiness and a real test environment. No channel blocks a ready sibling
merely because it appeared earlier in a planning list. Every other Inbox/provider is
excluded from Sales Core v1 by the locked product decision above; a future addition
requires a separate native audit and channel-certification PR.

## 20.1 Shared across channels

Every approved Inbox uses the same:

```text
Assistant / AssistantVersion
BrainInvocation
context and identity policy
text Business Knowledge architecture
ToolDefinition registry
AI decision contract
native action authorization
audit/idempotency
```

## 20.2 Deliberately Inbox-specific

Each Inbox owns:

```text
Inbox Tool policy
Inbox capability profile
InboxPlaybooks and published versions
trigger phrases
presentation/copy choices
call/booking availability
channel/provider fallback behavior
```

This is preferable to large channel-specific Assistant prompts.

It also avoids pretending that one published Playbook will render identically in Website, WhatsApp, Facebook, Instagram, SMS and Email.

## 20.3 Reuse through cloning, not shared runtime binding

Administrators may clone a Playbook from one Inbox to another.

The editor should show capability differences and require the cloned Playbook to pass target-Inbox validation before publication.

A later template library may support shared authoring, but each runtime version remains Inbox-owned.

## 20.4 Channel-specific implementation remains narrow

```text
native scheduling seam
native eligibility differences
content/media normalization
Tool renderer/fallback
serialization participation
provider template/session restrictions
native delivery/status behavior
```

Do not create ChatRing provider webhooks for channels Chatwoot already supports.

The proof for each channel remains:

```text
native provider ingress
        ->
native Contact / ContactInbox
        ->
native Conversation / Message
        ->
small channel-specific ChatRing adapter
        ->
same Brain and text Knowledge
        ->
current InboxPlaybook and Tool policy
        ->
guarded native Chatwoot effect
        ->
native provider delivery
```

## 20.5 Website-only capabilities

Sales Core v1 Website-only capabilities:

```text
Engagement starter pills
native Widget forms/cards/options
RealtimeKit call surface
certified appointment renderer for an Inbox-approved calendar/form
```

Later Visual Sales Website-only capabilities:

```text
AI Navigator
explicit Playbook buttons
inline Microsites
embedded calendars inside Microsites
Website host actions
```

## 20.6 Twilio SMS must be hardened before certification

The existing CE transport remains authoritative. The bounded extension must:

```text
validate X-Twilio-Signature synchronously at the existing inbound and status controllers
store the primary Account Auth Token separately from an optional REST API-key secret
deduplicate inbound provider SIDs durably
enforce monotonic delivery-state transitions
validate, authenticate and bound MMS downloads
persist and enforce STOP/opt-out/consent state
enforce SMS output/segment policy server-side
```

Do not add another Twilio webhook, Contact store, Conversation, sender or delivery job.
Native one-off Campaign sending must be adapted before Sales outbound use because its
current direct provider call does not create the required per-recipient Conversation/
Message/idempotency audit.

---

# 21. Human voice and calls in Sales v1

Sales v1 includes human-to-human voice.

It does not include AI speech-to-speech or an AI receptionist.

## 21.1 Website RealtimeKit calls

Audit and reuse Chatwoot's Cloudflare RealtimeKit integration for agent-initiated Website meetings/calls.

The current CE seam is real but is not production-safe unchanged. Before any Sales call
release, the native Widget participant-token endpoint must scope the integration Message
through the authenticated contact's conversations, not merely the Inbox. Provider tokens
must be encrypted at rest, calls must use bounded provider timeouts, visitor and agent
participant roles must use least-privilege presets, and participant-token updates must be
concurrency-safe. These are hardening extensions to the native seam, not reasons to build
another meeting transport.

Native meeting creation currently writes the outgoing integration Message directly. In a
managed-bot-owned Conversation, an agent starting or accepting a call must first complete
native human takeover through the existing serialization boundary and
`Conversations::AssignmentService`. Add pending-AITurn versus agent-call race tests; a
meeting must never leave the managed AgentBot as owner while a human agent is joining.

Required flows:

```text
Agent-initiated
Agent opens native Conversation
→ starts RealtimeKit meeting
→ native integration Message/invite
→ visitor accepts
→ both join
```

```text
Visitor-initiated
Visitor clicks Talk to us / Voice Banner
→ native hours + availability + abuse checks
→ create/reuse native Contact/Conversation
→ call request rings assigned agent first
→ then eligible Inbox members according to approved routing
→ first accepted agent becomes native assignee
→ create/reuse RealtimeKit meeting
→ both join
```

The visitor-initiated flow is a ChatRing extension where Chatwoot does not already provide it.

It must reuse native Contact, Conversation, agent presence, Inbox membership and assignment.

## 21.2 Twilio is the PSTN provider for v1

The current CE source provides native Twilio SMS, credentials and messaging delivery, but
the PSTN Voice backend—Call model, controllers, provider services and lifecycle—is
Enterprise-only. CE schema/UI fragments do not make that runtime available. Enterprise
code must not be copied, ported or unlocked.

Twilio Voice is therefore a genuinely missing CE capability. Implement it independently
from Twilio's public SDK/contracts as one narrow provider adapter subordinate to native
Account, Inbox, Contact, ContactInbox, Conversation, Message, agent presence and
AssignmentService. Reuse only CE-owned Twilio/channel seams that survive the implementation
audit; do not create another conversation, assignment or delivery authority.

Conceptually:

```text
VoiceProviderAdapter
├── create_client_token
├── originate_call
├── receive_provider_event
├── accept
├── reject
├── hangup
├── transfer, if required
└── normalize_status
```

Build only the operations required by Sales v1.

## 21.3 Voice ownership boundary

```text
Sales Brain
→ may offer/request a human call

Chatwoot / ChatRing call policy
→ determines eligibility, routing and assignment

RealtimeKit or Twilio PSTN provider
→ owns media transport

Chatwoot
→ owns Contact, Conversation, agent/team and native assignment

Call adapter / native Call model
→ owns normalized call status and provider IDs
```

The Brain must not:

```text
select arbitrary agents
create participant tokens directly
control provider credentials
change call status directly
or stream/process audio
```

## 21.4 Call record audit

Before creating a new `ChatRingCall` model, audit:

```text
native Chatwoot Call model availability and licensing
native voice_call Message content type
RealtimeKit integration Message behavior
Conversation association
call dashboard/reporting
```

Prefer extending/reusing native call records where legally and technically available.

If a minimal ChatRing call-request record is necessary, it must be linked to native Account, Inbox, Contact, Conversation and Message, and must not replace native assignment or Conversation status.

## 21.5 Call failure and fallback

Required outcomes:

```text
agent accepts
no agent answers
visitor declines
provider failure
microphone permission denied
outside business hours
rate limited / abuse rejected
```

Fallback may offer:

```text
continue chat
book appointment
leave contact details
request callback
```

---

# 22. Sales-first product shell and administration

ChatRing Sales simplifies Chatwoot for customers while preserving native code and upgrade compatibility.

## 22.1 Sales Core v1 primary navigation

Recommended navigation:

```text
Overview

Conversations

Leads & Customers

AI Sales Agent

Playbooks

Engagements

Knowledge

Calls

Campaigns

Automations

Sales Analytics

Settings
```

Do not expose AI Navigator or Microsites in the primary navigation until the Visual Sales stage is implemented.

## 22.2 Native Chatwoot features kept and presented for sales

| Native Chatwoot capability | Sales-first presentation |
|---|---|
| Contacts | Leads & Customers |
| Companies | Accounts / Companies |
| Contact notes | Sales Notes / Memory |
| Custom attributes | Lead Fields |
| Labels | Segments / Tags |
| Conversations | Sales Conversations |
| Inboxes | Channels |
| Agents and teams | Sales Reps and Teams |
| Assignment | Lead / Conversation Ownership |
| Business hours | Team Availability |
| Campaigns | Campaigns / Proactive Outreach |
| Automations | Sales Automations |
| RealtimeKit | Website Calls |
| Canned Responses | Rep Templates |
| Reports | Sales Engagement Analytics |
| APIs/Webhooks | Advanced Integrations |

Internal Chatwoot model/service names remain unchanged.

## 22.3 Minimum Sales Core administration

Console-only operation is not acceptable for production.

Administrators need UI/API for:

```text
Assistant create, edit draft and immutable publish

Inbox bind, switch, drain, disable and archive

Business Knowledge source add/delete/retrain/status

Inbox Tool policy and configuration

Inbox capability preview

InboxPlaybook create/edit/validate/test/publish/clone

Playbook execution and failure inspection

Engagement starter configuration and page visibility

Classic Widget sales appearance/preview

RealtimeKit and PSTN voice configuration

hours, routing and call fallback

failed AITurn / Tool / call inspection

feature enable/disable and release state
```

## 22.4 Playbook editor requirements

Study cqalerts donor UI patterns for:

```text
list and status cards
quick setup and manual creation
split editor / Tool palette
real-time validation
visual step preview
publish errors and warnings
clone to another Inbox
```

ChatRing runtime must use typed compiled versions rather than donor prose parsing as authority.

The Tool palette must be filtered by the selected Inbox Tool policy.

The preview must show target-Inbox rendering/fallback behavior.

## 22.5 Engagement editor requirements

Provide:

```text
starter label and submitted text
order and enabled state
Website Inbox selection
page visibility rules
Classic Widget preview
future AI Navigator visibility field, disabled until available
```

Do not combine Playbook selection or proactive Campaign timers into Engagement records.

## 22.6 Visual Sales administration later

The AI Navigator stage adds separate UI for:

```text
website-image extraction status
media library, upload, description, enable/disable and approval
Sales Entity review and exact fact correction
AI Navigator appearance and page rules
explicit Playbook buttons
Microsite component/CTA policy
calendar/booking configuration
share, expiry and SEO policy
host action / cart adapter configuration
Visual Sales failures and analytics
```

## 22.7 Support-first features hidden, not deleted

Hide from ordinary Sales navigation unless enabled:

```text
Help Center / support portals
SLA policies and breach views
CSAT configuration and reports
support resolution dashboards
support-ticket terminology where irrelevant
Captain configuration
Dialogflow configuration
external AgentBot configuration for managed Inboxes
support-specific developer settings
```

Use feature flags, product profile, navigation filtering, permissions and Advanced settings.

---

# 23. Keep Engagements, Playbooks, Tools, Campaigns, Automations, AI Navigator and Microsites separate

This boundary must be reflected in models, APIs, UI labels, documentation and tests.

| Concept | Definition | Trigger | Runtime authority |
|---|---|---|---|
| **Engagement** | Website conversation-starter pill | Visitor clicks pill | Submits ordinary customer Message |
| **InboxPlaybook** | Inbox-owned multi-turn guided sales flow | Matching customer phrase; later exact AI Navigator button | ChatRing execution + native Messages/Tools |
| **Tool** | Typed semantic capability | Brain or Playbook requests it | Inbox policy + authorized native executor/renderer |
| **Campaign** | Proactive/broadcast outreach | Native Chatwoot Campaign rules/schedule | Chatwoot Campaign engine |
| **Automation** | Event-condition-action rule | Native Chatwoot event | Chatwoot Automation engine |
| **AI Navigator** | Later rich Website presentation surface | Website configuration | Same native Conversation and Sales Core |
| **Microsite** | Later validated visual artifact | AI Navigator Tool request | ChatRing artifact pipeline linked to native records |

Rules:

```text
Engagement records contain no Playbook IDs or Tool actions.

InboxPlaybooks own phrase triggers and Tool allowlists.

AI Navigator buttons come from published InboxPlaybooks, not Engagements.

Tools are available through Inbox policy to free-form Brain and/or Playbooks.

Campaigns are not renamed Engagements.

Playbooks do not evaluate native Automation conditions.

Automations may react to native effects requested by Playbooks.

Microsites are not available until AI Navigator/media release.

All customer-visible text remains native Chatwoot Messages.
```

A Sales administration screen may cross-link concepts for convenience, but persistence and runtime authority remain separate.

---

# 24. Complete durability and failure semantics across Sales Core v1

The Sales Core reliability model must cover:

```text
LLM calls

text Business Knowledge retrieval

Tool calls

InboxPlaybook activation and step execution

Automation arbitration

final Chatwoot Message/action commit

RealtimeKit call requests

Twilio PSTN provider events
```

Foundation requirements include:

```text
hard AITurn/BrainInvocation deadline

explicit LLM timeout

bounded retries with one retry owner

retry safety/idempotency classification

durable execution attempts

no stranded received/running/ready_to_commit state

durable final-commit enqueue/recovery

release kill switch

InboxPlaybookExecution recovery and supersession

ToolExecution audit/idempotency

call request/provider-event dedupe

KnowledgeIndex pin safety
```

## 24.1 One retry owner

Recommended default:

```text
model SDK internal retries disabled or tightly bounded to zero

ActiveJob / ChatRing orchestration owns cross-attempt retry

one persisted attempt per actual provider request

all retries bounded by deadline_at
```

Do not retry permanent configuration, authorization, schema, tenant, expiry, human-takeover or unsupported-capability failures.

## 24.2 Durable customer-outcome outbox

A customer-affecting result must not depend on a best-effort enqueue.

```text
Brain / Playbook / Tool produces authorized outcome
        ->
transaction creates or reuses pending outcome ledger
        ->
after-commit enqueue
        ->
worker revalidates native state
        ->
commits native Message/action/handoff
        ->
marks committed / rejected / retryable failure
```

Automatic recovery of pending outcomes is mandatory.

Operator resume is supplemental.

## 24.3 Playbook recovery

A crash or retry must not:

```text
advance a step twice
ask a question twice
write a Contact field twice
transition twice
resume after human takeover
```

The execution pins the current step and uses idempotent outcome keys.

## 24.4 Tool failure

A Tool failure follows its declared policy:

```text
safe text fallback
retry within remaining budget
Playbook alternate branch
clarification
human handoff
```

No unavailable or failed Tool may cause fabricated success.

## 24.5 Voice failure

Call-request and provider failures must produce explicit states and safe fallback to chat, booking or callback.

## 24.6 Later Visual Sales reliability

Media extraction, Sales Entity generation, Microsite generation, sharing and calendar/cart actions receive a separate failure and release matrix in the Visual Sales stage.

They are not hidden inside the Sales Core release gate.

---

# 25. Shared serialization and final commit invariants remain mandatory

For managed ChatRing Conversations, preserve the narrow DB-backed serialization approach.

Do not globally lock every Chatwoot Message.

The existing direction remains:

```text
Account/configuration
        ↓
Inbox
        ↓
Conversation
        ↓
AITurn / PlaybookExecution / outcome ledger
```

At final native-effect commit, revalidate:

```text
Workspace/account ownership

current Assistant binding/version

expected AgentBot

Conversation ownership/status

human takeover

newer customer Message

Automation outcome/arbitration

active PlaybookVersion and expected step

Native Tool authorization

channel/Website capability

deadline

release gate

duplicate/idempotency state
```

For a call request, also revalidate:

```text
calls enabled for Inbox/site

business hours / configured availability

eligible agent/team route exists

no duplicate active request

provider/RealtimeKit configuration valid
```

The Brain's answer, Playbook step and Tool request remain advisory until guarded commit succeeds.

Do not perform external model, Tool-provider or call-provider network operations while holding database locks.

The later Visual Sales stage must add its own artifact-specific revalidation without changing this native commit boundary.

---

# 26. PR #17 is merged; preserve its lifecycle correction

PR #17 merged at source head:

```text
19d6abcd49ec33e52f96f469ad0ee65b63110093
```

with merge commit:

```text
401a33f35a4edda131edf51ed829a6b2fbbcec61
```

It froze:

```text
native Chatwoot authority

internal managed AgentBot mode

managed self-webhook removal

native assignment and takeover

native handoff

ordinary AgentBot Message persistence

native delivery

scoped serialization

binding drain / rebind / disable / archive behavior

fail-closed Automation containment

public/external gates disabled
```

It explicitly did not freeze post-template scheduling as the final production trigger seam.

Do not reopen PR #17 or mix Sales product work into its historical scope.

The directly stacked Native Handling Completion work is merged:

```text
synchronous template completion
+
actual immediate Automation completion/effects
+
idempotent ChatRing scheduling
```

Source head:

```text
019cf695695137b1733da8ab2d6a9060aa06add4
```

Merge commit:

```text
28aeef3baebbf75c1a521c30783bcc6c9d5588b8
```

Current fork behavior and current upstream delayed-Automation behavior must be audited separately.

Do not claim delayed Automation support unless it is deliberately ported, implemented and tested.

PR #17 merge is not permission to enable public AI.

---

# 27. Package Sales Core v1 as stacked, reviewable work

PR #17 and Native Handling Completion are merged. Continue through bounded PRs in
dependency order. Feature-specific administration ships with its feature; the later
administration stage consolidates navigation, health and analytics rather than deferring
operability.

```text
PR #17 - merged
Native lifecycle remediation
+ containment
+ correct Chatwoot authority

        ->

Foundation PR - Native Handling Completion - merged
synchronous template completion
immediate Automation completion/effect observation
one two-sided trigger barrier
no rule re-evaluation

        ->

Foundation PR - BrainInvocation / Context / Policy
BrainInvocation
trusted-vs-model context
speaker provenance
privacy and Contact projection
native hours, identity and kill-switch policy
deadlines and typed decisions

        ->

Foundation PR - Reliability / Durable Outcomes
one retry owner
bounded provider calls
durable fallback and pending-outcome recovery

        ->

Foundation PR - Knowledge Safety
nonterminal KnowledgeIndex pin protection
evidence and outcome correlation
cleanup safety

        ->

Foundation PR - Native Actions / Automation / Memory Base
actual native effect arbitration
server-authorized native actions through Chatwoot services
human-visible notes and governed memory policy

        ->

Foundation PR - Basic Assistant Administration
create and publish immutable Assistant versions
bind, switch, disable/archive and inspect failures
configure Knowledge and basic policy

        ->

Foundation PR - Web Widget Core Production Proof
real PostgreSQL, Redis, Sidekiq and DocsGPT boundaries
native handling through Brain, Knowledge, native reply/action/handoff
both race orderings and concurrency proof

        ->

Foundation PR - Bounded Sales Core Tool System
ToolDefinition
InboxCapabilityProfile
InboxToolPolicy
native action and conversational/Widget capability adapters
channel renderer/fallback contract
ToolExecution audit

        ->

Foundation PR - InboxPlaybooks
InboxPlaybook and immutable versions
phrase resolution
validation against Inbox Tools
execution, side questions and transitions
Playbook administration and target-Inbox preview

        ->

Foundation PR - Engagements and Classic Widget Sales UX
Website starter pills
page visibility
native interactive Messages
sales appearance/preview
strict Engagement/Playbook separation

        ->

Foundation PRs - Complete Website Sales + RealtimeKit Vertical
first harden participant authorization, credential storage, timeouts, role presets,
participant-state concurrency and native takeover
then add visitor Talk to us through native hours, presence, routing and assignment
prove free-form sales, Playbooks, Engagements, native actions, human handoff and calls

        ->

Foundation PRs - Approved Text-Channel Certification
one shared Brain with Inbox-owned Playbooks and Tool policies
Twilio SMS, Email, WhatsApp Cloud, Facebook and available Instagram
each independently certified when its real provider gate is ready; no fixed sibling order

        ->

Foundation PR - Twilio PSTN Voice
independently implement only the missing CE provider/call boundary
signed callbacks, durable provider-leg idempotency and native Conversation projection
native hours, presence, routing and assignment

        ->

Foundation PR - Final Sales Shell, Administration and Analytics
sales navigation and terminology
hide support-first surfaces
consolidated configuration health and failure inspection
sales analytics; feature-specific administration already ships with each feature

        ->

Foundation PR - Sales Core Full Production Proof
real PostgreSQL / Redis / Sidekiq
all approved channels
Automations and native actions
Playbooks, Engagements and Tools
human voice
exact-image deployment and manual proof

        ->

CHATRING SALES CORE V1 RELEASE
```

After Sales Core v1 is stable:

```text
Visual Sales PR - Media-aware Knowledge
        ->
Visual Sales PR - Sales Entities and AI Navigator
        ->
Visual Sales PR - Microsites, booking and sharing
        ->
Visual Sales full production proof
        ->
AI NAVIGATOR / VISUAL SALES RELEASE
```

The exact number of PRs may change.

The dependency order and release boundaries may not be blurred.

---

# 28. What may legitimately remain for later

The following are legitimate post-Sales-Core features because they plug into the frozen Brain, Tool, Playbook, native ownership and channel contracts:

```text
AI Navigator

website-image/media extraction and administrator media library

structured Sales Entities

Microsite generation, rendering and share links

embedded calendar UI

approved Website add-to-cart adapter

additional PSTN provider

AI voice receptionist / speech-to-speech

Shopify / WooCommerce order lookup

generic external HTTP Custom Tools

trusted external business-event processing

transactional and AI-assisted outbound automation

general AI Skills framework

advanced analytics / A-B testing / optimization
```

These later features must not require changing:

```text
native Chatwoot ownership

BrainInvocation

trusted-vs-model context boundary

Contact/identity authority

Inbox Tool policy contract

InboxPlaybook execution and versioning

Automation arbitration

AITurn / durable outcome semantics

channel adapter/native delivery contract
```

If they do, the Sales Core foundation was incomplete.

The following may not be moved later while still claiming Sales Core v1 production readiness:

```text
native handling completion

reliable shared Brain and text Knowledge

correct Contact/Conversation context

Inbox-scoped Tools

Inbox-owned phrase-triggered Playbooks

Website Engagement pills in the native Widget

productive native actions/Automation coexistence

approved omnichannel sales chat

human voice/calls

complete administration

production durability and tenant isolation
```

---

# 29. Do not prematurely build unnecessary generic infrastructure

"Complete foundation" does not mean invent every conceivable abstraction.

Do not build without a proven requirement:

```text
generic second CRM/customer database

generic cross-provider identity graph

generic external Tool marketplace

generic business-event bus

generic outbound orchestration platform

new Campaign engine

new Automation language

new provider transport for channels Chatwoot already owns

new assignment engine

new agent-presence system

arbitrary visual page builder

arbitrary LLM-generated HTML/JavaScript runtime
```

The intended Playbook language is deliberately bounded to conversational sales flows.

The later Visual Sales Microsite schema must be bounded to approved components and CTAs.

The Sales Core Voice adapter is deliberately bounded to one selected provider.

When Visual Sales adds Website add-to-cart, use a narrow configured host adapter rather than a generic ecommerce integration platform.

Sales Core appointment handling uses the channel-neutral `request_appointment` Tool.
The certified Website renderer may embed an Inbox-approved calendar; other channels use
an approved link or appointment-request form. Calendar composition inside a generated
Microsite remains part of the later Visual Sales stage.

The goal is complete necessary Sales primitives, not speculative infrastructure.

---

# 30. Sales Core v1 production-foundation tests

The public Sales Core AI gate remains closed until this complete base is exercised.

## 30.1 Native lifecycle and Automation

```text
greeting, email collection and out-of-office precedence

immediate Automation completion/effect observation

label/priority/private-note Automation coexists

public-response or ownership Automation produces one deterministic result

newer customer Message supersedes stale AI

human reply/takeover supersedes AI and Playbook outcome

non-managed Inbox remains native
```

## 30.2 Brain, context and text Knowledge

```text
supported question -> grounded response with evidence

unsupported question -> clarification or handoff, no fabrication

cross-account/scope evidence rejected

speaker provenance preserved

unapproved Contact PII absent from model context

KnowledgeIndex pinned while execution is nonterminal

free-form and Playbook side questions use the same Business Knowledge
```

## 30.3 Inbox Tool policy

```text
free-form Brain sees only current Inbox Tools

Playbook sees only Inbox Tools intersected with version/step allowlist

unavailable Tool absent from prompt

native action executes through native service

model cannot override Account/Contact/Conversation/agent/team identity

Tool retry creates one idempotent effect

renderer fallback selected for current Inbox/provider

request_appointment embeds only on a certified Website surface and otherwise uses an approved link/form

Inbox Tool policy change detects invalid published Playbooks
```

## 30.4 Engagements

```text
starter pill displays in native Website Widget

click creates one ordinary incoming customer Message

no direct Playbook ID/action exists on Engagement

clicked text may match normal phrase resolver

page visibility and ordering work

Campaign behavior remains native and separate
```

## 30.5 InboxPlaybooks

```text
phrase match starts correct Playbook for current Inbox only

same phrase in another Inbox follows that Inbox's Playbooks

ambiguous match clarifies or falls back

sequential steps and branches

side question answered from Knowledge, then pending step resumes

repeated explicit human request overrides the pending step according to native availability policy

inside hours plus eligible online human produces native assignment and supersedes the AI turn

inside hours with no eligible human never claims transfer and offers appointment/callback

outside hours never claims transfer and preserves the follow-up request in Chatwoot

field collection writes approved native Contact state

invalid Tool/capability blocks publication

clone to another Inbox requires revalidation

explicit same-Inbox transition works

cycle/excessive depth blocked

worker retry advances once

human takeover supersedes execution
```

## 30.6 Current Website Widget

```text
native appearance/identity remains intact

native input_select/form/card paths work where used

Engagements and Playbook options render correctly

appointment embed/link/form and human-call CTA fall back safely

no AI Navigator or Microsite dependency
```

## 30.7 Omnichannel certification

For every approved Sales v1 Inbox/provider:

```text
native ingress
-> same Brain and text Knowledge
-> Inbox-owned Playbook and Tool policy
-> guarded native effect
-> native delivery
-> no second Conversation/store/Brain
```

Test identity, threading/reopen behavior, media/attachments, renderer fallbacks, provider templates/session rules, human takeover and delivery failure/status.

Additional mandatory provider checks:

```text
Twilio SMS: signed inbound/status webhooks, SID deduplication, monotonic status,
bounded authenticated MMS fetch, STOP/consent and real provider delivery

Facebook / Instagram: AI output never uses Meta's HUMAN_AGENT tag

All channels: server-side provider length/capability enforcement before Message creation
```

## 30.8 Human voice

```text
agent-initiated RealtimeKit invite

visitor-initiated Talk to us

hours/availability checks

assigned agent first and eligible Inbox fallback where configured

first answer wins

native assignment updates once

visitor decline / no answer / microphone denial / provider failure

Twilio PSTN provider flow

chat/booking/callback fallback

no AI audio processing
```

## 30.9 Administration and product shell

```text
administrator can create/publish/bind Assistant

configure text Knowledge and inspect status

configure Inbox Tools

create/validate/publish/clone InboxPlaybook

configure Engagement starters

configure voice and fallback

inspect failures and safely disable/drain

support-first surfaces hidden from default Sales navigation

advanced administrator retains permitted native settings
```

## 30.10 Multi-process reliability

Use real PostgreSQL, Redis and Sidekiq process boundaries where race correctness depends on them.

Run representative concurrency across free-form AI, Playbook execution, native actions/Automations, human takeover, call request acceptance and multiple approved channels.

## 30.11 Separate Visual Sales test gate

AI Navigator, media extraction, Sales Entities, Microsites, sharing, Microsite calendar
composition and cart actions are tested under their own later release gate. The bounded
Sales Core `request_appointment` renderer is tested in the Sales Core gate instead.

Sales Core tests must not pretend those features exist.

---

# 31. Release-gate definition

There are three milestones.

## 31.1 PR #17 lifecycle remediation

Complete. PR #17 merged with public AI disabled and the native authority boundary corrected.

## 31.2 ChatRing Sales Core v1 production readiness

Sales Core v1 may be called production-ready only when the following are implemented and proven:

```text
native Chatwoot lifecycle
+
Native Handling Completion / Automation arbitration
+
BrainInvocation and typed decisions
+
native context / identity / speaker provenance
+
one text Business Knowledge Base with evidence safety
+
Inbox Tool policies used by free-form Brain and Playbooks
+
Inbox-owned phrase-triggered Playbooks
+
validated execution, side questions and transitions
+
Engagement starter pills in the current Website Widget
+
productive native Chatwoot actions and Automations
+
omnichannel sales chat across the approved Inbox set
+
human RealtimeKit Website calls
+
one production PSTN provider adapter or audited native equivalent
+
complete Sales administration and customization
+
native Message persistence/delivery
+
multi-process durability, idempotency and tenant isolation
```

Sales Core v1 does not claim:

```text
AI Navigator
Microsites
image-aware Knowledge
embedded calendars inside generated Microsites
website add to cart
AI voice
external event outbound
```

## 31.3 AI Navigator / Visual Sales readiness

The later Visual Sales release requires, in addition to the already-proven Sales Core:

```text
media-aware Knowledge and administrator media controls
+
source-linked Sales Entities
+
AI Navigator using the same native Conversation/Brain/Playbooks/Tools
+
explicit Playbook buttons separate from Engagements
+
validated Microsite artifacts and safe sharing
+
booking/calendar and approved Website host actions
+
visual-stage durability, privacy, rendering and browser proof
```

Each milestone has a separate feature/release gate and immutable image proof.

---

# 32. Final completion definitions

## 32.1 Sales Core v1

ChatRing Sales Core v1 is complete when we can truthfully say:

> **ChatRing is a native sales-conversation and human-connection layer across Chatwoot. Chatwoot remains authority for Inboxes, Contacts, ContactInbox, Conversations, Messages, AgentBot ownership, agents/teams, assignment/handoff, Automations, Campaigns, APIs and delivery. ChatRing uses one shared Sales Brain and one text Business Knowledge Base; provides Inbox-owned phrase-triggered Playbooks and Inbox-scoped Tools to both free-form and guided conversations; shows separate Engagement starter pills in the current Website Widget; executes authorized native Chatwoot actions; and connects qualified visitors to humans through native RealtimeKit and one audited PSTN provider under production-grade durability and tenant isolation.**

Architecture:

```text
                         CHATWOOT
                native operational foundation

 Inboxes / Channels / Provider Ingress
 Contacts / ContactInbox / Identity
 Conversations / Messages / Attachments
 AgentBot / Agents / Teams / Availability
 Assignment / Handoff / Status
 Templates / Automations / Actions
 Campaigns / APIs / Webhooks
 Native Delivery / RealtimeKit / Calls where available
                         |
                         v
               CHATRING SALES CORE V1

 Assistant / Immutable Version
 BrainInvocation / AITurn
 Native Context / Privacy Policy
 Text Business Knowledge / Evidence
 ToolDefinition / InboxToolPolicy / ToolExecution
 InboxPlaybook / Version / Execution
 Engagement Starter Configuration
 Native Effect Arbitration
 Voice Request Coordination / One PSTN Adapter
 Sales Administration / Audit / Analytics
                         |
              +----------+-----------+
              |                      |
              v                      v
      CUSTOMER CHANNELS          HUMAN SALES TEAM

      Native Website Widget      Native Chatwoot Inbox
      WhatsApp / Email / SMS     Agents / Teams
      Social / API Inboxes       Assignment / Handoff
      Voice Call Surface         RealtimeKit / PSTN
```

Free-form path:

```text
native customer Message
        ->
native templates + immediate Automations complete
        ->
no active/matching InboxPlaybook
        ->
shared BrainInvocation
        ->
text Business Knowledge + current Inbox Tools
        ->
authorized native Message/action/call offer
        ->
native delivery
```

Engagement path:

```text
visitor clicks starter pill
        ->
ordinary incoming Message with configured text
        ->
normal phrase resolution or free-form path
```

Playbook path:

```text
customer phrase match for current Inbox
        ->
published InboxPlaybookVersion
        ->
InboxPlaybookExecution
        ->
shared Brain + text Knowledge + Inbox Tools
        ->
native Messages/actions / booking link / human call
        ->
stop, handoff or explicit same-Inbox transition
```

Human voice path:

```text
agent invite OR visitor Talk to us OR Brain/Playbook call offer
        ->
native Contact / Conversation / hours / availability
        ->
native assignment/routing
        ->
RealtimeKit Website call
OR audited Twilio PSTN adapter
        ->
normalized call status
        ->
return to same Chatwoot Conversation
```

## 32.2 Later AI Navigator / Visual Sales

The later product is complete when it can truthfully add:

> **The same Sales Core now has media-aware Knowledge, AI Navigator, source-grounded visual Microsites, explicit Playbook buttons, embedded booking and safe shareable artifacts without creating another Conversation, Brain, customer identity or delivery lifecycle.**

Visual path:

```text
Sales Core Brain / InboxPlaybook
        ->
approved text evidence + media + Sales Entities
        ->
typed visual Tool
        ->
validated immutable artifact
        ->
native Message reference
        ->
AI Navigator render
        ->
optional sanitized share snapshot
```

The central engineering objectives are:

> **Audit Chatwoot before building each component. Preserve native ownership. Keep Engagements and Playbooks distinct. Use one shared Brain, while making Tool availability and Playbooks Inbox-specific. Complete the current Widget, Playbook, Tool, omnichannel and human-voice foundation before building AI Navigator. Add media and Microsites only when the Knowledge, administration and artifact-security prerequisites exist.**

---

# Appendix A - Mandatory source-evidence map

Before implementation, Codex must refresh exact repository SHAs and document them in the active implementation plan.

Current lifecycle reference at the time of this direction:

```text
Repository: noomi456/chatwoot
PR: #17
Merged: 2026-08-10
PR head: 19d6abcd49ec33e52f96f469ad0ee65b63110093
Merge commit: 401a33f35a4edda131edf51ed829a6b2fbbcec61
```

Do not assume these remain the deployed production SHA.

## A.1 Source authority hierarchy

```text
1. Deployed Chatwoot/ChatRing source and runtime
2. This staged Sales Core v1 direction
3. PR #17 / v2.2 native lifecycle contract
4. Active stacked implementation plans
5. Official Chatwoot documentation
6. Expertise.ai public documentation/product pages as donor reference
7. cqalerts3-code repository as donor/UI reference
```

Donor code may not override native Chatwoot ownership or production security requirements.

## A.2 Current Knowledge truth to audit

At the reviewed ChatRing merge:

```text
KnowledgeDocument stores markdown and metadata.

DocsGPT upload sends text/markdown files containing KnowledgeDocument.markdown.

The configured provider chunks markdown.

There is no implemented first-class Website image/media asset catalog,
administrator media upload/review surface, image retrieval contract,
or Microsite-ready media selection path.
```

Codex must verify the current deployed tree before implementing media support.

Relevant source areas include:

```text
db/migrate/20260805000000_create_chat_ring_knowledge_foundation.rb
app/models/chat_ring/knowledge_document.rb
app/models/chat_ring/knowledge_index.rb
app/services/chat_ring/knowledge/docs_gpt_client.rb
app/services/chat_ring/knowledge/sync_service.rb
app/services/chat_ring/knowledge/retriever.rb
```

## A.3 Official Chatwoot documentation to audit

```text
User Guide
https://chatwoot.help/hc/user-guide/en
https://www.chatwoot.com/hc/user-guide/en/

Channels and Inboxes
https://www.chatwoot.com/hc/user-guide/articles/1677492191-adding-inboxes

Agent Bots
https://www.chatwoot.com/hc/user-guide/articles/1677497472-how-to-use-agent-bots

Automations
https://www.chatwoot.com/hc/user-guide/articles/1677689800-how-to-use-automation

Interactive Messages
https://www.chatwoot.com/hc/user-guide/articles/1677689344-how-to-use-interactive-messages

Widget Customization
https://www.chatwoot.com/features/widget-customization

Pre-chat Forms
https://www.chatwoot.com/hc/user-guide/articles/1677688647-how-to-use-pre_chat-forms

Widget identity validation and SDK user information
Audit the current official Widget SDK/HMAC documentation.

Contacts
https://www.chatwoot.com/hc/user-guide/articles/1677498364-understanding-contacts

Campaigns
https://www.chatwoot.com/hc/user-guide/articles/1677738682-how-to-use-campaigns

Cloudflare RealtimeKit / Website calls
https://www.chatwoot.com/hc/user-guide/articles/1781766180-how-to-enable-video-calls-with-cloudflare-realtime_kit

Voice calling / Twilio Voice / WhatsApp Calling
Audit current official Voice documentation and deployed edition.
```

## A.4 Chatwoot source areas to audit

```text
app/models/account.rb
app/models/inbox.rb
app/models/contact.rb
app/models/contact_inbox.rb
app/models/conversation.rb
app/models/message.rb
app/models/agent_bot.rb
app/models/agent_bot_inbox.rb
app/models/automation_rule.rb
app/models/campaign.rb

app/listeners/agent_bot_listener.rb
app/listeners/automation_rule_listener.rb
app/listeners/campaign_listener.rb

app/dispatchers/dispatcher.rb
app/dispatchers/sync_dispatcher.rb
app/dispatchers/async_dispatcher.rb

app/services/message_templates/hook_execution_service.rb
app/services/automation_rules/action_service.rb
app/services/automation_rules/conditions_filter_service.rb
app/services/conversations/assignment_service.rb
app/builders/messages/message_builder.rb

app/controllers/api/v1/widget/
app/controllers/api/v1/accounts/conversations/
app/controllers/api/v1/accounts/integrations/
app/controllers/public/api/v1/inboxes/

app/models/channel/
app/services/whatsapp/
app/services/twilio/
app/mailers/conversation_reply_mailer.rb

lib/integrations/dyte/
app/controllers/api/v1/widget/integrations/dyte_controller.rb
app/controllers/api/v1/accounts/integrations/dyte_controller.rb

enterprise/app/models/call.rb and related voice services
only to determine deployed edition/licensing/native seams;
do not import Enterprise source without explicit authority.

app/services/chat_ring/
app/jobs/chat_ring/
app/models/chat_ring/
```

## A.5 Expertise.ai donor references

Use public sources to understand product contracts:

```text
Playbooks
https://docs.expertise.ai/playbook/core-concepts/
https://docs.expertise.ai/playbook/quick-reference/

Active Engagement / Conversation Starters
https://docs.expertise.ai/active-engagement/overview/

Personalized Microsites
https://www.expertise.ai/personalized-microsites

Voice and booking product references
https://www.expertise.ai/booking
```

Important distinctions:

```text
Conversation Starters are clickable questions.

Playbooks have triggers, steps, branches and Tools.

Microsites are a separate AI Nav visual capability and are not supported in the standard chat widget.

Microsites depend on images, links, interactive tools and booking/calendar presentation.
```

## A.6 cqalerts3-code donor references

Repository:

```text
cqalerts3-code/bottree-dark-custom-bots-f6b3cac4
verified donor commit: 99d37267d01997ca23ae7ff776ca11ee319bdb6b
verified on: 2026-08-10
```

Study, at minimum:

```text
src/pages/dashboard/Engagement.tsx
src/components/engagement/
src/components/widget/ClassicEngagementSettings.tsx

src/pages/dashboard/Playbooks.tsx
src/components/playbooks/
src/hooks/usePlaybooks.ts
docs/PLAYBOOK_DOCUMENTATION.md
docs/PLAYBOOK_TOOLS_REFERENCE.md
supabase/functions/shared/playbook-utils.ts

supabase/functions/enrich-content/index.ts
supabase/functions/shared/extract-entities.ts
supabase/functions/generate-microsite/index.ts
supabase/functions/shared/microsite-artifact.ts
supabase/functions/microsite-share/index.ts
public/microsite-renderer.js

src/components/voice/IncomingCallBanner.tsx
voice-server/README.md
```

Study useful donor patterns such as:

```text
Playbook list/editor/preview/validation/quick setup

Engagement list/page rules/live preview

content enrichment, CTA extraction and structured entity extraction

media-aware Microsite generation and image review concepts

shared artifact renderer and share page
```

The donor `IncomingCallBanner` is a visual interaction reference only. The donor
`voice-server` is an AI voice WebSocket/STT/TTS/LLM runtime with in-memory sessions and
Supabase functions; it is outside Sales Core v1 and must not be copied into Chatwoot's
human-call path.

Do not copy donor weaknesses as production authority:

```text
Supabase-specific tenancy/storage

substring-only Playbook matching

heuristic branch matching without typed validation

prototype claims not backed by end-to-end tests

separate customer/conversation stores

arbitrary URL/action execution

AI voice architecture outside Sales Core v1
```

## A.7 Evidence rule

Every implementation decision must cite:

```text
exact Chatwoot source path or official documentation

current commit/ref and deployed feature state

observed native behavior

selected classification: NATIVE / EXTEND / ADAPT / NEW

donor source studied, when applicable

reason the chosen ChatRing extension is minimal

native Message/action/assignment/delivery path

test proving non-managed Chatwoot behavior remains unchanged
```
