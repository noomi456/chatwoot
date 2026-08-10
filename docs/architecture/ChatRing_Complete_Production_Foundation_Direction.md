# ChatRing v1 Production Foundation — PR #17 / v2.2 Execution Direction

## Purpose

We are still completing PR #17 / ChatRing v2.2, but PR #17 is only the native-lifecycle remediation package. It is not the complete ChatRing product.

The production objective is:

> **Build a Captain-like, production-ready ChatRing AI layer on top of Chatwoot's native omnichannel foundation, using Chatwoot's existing Contacts, ContactInbox, identity, Conversations, Messages, AgentBot ownership, assignment/handoff, templates, Automations, actions, Campaigns, APIs, webhooks and channel delivery rather than recreating them.**

ChatRing v1 is not production-complete while AI is limited to Web Widget, while it can only answer static Knowledge, or while external events cannot produce native Chatwoot customer communication.

The complete production boundary includes:

```text
omnichannel inbound AI
+
Chatwoot Contact / Conversation context
+
Knowledge and human-visible memory
+
native Chatwoot actions
+
productive Automation coexistence
+
one real customer-scoped external integration
+
transactional and AI-assisted outbound
+
native Chatwoot persistence and delivery
```

This does **not** mean copying all Captain features, building every possible connector, replacing Chatwoot's CRM, or creating a new workflow/messaging platform.

The foundation may be delivered through PR #17 plus stacked, reviewable PRs. The public release gate remains closed until the complete production foundation defined in this document is implemented and proven.

The governing engineering rule is:

```text
AUDIT CHATWOOT FIRST
        ↓
      REUSE
        ↓
      EXTEND
        ↓
       ADAPT
        ↓
BUILD ONLY WHAT IS GENUINELY MISSING
```

The governing production rule is:

```text
NO ARCHITECTURE-CRITICAL "WE WILL GENERALIZE THIS LATER"
```

If a later channel, integration, Tool, Automation effect, or business event would require rebuilding the Brain invocation model, context model, identity/authorization boundary, execution persistence, native-effect arbitration, or Chatwoot ownership boundary, then the production foundation is incomplete.

At the same time, do not create speculative generic infrastructure without a real requirement. Generic primitives must be derived from and proven by concrete Chatwoot channels and at least one real external integration/event path.

---
# 1. Audit native Chatwoot before implementing each base component

Before creating or changing a ChatRing subsystem, inspect:

- the current PR #17 implementation;
- the pinned Chatwoot CE source;
- relevant current upstream Chatwoot implementation;
- official current Chatwoot documentation;
- and, where behavior is provider-dependent, the real configured provider path.

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
Voice/calls as a separately audited non-text lifecycle

official AI Actions product contract
official Custom Tools product contract
native integrations available in the deployed edition/version
```

For each desired ChatRing capability classify it as:

```text
NATIVE
Use Chatwoot unchanged.

EXTEND
Use the native model/service/event lifecycle with a narrow seam.

ADAPT
Independently implement a useful publicly documented Chatwoot product
abstraction that is not available in our CE implementation.

NEW
The capability is genuinely absent and requires ChatRing infrastructure.
```

Do not design a new ChatRing subsystem before completing this classification.

The audit must identify the actual native model, callback, service, API or provider path that will be reused. A statement such as "Chatwoot supports outbound" or "Chatwoot supports WhatsApp" is not sufficient without identifying the exact channel/provider behavior relevant to the feature.

If source and documentation disagree, current deployed source/runtime behavior wins for implementation purposes and the discrepancy must be documented.

Every implementation PR must state:

```text
native Chatwoot authority
→ native seam reused
→ minimal ChatRing extension
→ native mutation/delivery path
```

---

# 2. Native ownership boundary is final

Chatwoot remains operational authority.

Chatwoot owns:

```
Account / workspace tenancy

Contact
ContactInbox
channel identity
Widget HMAC identity validation
Contact reconciliation

Conversation
Message

AgentBot integration identity

assignment
human takeover
handoff
Conversation status

Message Templates

Automations
Automation conditions/actions

Campaigns

provider/channel ingress
provider/channel delivery

native APIs
native Webhooks

```

ChatRing must not recreate those systems.

ChatRing owns only the AI-specific layer required above them:

```
Assistant configuration/versioning

normalized Brain invocation

AI execution state

context policy/projection

Knowledge retrieval/evidence

AI/tool reasoning loop

Tool authorization/execution/audit

AI/native-effect arbitration

trusted business-event normalization

AI outbound intent

AI audit/idempotency

```

The primary authority flow remains:

```
native Chatwoot state/lifecycle
          ↓
ChatRing reasoning/policy
          ↓
native Chatwoot mutations/messages/actions
          ↓
native delivery

```

Do not introduce:

```
second Conversation store
second Message store
second customer model
second channel-identity model
second assignment state machine
second workflow engine
second campaign engine
second delivery engine

```

---

# 3. Build a real Brain kernel now

Do not finish the foundation with a Brain that fundamentally means:

```
AITurn.trigger_message
        ↓
prompt
        ↓
LLM

```

Implement a concrete normalized Brain invocation contract.

Conceptually:

```
BrainInvocation
├── assistant_version
├── trigger
│   ├── kind
│   ├── source
│   └── normalized payload
├── model_context
├── trusted_runtime_context
├── knowledge_evidence
├── available_tools
└── runtime_policy

```

The distinction between `model_context` and `trusted_runtime_context` is mandatory.

## Model-visible context

Only information intentionally exposed to the model:

```
Assistant instructions/policy

relevant Conversation history

correct speaker provenance

approved Contact attributes

retrieved Knowledge evidence

Tool names/descriptions/input schemas

safe business-event facts when relevant

```

## Trusted runtime context

Information the ChatRing runtime may use but which does not automatically belong in the prompt:

```
Workspace / Chatwoot Account

native Contact database identity

ContactInbox

HMAC/verified identity state

channel/provider identity

Assistant binding/version

expected AgentBot

Conversation ownership

deadline

credentials

authorization information

external identity resolution

locking/idempotency data

```

This separation is important.

The AI system must be able to **use** trusted identity and customer information for authorization without necessarily sending identifiers, email addresses, phone numbers, credential data or other sensitive information to the model.

---

# 4. AITurn and BrainInvocation must be separate concepts

`ChatRing::AiTurn` may remain the durable execution record for an inbound customer-Message turn.

Do not generalize its database model merely for theoretical purity if that creates unnecessary churn.

But the Brain must not accept an `AiTurn` as its fundamental reasoning API.

Use an adapter/builder boundary:

```
incoming native Message
        ↓
AITurn
        ↓
InboundInvocationBuilder
        ↓
BrainInvocation
        ↓
Brain

```

A future trusted business event must use the same reasoning kernel:

```
BusinessEvent
        ↓
BusinessEventInvocationBuilder
        ↓
BrainInvocation
        ↓
same Brain

```

This second path must not require:

```
BusinessEvent pretending to be a Message

synthetic customer Message just to invoke AI

new Shopify-specific Brain runner

```

The normalized invocation contract must be implemented and tested before the production foundation is frozen.

---

# 5. Complete the Chatwoot-native context layer

Do not leave native context assembly as scattered prompt-building logic.

Create one reusable Chatwoot-context resolution/projection layer conceptually responsible for:

```
Conversation

Inbox/channel metadata

Contact

ContactInbox

verified/identified state

selected labels

selected custom/additional attributes

native Conversation state

normalized Message history

speaker provenance

```

The context resolver should understand native Chatwoot data.

A separate context policy determines what becomes model-visible.

## Required speaker provenance

At minimum distinguish:

```
customer
human_agent
managed_ai
native_template
automation
external_bot_or_system

```

Do not classify every outgoing Message as AI.

Automation-generated Messages must retain Automation provenance.

Native templates must retain template provenance.

Human replies must remain human replies.

External/system bot messages must not be presented as ChatRing's previous statements.

This must be fixed before the Brain foundation is frozen.

---

# 6. Contact identity remains native; authorization remains server-side

Do not build parallel customer identity.

Use:

```
Chatwoot Contact
+
ContactInbox
+
native channel identity

```

For Web Widget:

```
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

Implement a reusable allowlisted projection mechanism rather than hardcoding one temporary set of fields inside PromptBuilder.

It must be capable of exposing selected fields such as:

```
customer type
language
plan/tier
region
selected labels
selected custom attributes

```

when explicitly authorized.

It must not automatically expose:

```
name
email
phone
identifier
all custom attributes
all internal metadata

```

merely because Chatwoot stores them.

The initial Widget policy may remain minimal.

The base component must nevertheless support controlled native-field projection without another context architecture rewrite.

---

# 7. Knowledge is part of the finished Brain foundation

Continue the current account-owned Knowledge/Retriever architecture.

The Brain receives retrieved evidence, not an entire Knowledge Base dump.

The finished foundation must include:

```
workspace/account ownership enforcement

Knowledge scope enforcement

active/pinned index selection

AITurn index pinning

evidence persistence/audit

protection of indexes referenced by nonterminal executions

bounded retrieval context

```

Knowledge cleanup must not delete an index still required by any nonterminal AI execution.

---

# 8. Automation and ChatRing are peer decision-makers

Do not use the inaccurate simplification:

```
Automation = WHEN
AI = WHAT

```

Native Chatwoot Automations can themselves:

```
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

ChatRing separately performs AI reasoning and may also request overlapping native effects.

The actual architecture is:

```
                   CHATWOOT EVENT
                         │
             ┌───────────┴───────────┐
             │                       │
             ▼                       ▼
     native Automations         ChatRing AI
     deterministic rules         reasoning
             │                       │
             └───────────┬───────────┘
                         ▼
                   native Chatwoot
                    effects/state

```

Neither system replaces the other.

The production problem is deterministic arbitration when both affect the same customer turn.

---

# 9. Automation arbitration is a production-foundation component

The existing broad `AutomationConflictClassifier` is useful temporary containment.

It is not the final production arbitration mechanism.

It currently reasons about whether a potentially applicable Automation contains a potentially conflicting action.

That can conservatively suppress AI even when the particular Automation never executes for the particular Message.

More importantly, current ordering can be:

```
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

The exact mechanism must follow the source audit, but the required invariant is non-negotiable:

> **For one triggering customer event, ChatRing must know when relevant native Automation evaluation/effects are complete or must have an equivalent serialization barrier that prevents a later Automation effect from racing an already-approved AI commit.**

Codex should specifically evaluate whether the cleanest native seam is to schedule/arbitrate ChatRing after `AutomationRuleListener` processing for the triggering event rather than maintaining a separate competing lifecycle.

Do not duplicate Automation evaluation.

Do not reimplement its conditions.

Do not re-run Automation rules inside ChatRing.

Extend the native lifecycle at the smallest safe point.

---

# 10. Automation effect policy must be based on actual effects

Classify Automation effects by what actually happened for the trigger.

## Orthogonal effects

Examples after source verification may include:

```
labels
priority
private notes
non-responder metadata

```

These should normally be allowed to coexist.

They may become part of the final Conversation/context snapshot seen by AI.

## Responder/lifecycle effects

Examples include:

```
public send_message
public attachment

assignment changes

AgentBot ownership changes

status changes

resolve/open/pending/snooze

```

If one of these actually executes for the customer trigger, apply deterministic policy.

For example:

```
Automation sends customer-facing response
→ AI response for that trigger must not race it.

Automation hands conversation to human/open
→ current AI turn cannot later commit a public reply.

Automation only adds label/priority
→ AI may continue using the updated state.

```

The exact precedence must be documented and tested.

## Indirect/external effects

Examples:

```
send_webhook_event
future actions
indirect external side effects

```

Audit their real semantics before deciding whether they invalidate the AI turn.

Do not classify them only by name.

---

# 11. The final base must not rely on permanent broad Automation suppression

During implementation, the current conservative classifier may remain enabled.

Before foundation freeze:

```
actual native Automation processing
        ↓
effect/provenance observation
        ↓
deterministic ChatRing eligibility/arbitration
        ↓
AI execution/commit

```

must be proven.

The production foundation should not require customers to disable useful native Automations simply because ChatRing cannot determine whether they actually fired.

This is part of making ChatRing a native Chatwoot extension rather than a competing subsystem.

---

# 12. Implement the Tool capability through a real business integration before foundation freeze

Do not defer live external-system access until after the product is called complete.

The intended product is a business-capable AI Agent, not merely a RAG FAQ responder.

Chatwoot AgentBot does not automatically know how to query Shopify, WooCommerce, CRM, billing, inventory or another external system. ChatRing must provide the concrete connector/business logic.

At the same time, do not build a fake or purely theoretical generic Tool platform.

Implement the reusable Tool execution contract around one real, read-only, customer-scoped vertical slice, preferably:

```text
identified customer asks for order status
        ↓
Brain requests order lookup
        ↓
server resolves trusted customer/store identity
        ↓
Shopify / WooCommerce / business API connector
        ↓
structured order, fulfilment and tracking result
        ↓
Brain answers through native Chatwoot Message
```

The reusable Tool contract should follow the publicly documented Chatwoot Custom Tool product model conceptually and support at least:

```text
name
description

HTTP GET / POST

endpoint or connector operation

input schema

authentication:
  Bearer
  Basic
  API key
  provider-managed credentials

request template/shaping

response template/shaping
```

Do not implement separate reasoning systems such as:

```text
Brain::Shopify
Brain::Stripe
Brain::Hubspot
```

The Brain understands capabilities and structured results.

The connector owns the external-system-specific logic, including:

```text
provider authentication
customer/store identity resolution
API requests
pagination/search
provider errors
normalization
business validation
```

Native Chatwoot Actions and external Tools are different categories:

```text
Native Chatwoot Actions
→ label, priority, note, assignment, status, handoff, reply

External Tools / Connectors
→ order lookup, tracking, inventory, billing, subscription, booking
```

Both may be available to the Brain, but they use different executors and authority boundaries.

---

# 13. Tool execution must be production-safe

Implement a real ToolExecutor.

It must handle:

```
schema validation

trusted server-side identity injection

Workspace/account authorization

credential access

network/SSRF protections

timeouts

response-size bounds

safe response parsing

bounded tool iterations

deadline propagation

audit

error classification

idempotency/retry rules

```

Retries must account for operation safety.

Read-only/idempotent operations may be retryable under policy.

Do not blindly retry non-idempotent writes.

## Tool identity rule

The model chooses the requested operation.

The runtime chooses the authorized identity.

Good:

```
AI:
get_my_order(order_number)

```

Runtime injects:

```
Workspace
verified Contact
ContactInbox/channel trust
resolved provider customer identity
credentials
authorization

```

Bad:

```
AI:
get_orders(customer_id=12345, account_id=99)

```

The LLM must not be trusted to select the customer/tenant identity used for authorization.

This boundary must be implemented before the first real integration.

---

# 14. Prove the Tool loop with a real connector, not a fake fixture

Do not declare the Tool architecture complete using only a mock endpoint or synthetic demo Tool.

Use one real read-only customer-scoped capability in a test store/environment.

Prove:

```text
customer asks for live data
        ↓
Brain selects the capability
        ↓
ToolExecutor validates request
        ↓
trusted identity/policy applied
        ↓
real connector calls the external system
        ↓
result is normalized and audited
        ↓
Brain consumes the safe result
        ↓
final native Chatwoot response
```

The first required ecommerce operations should be narrowly scoped, for example:

```text
list_my_recent_orders
get_my_order_status
get_my_tracking_details
```

The model must not select arbitrary customer or tenant identity.

Also test:

```text
unverified customer requests sensitive data
Tool timeout
Tool unauthorized
Tool malformed result
Tool unavailable
Tool retries
Tool response too large
Tool returns prompt-injection-like content
Tool attempts to access another customer's identity
overall AITurn deadline exceeded
connector succeeds but final Chatwoot commit is superseded
```

Do not enable write-capable Tools such as refund, cancellation or credit merely because the read-only path works. Those require stronger verification, confirmation, authorization, idempotency and limits.

---

# 15. Inbound core must be proven across all enabled Chatwoot messaging channels

PR #17 remains the Web Widget lifecycle-remediation PR, but Web Widget is not the product-completion boundary.

Before ChatRing v1 is called production-complete, certify the same AI core across every customer messaging Inbox type enabled in the deployed Chatwoot build.

The required target set includes, where enabled:

```text
Website / Web Widget
Email
WhatsApp Cloud
WhatsApp default/non-Cloud provider
Twilio WhatsApp
Twilio SMS
Bandwidth/native SMS
Facebook Messenger
Instagram
Telegram
LINE
TikTok
X/Twitter
API Channel
```

Any enabled messaging Inbox type not certified must be explicitly excluded by product decision with a documented native limitation. It may not be silently omitted while the product is described as omnichannel.

Voice/calls must be audited separately because the call lifecycle may not reduce to the ordinary text Message/AgentBot path. If Voice is part of the product, certify it separately; otherwise document it as a v1 exclusion.

Every channel must use the same:

```text
Assistant / AssistantVersion
BrainInvocation
context and identity policy
Knowledge architecture
memory policy
native-action policy
external Tool policy
AI decision contract
audit/idempotency
```

Channel-specific implementation is limited to:

```text
native scheduling seam
native eligibility differences
content/media normalization
serialization participation
reply/template/session restrictions
native delivery and status behavior
```

The proof for every channel must look like:

```text
native provider ingress
        ↓
native Contact / ContactInbox
        ↓
native Conversation / Message
        ↓
small channel-specific ChatRing adapter
        ↓
same BrainInvocation and AI core
        ↓
same context / Knowledge / Tool / action policy
        ↓
guarded native Chatwoot effect
        ↓
native provider delivery
```

If a channel requires creating a separate Brain, customer model, Conversation lifecycle, Message store, assignment model or delivery system, the shared architecture has failed.

Staged feature flags and channel-by-channel rollout are allowed operationally.

They do not change the final completion requirement.

---

# 16. Inbound provider transports remain native

Even while adding the second-channel proof, do not create ChatRing provider webhooks for channels Chatwoot already supports.

The ownership remains:

```
provider
  ↓
native Chatwoot ingress
  ↓
native Contact/ContactInbox
  ↓
native Conversation/Message
  ↓
ChatRing

```

ChatRing only needs the smallest channel-specific scheduling/eligibility seam required to invoke its shared execution core.

Audit each provider independently because identity/message semantics differ.

The Brain itself remains provider-neutral.

---

# 17. Build the trusted business-event path through a real external event

Outbound/event-driven customer communication is part of the ChatRing v1 product boundary.

Do not leave it as a diagram until after the product is declared complete.

Do not begin with a speculative event platform either.

Implement the minimal reusable event contract through one real provider event, preferably:

```text
Shopify / ecommerce order fulfilled or shipment created
```

The concrete flow is:

```text
provider webhook/event
        ↓
provider-specific signature/authentication verification
        ↓
deduplicate external event ID
        ↓
resolve Workspace / Account
        ↓
resolve Contact and target Inbox/channel
        ↓
normalize trusted event facts
        ↓
deterministic intent or BrainInvocation
        ↓
native Chatwoot action/message
```

Extract only the generic event fields proven necessary by the real integration.

A minimal durable BusinessEvent may include:

```text
workspace/account
source
event_type
external_event_id / dedupe key
Contact reference when known
trusted normalized payload
occurred_at
received_at
processing status
audit metadata
```

The base must provide:

```text
tenant resolution
event authentication result
dedupe/idempotency
Contact resolution
durable processing state
audit
```

Provider-specific verification and normalization remain in the provider adapter.

Do not force the event to pretend to be a customer Message.

---

# 18. Do not create another rule/workflow engine for business events

A deterministic business event does not automatically require AI.

For example:

```
order_fulfilled

```

may simply produce a deterministic outbound intent.

Do not create a new general ChatRing rule language to express this.

A provider/business adapter may decide:

```
deterministic native intent

```

or:

```
invoke Brain for judgment

```

Both use the same downstream native execution architecture.

Conceptually:

```
BusinessEvent
       │
       ├── deterministic adapter mapping
       │            ↓
       │       OutboundIntent
       │
       └── BrainInvocation
                    ↓
               OutboundIntent

```

Do not duplicate Chatwoot Automations merely to handle external events.

Where an external event can appropriately be translated into native Chatwoot state and then handled by native Automations, reuse that path.

---

# 19. Implement a generic native-effect / outbound-intent contract

The Brain should not perform provider sends directly.

It should produce structured intents.

Examples:

```
send_customer_message

handoff

assign_team

change_priority

add_label

do_nothing

```

The intent executor must map those decisions onto native Chatwoot services/actions wherever available.

Do not create duplicate business operations if Chatwoot already owns them.

This same intent/effect layer should be usable by:

```
inbound AI

business-event AI

future scheduled AI

```

without separate responder implementations.

---

# 20. Campaigns are not generic transactional outbound

Keep the three outbound concepts separate.

## Campaign/broadcast

Use native Campaigns where their semantics fit:

```
audience/broadcast
promotion
Website proactive campaign
supported native SMS/WhatsApp campaign behavior

```

Do not create ChatRing Campaigns.

## Deterministic transactional outbound

Example:

```
BusinessEvent: order_shipped
        ↓
deterministic intent
        ↓
native Chatwoot send path

```

No AI required.

## AI-assisted outbound

Example:

```
BusinessEvent: severe_order_delay
        ↓
Brain
+ Contact context
+ Conversation context
+ Knowledge
+ Tools
        ↓
structured intent
        ↓
native Chatwoot actions/message

```

All three can coexist.

They are not the same subsystem.

---

# 21. Implement native outbound capability resolution

Recent investigation shows that outbound capability differs by:

```
channel
+
provider
+
Conversation state
+
session/template requirements

```

Do not put provider branching in the Brain.

Implement a reusable native capability resolver conceptually like:

```
OutboundCapabilities.for(inbox, conversation:, contact:)

```

It should answer facts derived from native Chatwoot/channel behavior such as:

```
can_initiate?

requires_existing_conversation?

supports_transactional_send?

requires_template?

supports_template?

session/window restrictions?

persists_normal_chatwoot_message?

native send path

```

Do not duplicate provider implementations.

The resolver describes what the existing native channel can do.

The executor still invokes native Chatwoot services.

---

# 22. Audit and encode capability by channel + provider

Audit every enabled target channel/provider separately for both inbound and outbound behavior.

At minimum include:

```text
Website / Web Widget
Email
WhatsApp Cloud
WhatsApp default/non-Cloud provider
Twilio WhatsApp
Twilio SMS
Bandwidth/native SMS
Facebook Messenger
Instagram
Telegram
LINE
TikTok
X/Twitter
API Channel
```

For each document and test:

```text
native ingress path

Contact identity semantics
ContactInbox source identity

Conversation creation/reopen/threading behavior

supported Message/content/media types

native templates and Automation timing

safe ChatRing scheduling seam

human takeover / assignment behavior

can initiate outbound?

Contact requirements
Conversation requirements

template/session/window restrictions

Campaign support

native Message persistence

native send API/service

delivery/status/error behavior

serialization requirements

provider limitations
```

Do not use a generic channel name as proof of provider behavior.

The capability registry must describe native Chatwoot behavior; it must not duplicate provider transport logic.

---

# 23. Prefer native Message persistence for outbound

Whenever possible:

```
business event
        ↓
optional Brain
        ↓
native Chatwoot Conversation/Message
        ↓
native provider delivery

```

is preferred over:

```
business event
        ↓
direct provider API only

```

because native persistence gives:

```
human-visible history

future Brain context

auditability

Conversation continuity

native delivery/status semantics

```

Direct provider sending is an exception.

If a provider genuinely requires it, document:

```
why native Chatwoot cannot perform the send

how the send/result is represented back in Chatwoot

how retries/idempotency are handled

```

---

# 24. Complete durability and failure semantics across the whole execution base

The same reliability model must cover:

```
LLM calls

Knowledge retrieval

Tool calls

Automation arbitration

final Chatwoot commit

business-event processing

```

Foundation requirements include:

```
hard turn/invocation deadline

explicit LLM timeout

explicit Tool timeout

bounded retries

retry safety/idempotency classification

durable execution attempts

no stranded received/running/ready_to_commit state

durable final-commit enqueue/recovery

release kill switch

business-event dedupe

tool-call audit

outbound effect idempotency

KnowledgeIndex pin safety

```

Failure behavior must be deterministic.

A process crash, Sidekiq retry, Redis restart, or provider timeout must not produce duplicate customer-facing effects.

---

# 25. Shared serialization and commit invariants remain mandatory

For managed ChatRing conversations, preserve the narrow DB-backed serialization approach.

Do not globally lock every Chatwoot Message.

The existing direction of:

```
Inbox
  ↓
Conversation
  ↓
AI/outbound effect record

```

should remain the basis where appropriate.

At final native-effect commit, revalidate:

```
Workspace/account ownership

current Assistant binding/version

expected AgentBot

Conversation ownership/status

human takeover

newer customer Message

Automation outcome/arbitration

deadline

release gate

duplicate/idempotency state

```

The Brain's answer is advisory until final guarded commit succeeds.

---

# 26. PR #17 itself should finish the lifecycle work it already owns

PR #17 should not be abandoned or converted wholesale into every production-foundation feature.

PR #17 owns the native lifecycle correction:

```text
release-gate containment

stale gate-created AITurn reconciliation

managed AgentBot self-webhook removal

internal post-template scheduling

native AgentBot ownership

native assignment and takeover

native handoff

scoped serialization

binding drain / rebind / disable / archive behavior

ordinary AgentBot Message persistence

native delivery

non-managed Inbox regression protection

lifecycle and containment deployment proof
```

If the native Automation audit proves that ChatRing is scheduled at an incorrect lifecycle point, the minimal scheduling-seam correction belongs in PR #17 or a directly stacked lifecycle PR.

Brain/context, Tool, channel certification and outbound work may be delivered in separate reviewable PRs.

They remain part of the production-completion scope and must not be reclassified as an indefinite future roadmap.

Merging PR #17 must not enable public AI or be described as product completion.

---

# 27. Package the remaining foundation as stacked work, not future roadmap

After PR #17 is correct, complete the remaining ChatRing v1 foundation through stacked, reviewable work.

A reasonable package is:

```text
PR #17
Native lifecycle remediation
+ containment
+ correct Chatwoot authority

        ↓

Foundation PR — Brain / Context / Knowledge / Reliability
BrainInvocation
trusted-vs-model context
native context resolver
speaker provenance
identity/context policy
Knowledge pin/evidence safety
deadlines/timeouts/retries/fallback recovery

        ↓

Foundation PR — Native Actions and Automation Integration
native action authorization/execution
actual Automation effect observation
native-handling completion/arbitration seam
human-visible memory/notes policy

        ↓

Foundation PRs — Omnichannel Inbound
one shared AI core
channel/provider adapters and certification
all enabled messaging channels covered

        ↓

Foundation PR — Real External Capability
one real customer-scoped order/tracking connector
generic Tool contract extracted from the vertical slice
ToolExecutor security, audit and bounded loop

        ↓

Foundation PR — Events / Outbound
one real verified business event
dedupe/idempotency
one deterministic transactional notification
one AI-assisted outbound decision
native effect executor
channel/provider capability resolution

        ↓

Foundation PR — Full Production Proof
cross-channel lifecycle tests
real PostgreSQL/Redis/Sidekiq concurrency
provider failure tests
tenant isolation
exact-image deployment and manual proof

        ↓

CHATRING V1 FOUNDATION FREEZE

        ↓

PUBLIC PRODUCTION RELEASE
```

The exact number of PRs may change.

The production-completion scope may not be reduced to Web Widget, static Knowledge, or an empty Tool/event abstraction.

Feature flags may support staged rollout while the complete foundation is being verified.

---

# 28. What may legitimately remain for later

After ChatRing v1 foundation freeze, later work should plug into the frozen primitives.

Examples:

```text
additional ecommerce/CRM/billing connectors

write-capable Tools such as refund or credit

additional Tool types

advanced provider credential/setup UI

more business-specific event mappings

more transactional message templates/policies

full Copilot/agent-assist product

automatic FAQ generation and curation UI

advanced analytics and evaluation UI

voice-agent/call automation if excluded from v1

additional UI/admin polish
```

Adding one of these should not require changing:

```text
BrainInvocation

Context architecture

Contact/identity authority

native action authorization

Tool authorization model

Tool execution loop

AITurn core semantics

Automation arbitration model

BusinessEvent contract

OutboundIntent contract

native effect execution model

serialization/idempotency model

channel adapter contract
```

If it does, the foundation was not actually complete.

The following may **not** be moved to “later” while still claiming ChatRing v1 production completion:

```text
omnichannel inbound across enabled messaging channels

correct Contact/Conversation context

Knowledge and memory policy

native Chatwoot actions

productive Automation coexistence

one real external business integration

one deterministic outbound event

one AI-assisted outbound path

native persistence/delivery and production reliability
```

---

# 29. Do not prematurely build unnecessary generic infrastructure

“Complete foundation” does not mean invent every conceivable abstraction.

In particular, do not build without a proven requirement:

```
generic second CRM/customer database

generic cross-provider identity graph

new workflow language

new Campaign engine

new channel framework

new provider transport system

new assignment engine

```

For external business identity, begin with trusted native Contact/ContactInbox identity and canonical `Contact.identifier`/approved attributes where sufficient.

Introduce a dedicated external-identity relation only if a real integration demonstrates requirements such as:

```
multiple provider accounts per Contact

multiple IDs per provider

ID rotation/merges

many-to-many identity relations

provenance/verification requirements

```

The goal is complete **necessary** primitives, not speculative infrastructure.

---

# 30. Production-foundation tests

The public AI gate must remain closed until the complete base is exercised.

At minimum prove:

## Native lifecycle

```text
greeting + AI precedence

email collection suppresses AI

out-of-office suppresses AI

human public reply supersedes AI

newer customer Message supersedes stale AI

handoff uses native state

non-managed Inbox is unchanged
```

## Automation and native actions

```text
label Automation + AI
→ both succeed

priority Automation + AI
→ both succeed

private-note Automation + AI
→ both succeed

Automation public reply + AI
→ exactly one deterministic customer-facing outcome

assignment/status Automation + AI
→ deterministic ownership; no late AI reply

Automation-generated outgoing Message
→ does not start a new customer AITurn

multiple Automations
→ preserve native Chatwoot semantics

Brain requests native label/priority/note/assignment/status/handoff action
→ application authorization applies
→ native Chatwoot service executes
→ audit records result
```

## Knowledge, context and memory

```text
supported Knowledge question
→ grounded response with evidence

unsupported question
→ no fabrication; clarification/handoff

cross-account or cross-scope evidence
→ rejected

speaker provenance
→ customer/human/AI/template/Automation/system preserved

unapproved Contact PII
→ absent from model context

human-visible memory/note
→ correct Contact, provenance and retention
```

## Real external Tool / connector

```text
identified customer order lookup
→ correct customer/store only

unverified identity requests sensitive data
→ rejected or handed off

Tool timeout

Tool malformed response

Tool unauthorized

Tool response too large

safe retry

unsafe write not blindly retried

customer identity cannot be overridden by model

connector result is normalized and audited
```

## Business events/outbound

```text
duplicate external_event_id
→ one effect only

real order/shipment event
→ deterministic native outbound notification

AI-assisted delay event
→ same Brain kernel
→ one authorized native outcome

unsupported channel/provider capability
→ explicit safe failure or configured fallback

supported native outbound path
→ normal Chatwoot history and delivery status

customer reply to outbound notification
→ returns through normal inbound AI/human lifecycle
```

## Omnichannel portability

For every enabled messaging channel/provider:

```text
native ingress
→ same Brain core
→ native Chatwoot effect
→ native delivery
→ no second lifecycle/store/Brain
```

Include channel-specific tests for:

```text
identity
threading/reopen behavior
media/attachments
provider templates/session rules
human takeover
delivery failure/status
```

## Multi-process reliability

Use real PostgreSQL/Redis/Sidekiq process boundaries where race correctness depends on them.

Do not prove concurrency exclusively with mocks or one-process specs.

Run representative concurrency across multiple channels and outbound/event processing.

---

# 31. Release-gate definition

There are two separate milestones.

## PR #17 merge readiness

PR #17 can merge when its bounded lifecycle remediation is internally correct, reviewed, tested and deployed with public AI still disabled.

## ChatRing v1 production readiness

The project may be called production-complete only when the complete production foundation is finished and proven:

```text
native Chatwoot lifecycle
+
BrainInvocation and typed decisions
+
native context / identity / speaker provenance
+
Knowledge and memory safety
+
productive native Automation coexistence
+
native Chatwoot action authorization/execution
+
omnichannel inbound across every enabled messaging channel
+
one real customer-scoped external integration
+
secure Tool authorization/execution derived from that integration
+
one real trusted business-event path
+
one deterministic transactional outbound path
+
one AI-assisted outbound path
+
channel/provider capability resolution
+
native Message persistence/delivery
+
multi-process durability, idempotency and tenant isolation
```

Staged rollout may enable channels incrementally behind feature flags.

That operational rollout does not alter the completion definition.

Merging PR #17 or enabling Web Widget alone must not be described as ChatRing v1 production completion.

---

# 32. Final completion definition

ChatRing v1 is complete when we can truthfully say:

> ChatRing is a native, Captain-like AI layer across Chatwoot rather than a parallel customer-service platform or a Web Widget-only RAG bot. Chatwoot remains authority for Contacts, channel identity, Conversations, Messages, AgentBot ownership, Automations, native actions, assignment/handoff, Campaigns and delivery. ChatRing uses one channel/provider-neutral Brain, one safe context/identity policy, one deterministic model for AI versus native effects, one authorized external-capability model proven through a real connector, one durable trusted business-event path, one native outbound-intent/effect path, and certified operation across every enabled messaging channel.

The final architecture is:

```text
                         CHATWOOT
                native operational foundation

 Contacts / ContactInbox / Identity
 Conversations / Messages
 AgentBot / Assignment / Handoff
 Templates
 Automations / Actions
 Campaigns
 APIs / Webhooks
 Channels / Delivery
                         │
                         ▼
               CHATRING EXECUTION CORE

              Assistant / Version
              BrainInvocation
              Context Policy
              Knowledge / Memory
              AI reasoning
              Native-action policy
              Effect Arbitration
              External capabilities / Tools
              Tool Authorization
              AI Audit / Idempotency
              BusinessEvent
              OutboundIntent
                         │
              ┌──────────┴───────────┐
              │                      │
              ▼                      ▼
       NATIVE CHATWOOT         EXTERNAL SYSTEMS
       effects/delivery        via real connectors

                              Shopify / WooCommerce
                              CRM
                              Billing
                              ERP
                              custom APIs
```

Inbound:

```text
native provider ingress
        ↓
Chatwoot Contact / ContactInbox
        ↓
Chatwoot Conversation / Message
        ↓
native templates + Automations
        ↓
deterministic ChatRing arbitration
        ↓
shared BrainInvocation
        ↓
Brain / Knowledge / Memory / Tools
        ↓
authorized native Chatwoot effect
        ↓
native delivery
```

Outbound:

```text
trusted external business event
        ↓
real provider adapter
        ↓
BusinessEvent
        ↓
deterministic intent
        OR
shared BrainInvocation
        ↓
OutboundIntent
        ↓
native capability resolution
        ↓
authorized native Chatwoot effect
        ↓
native delivery
```

The central engineering objectives are:

> **Audit Chatwoot before building each component. Preserve the final native ownership boundary. Build one shared AI core across all enabled channels. Use Chatwoot's existing product primitives productively. Add external intelligence through real connectors rather than fake abstractions. Keep every customer-visible effect inside native Chatwoot wherever possible.**

After foundation freeze, adding another connector, business policy or Tool should be integration work—not a redesign of the Brain, identity model, Automation arbitration, event execution, channel lifecycle or Chatwoot ownership model.


---

# Appendix A — Mandatory source-evidence map

Before implementation, Codex must refresh the exact PR and repository SHAs and record them in the implementation plan.

Current reviewed reference at the time of this direction:

```text
Repository: noomi456/chatwoot
PR: #17
Reviewed head: 1500b09f27c80efb33d23ecea54354a4687e87bd
```

Do not assume this SHA remains current.

## Official Chatwoot documentation to audit

```text
User Guide
https://chatwoot.help/hc/user-guide/en
https://www.chatwoot.com/hc/user-guide/en/

Channels overview
https://www.chatwoot.com/features/channels

Channels and Inboxes
https://www.chatwoot.com/hc/user-guide/articles/1677492191-adding-inboxes

Agent Bots
https://www.chatwoot.com/hc/user-guide/articles/1677497472-how-to-use-agent-bots

Automations
https://www.chatwoot.com/hc/user-guide/articles/1677689800-how-to-use-automation

Customer engagement / Automation loop guidance
https://www.chatwoot.com/hc/user-guide/articles/1677238266-lesson-4-complete-your-customer-engagement-suite

AI Actions
https://www.chatwoot.com/hc/user-guide/articles/1777328078-lesson-5-ai-actions

Captain Custom Tools
https://www.chatwoot.com/hc/user-guide/articles/1775045339-v2-_-how-to-set-up-custom-tools-for-captain

Widget additional user information
https://www.chatwoot.com/hc/user-guide/articles/1677587234-how-to-send-additional-user-information-to-chatwoot-using-sdk

Widget identity validation
https://www.chatwoot.com/hc/user-guide/articles/1677587479-how-to-enable-identity-validation-in-chatwoot

Contacts
https://www.chatwoot.com/hc/user-guide/articles/1677498364-understanding-contacts

Campaigns
https://www.chatwoot.com/hc/user-guide/articles/1677738682-how-to-use-campaigns

Webhooks
https://www.chatwoot.com/hc/user-guide/articles/1677693021-how-to-use-webhooks

API Channel
https://www.chatwoot.com/hc/user-guide/articles/1677839703-how-to-create-an-api-channel-inbox

SMS channel
https://www.chatwoot.com/hc/user-guide/articles/1677846958-how-to-setup-an-sms-channel
```

## Chatwoot source areas to audit

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

app/dispatchers/dispatcher.rb
app/dispatchers/sync_dispatcher.rb
app/dispatchers/async_dispatcher.rb

app/services/message_templates/hook_execution_service.rb
app/services/automation_rules/action_service.rb
app/services/automation_rules/conditions_filter_service.rb
app/services/conversations/assignment_service.rb
app/services/messages/message_builder.rb

app/controllers/api/v1/widget/
app/controllers/api/v1/accounts/conversations/
app/controllers/public/api/v1/inboxes/

app/models/channel/
app/services/whatsapp/
app/services/twilio/
app/mailers/conversation_reply_mailer.rb

app/services/chat_ring/
app/jobs/chat_ring/
app/models/chat_ring/
```

Captain/Enterprise source may be inspected only for product and native-seam understanding. It must not be copied into the CE implementation unless licensing and product authority explicitly permit it.

## Evidence rule

Every implementation decision must cite:

```text
exact source path or official documentation
current commit/ref
observed native behavior
selected classification: NATIVE / EXTEND / ADAPT / NEW
reason the chosen ChatRing extension is minimal
```
