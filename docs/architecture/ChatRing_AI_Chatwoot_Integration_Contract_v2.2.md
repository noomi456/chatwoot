# ChatRing AI / Chatwoot Integration Contract

## Architecture reconciliation v2.2

**Status:** Approved implementation authority; public AI remains blocked until Section 13 passes

**Runtime decision:** Internal ChatRing control plane inside the Chatwoot deployment

**Native identity:** Account-owned Chatwoot `AgentBot`

**Public-response status:** Must remain disabled until every gate in Section 13 passes

**Verified ChatRing source:** `0309e77ea7954dec5185dc480f31dab610b468d4` (same tree as local `5acca0a21b0b5eb43a6d568986be8c9ee3970951`)

**Verified upstream source:** `chatwoot/chatwoot` `f12529105bff8b16793c836bde5bfe1ba7e2f470`

**Audit date:** 2026-08-09

---

## 1. Purpose and authority

This document connects the ChatRing business architecture in v2.1 to Chatwoot's
actual message, template, automation, assignment, AgentBot, handoff and delivery
lifecycle.

It supersedes the runtime-integration assumptions identified in Section 14. The
unaffected v2.1 decisions remain valid: Workspace ownership, Assistant and immutable
AssistantVersion, account-level Knowledge Base and Knowledge Scopes, governed memory,
tool authorization, identity assurance, auditability and ordinary Chatwoot delivery.

This is the approved integration contract for remediation. The current public-response
gate must be closed before runtime changes begin and must not be reopened until Section
13 passes against the production path.

The audited source currently sets `PUBLIC_AI_RELEASE_READY = true`; that state is not
justified by the integrated lifecycle evidence and is an immediate containment item.

### 1.1 Corrected executive decision

Chatwoot remains the sole operational conversation system. ChatRing adds reasoning
inside that system; it does not create a second event transport, responder lifecycle,
ownership state machine or message delivery path.

For the present single-deployment architecture:

```text
Customer channel
  -> ordinary Chatwoot incoming Message
  -> native Chatwoot status, event and template handling
  -> internal ChatRing turn scheduler
  -> Assistant policy + Phase 2A retrieval + LLM
  -> guarded internal Chatwoot commit
  -> ordinary AgentBot Message or native handoff
  -> ordinary Chatwoot channel delivery
```

The managed AgentBot is still the native Chatwoot owner and outgoing-message sender.
It is not used as an HTTP transport back into the same Rails application.

### 1.2 Why v2.1 requires this correction

V2.1 correctly required Chatwoot authority and a shared serialization boundary, but
it assumed that AgentBot webhook ingress starts after Chatwoot has settled response
handling. It does not.

Chatwoot synchronously dispatches `message_created` before it runs out-of-office,
greeting and email-collection templates. The AgentBot listener immediately enqueues
the webhook, while automation rules run later through the asynchronous dispatcher.
The existing implementation can therefore start inference before native responders
have finished—or even started—their work.

The current deployment also uses an architectural hybrid:

```text
Ingress:  public AgentBot webhook from Rails back to the same Rails application
Commit:   direct in-process Rails service call
```

This gains neither true service separation nor one coherent transaction boundary.

---

## 2. Audited native Chatwoot lifecycle

### 2.1 New Web Widget conversation

Chatwoot creates the Conversation and first incoming Message. If the Inbox has an
active AgentBot, native Conversation initialization sets the conversation to
`pending` and assigns that Inbox AgentBot.

Authority:

- `Conversation#determine_conversation_status`
- `Conversation#set_active_bot_conversation`
- `AgentBotInbox`

### 2.2 Incoming Message after-commit order

The verified order in `Message#execute_after_create_commit_callbacks` is:

```text
1. Reopen resolved or snoozed conversation when applicable
2. Apply native human-response behavior
3. Update conversation activity
4. Dispatch message_created
5. Schedule native channel delivery
6. Run native message-template hooks
7. Update contact activity
```

The synchronous dispatcher invokes `AgentBotListener` during step 4. Native
out-of-office, greeting and email collection occur in step 6. Automation rules are
invoked from the asynchronous dispatcher after the event has been enqueued.

Sources:

- [`app/models/message.rb`](../../app/models/message.rb)
- [`app/listeners/agent_bot_listener.rb`](../../app/listeners/agent_bot_listener.rb)
- [`app/services/message_templates/hook_execution_service.rb`](../../app/services/message_templates/hook_execution_service.rb)
- [`app/dispatchers/async_dispatcher.rb`](../../app/dispatchers/async_dispatcher.rb)
- [`app/listeners/automation_rule_listener.rb`](../../app/listeners/automation_rule_listener.rb)

### 2.3 Native responders are real message writers

Templates and automation are not advisory metadata:

- Greeting, out-of-office and email collection create Chatwoot messages.
- Automation `send_message` and `send_attachment` create public outgoing messages.
- Automation can also change status, agent/team assignment and other state.
- Ordinary channel delivery remains `SendReplyJob` plus the channel adapter.

Any integration contract that ignores these writers can produce duplicate or stale
answers even when its own turn and commit tests are green.

### 2.4 Native AgentBot webhook failure is stateful

AgentBot webhooks are an external-integration feature. A failed webhook may open a
pending bot-owned conversation and create an error activity. Only HTTP 429 and exactly
500 are retried by the current implementation; timeouts, TLS/connectivity failures,
401, 422, 502 and 503 can immediately enter native failure handling.

Using this behavior for an in-process ChatRing call means a transient public route
failure can mutate authoritative ownership before ChatRing's own fallback policy runs.
It can also happen on a webhook for ChatRing's own outgoing AgentBot message.

Source: [`lib/webhooks/trigger.rb`](../../lib/webhooks/trigger.rb)

---

## 3. Ownership boundary

| Concern | Sole authority | ChatRing behavior |
|---|---|---|
| Account, Inbox and channel | Chatwoot | Store exact foreign identifiers only |
| Contact and ContactInbox | Chatwoot | Read the minimum approved context |
| Conversation status | Chatwoot `Conversation` | Revalidate; never mirror a competing status |
| Human and bot assignment | Chatwoot assignment services | Request native transitions under the shared lock |
| Inbox AgentBot connection | `AgentBotInbox` | Provision atomically and validate conflicts |
| Working hours and out-of-office | Chatwoot Inbox and templates | Consume native result; do not duplicate schedules |
| Greeting and email collection | Chatwoot templates | Apply the precedence in Section 5 |
| Automation | Chatwoot automation engine | Reject launch conflicts; do not race it |
| Message persistence | Chatwoot `Message` | Create one ordinary AgentBot message |
| Customer delivery | Chatwoot | Use existing channel jobs/adapters |
| Assistant role/configuration | ChatRing | Immutable AssistantVersion pinned per turn |
| Knowledge | ChatRing Phase 2A | Account KB plus optional Assistant scope |
| Turn reasoning/audit | ChatRing | Durable AITurn, attempts, evidence and outcome |
| Tools and authorization | ChatRing | Server-side policy and idempotency; later phase |

### 3.1 AgentBot is identity, ownership and sender

Each active Assistant has one non-global, account-owned AgentBot. The AgentBot:

- is connected to compatible Inboxes through native `AgentBotInbox`;
- owns eligible pending conversations;
- is the sender of committed AI replies;
- participates in native assignment, queue, handoff and delivery behavior.

It is not the Assistant record and is not the in-process transport.

### 3.2 Assistant is policy, not conversation state

Assistant and AssistantVersion continue to own identity, instructions, audience,
availability restriction, knowledge scope and fallback policy. They do not decide or
mirror Chatwoot Conversation status or assignment.

### 3.3 Workspace does not replace Account

The one-to-one Workspace record remains the ChatRing configuration boundary. Every
runtime lookup begins from the authoritative Chatwoot Account and proves the exact
Workspace, Inbox, binding, AssistantVersion and account-owned AgentBot relationship.

### 3.4 Native-first implementation test

Before adding any ChatRing lifecycle service, state machine, event transport,
assignment mechanism, message writer, handoff mechanism, retry mechanism or delivery
mechanism, implementation must first identify the equivalent native Chatwoot
lifecycle or service and integrate through that seam. A new ChatRing component is
permitted only when the required capability does not exist natively, and it remains
subordinate to Chatwoot authority.

`AITurn` describes AI computation only. It never determines Conversation status,
ownership, human takeover or Message deliverability. `OutboundCommit` provides
idempotency and audit for one native Chatwoot outcome; it is not a second message
store. The first-release serialization guard is installed only around the approved
Web Widget customer writer and dashboard public-reply writer. It is not a global
`Message` callback.

---

## 4. Chosen runtime boundary

### 4.1 Decision: internal modular-monolith control plane

The current deployment runs ChatRing and Chatwoot in the same Rails/Sidekiq system.
The correct boundary is therefore an internal, durable service/job boundary:

```text
Chatwoot Message lifecycle
  -> ChatRing internal scheduling seam
  -> durable AITurn
  -> Sidekiq inference
  -> guarded in-process commit service
```

The managed AgentBot's `outgoing_url` is not pointed at Chatwoot's own public URL.

### 4.2 What happens to signed webhook ingress

Signed webhook verification is retained as reusable code and test coverage for a
future genuinely external runtime. It is not part of the active in-process path.
In internal mode the public managed-Assistant webhook route itself rejects requests;
clearing `AgentBot#outgoing_url` alone is not an adequate boundary.

If ChatRing is later deployed as a separate service, that is a separate architecture
mode and must use both ends of the external contract:

```text
signed webhook ingress
  -> external runtime
  -> authenticated conditional Chatwoot HTTP commit
```

It may not use external ingress and direct in-process commit together.

### 4.3 What happens to the conditional HTTP endpoint

For internal mode, `OutboundCommitJob` calls the guarded Rails service directly. The
conditional HTTP endpoint is disabled or removed from the launch surface so it cannot
be mistaken for a tested production boundary.

For future external mode, the endpoint must become independently usable and the live
runtime—not merely tests—must exercise its AgentBot-token authentication,
idempotency, timeout and ambiguous-result reconciliation.

---

## 5. Native response arbitration

ChatRing scheduling occurs only after native template handling has returned. It does
not start from the early AgentBot webhook event.

### 5.1 First-release precedence

| Native outcome for the trigger | AI turn |
|---|---|
| Out-of-office template sent | Do not create a turn |
| Email-collection input sent | Do not create a turn |
| Greeting sent | Greeting remains; create the turn after template handling |
| No template sent | Create the turn if otherwise eligible |
| Public automation reply may run | Assistant binding is rejected for launch |
| Automation may change owner/status/team | Assistant binding is rejected for launch |

Greeting is a native welcome message rather than an answer to the visitor's question.
It may precede the grounded AI response. It must be represented in context as a native
template, not as a human or AI statement.

Email collection owns that trigger. A later incoming message may create a turn after
Chatwoot has recorded the supplied email. Out-of-office behavior remains native and
owns the trigger while the Inbox is outside working hours.

### 5.2 Working-hours rule

The first release respects Chatwoot Inbox working hours. Assistant availability may
restrict that window further; it may not silently expand or replace it.

An explicit future `always_available` mode would require a separate product decision
and deterministic suppression of native out-of-office handling. It is not inferred
from Assistant text or LLM output.

### 5.3 Automation rule for launch

Chatwoot has no durable "all matching automation finished" barrier. Waiting, queue
priority and polling are not correctness mechanisms.

For the Web Widget first release, binding validation rejects an Inbox when an active
rule that may match that Inbox/event can:

- send a public message or attachment;
- change Conversation status;
- assign or unassign an agent, team or AgentBot; or
- invoke another bot/AI response path.

Non-response actions such as labels and private notes may remain only if they cannot
alter eligibility or leak into the public response path. A later coexistence design
must introduce one explicit native-handling completion contract and its own lifecycle
tests; it is not part of this remediation.

This constraint is reciprocal. Automation create, update and activation validate
against active ChatRing bindings and reject a newly conflicting rule. Ambiguous rule
conditions fail closed. Runtime scheduling and final commit repeat the conflict check
so a direct database/configuration race cannot silently enable two responders.

### 5.4 Internal scheduling seam

The scheduler extends the CE `MessageTemplates::HookExecutionService` through the
existing module-extension seam. It runs after the base service, never modifies
Enterprise/Captain source, and only considers:

- public incoming Contact messages;
- a supported channel;
- a pending Conversation owned by the Inbox's active managed ChatRing AgentBot;
- an active versioned InboxAssistantBinding;
- no terminal template outcome;
- no detected responder conflict.

`AITurn(trigger_message_id)` remains uniquely constrained so callback/job redelivery
cannot create a second turn.

The scheduler persists a causal native-handling snapshot tied to that trigger message,
including Inbox-hours state, whether email collection is still required and any
greeting/template message identifiers. Eligibility does not infer terminal handling
only from whether this callback created a new template row. In particular, while
email collection is enabled and the Contact still lacks email, every later incoming
message remains AI-ineligible even when the existing input-email message is not sent
again.

The native template classes rescue their own failures and do not return a reliable
typed result. The integration therefore records the relevant template-message set
before the native hook, runs the native hook unchanged, reloads authoritative Inbox,
Contact, Conversation and Message state, and records the resulting delta. It never
infers success from a template service return value.

---

## 6. End-to-end response path

### 6.1 Turn creation

```text
Incoming Message commits normally
  -> Chatwoot performs status/event/delivery/template work
  -> ChatRing post-template scheduler evaluates authoritative state
  -> one AITurn is inserted or an audited ineligible outcome is recorded
  -> AiTurnJob is enqueued
```

The scheduler does not copy the webhook payload and does not carry secrets or full
customer content in job arguments. Jobs receive record identifiers only.

### 6.2 Eligibility

Server-side eligibility must enforce all of the following:

- active Workspace;
- active binding and unchanged binding version;
- active Assistant and pinned immutable AssistantVersion;
- supported channel;
- pending Conversation;
- exact expected account-owned AgentBot owner;
- active Inbox-to-AgentBot connection;
- audience policy;
- Chatwoot working hours plus any stricter Assistant availability;
- newest qualifying incoming customer message;
- no newer public human response;
- no terminal native-template result;
- no active conflicting response automation;
- operational Workspace/Assistant kill switch.

The same checks are performed before inference and again inside final commit.

### 6.3 Context

Context uses ordinary Chatwoot Messages but preserves speaker provenance:

```text
customer
human_agent
managed_ai
native_template
automation
external_bot_or_system
```

These types may be mapped to model roles only after the source is retained in audit
metadata. Outgoing messages must not all be represented as if the Assistant said them.

Contact fields are data-minimized. Name, email, phone and identifier are included only
when the active Assistant policy and turn purpose require them. Private notes are
excluded by default.

For the first Web Widget release, empty `audience_policy` means all visitors to the
bound Widget Inbox and empty `availability_policy` means the native Inbox working-hours
window. Contact name, email, phone, identifier and other profile data are omitted from
model context. Any non-empty audience or availability policy is rejected at publish or
binding until a separately approved schema and management surface define its semantics;
the runtime never guesses what unknown policy keys mean.

### 6.4 Knowledge

The Brain consumes the existing Phase 2A Retriever. It pins the selected active
KnowledgeIndex to the AITurn and records evidence. Retrieval failure remains distinct
from insufficient evidence.

Provider cleanup must not delete an index referenced by any nonterminal AITurn. Current
and previous active-generation retention remains a Knowledge concern; turn pins add an
explicit temporary protection.

### 6.5 Model execution

Every model request has:

- an explicit per-attempt timeout;
- a total turn deadline;
- bounded attempts;
- persisted attempt/outcome metadata without secrets;
- cancellation checks between expensive stages.

Exhausted attempts must continue into the configured durable fallback commit. Merely
changing the AITurn to `ready_to_commit` is not sufficient; the commit job must be
durably enqueued or recoverably pending.

The first release supports only:

- grounded reply or clarification; and
- handoff.

`resolution_request` is removed from the accepted decision contract until a native,
audited and idempotent resolution operation exists.

### 6.6 Final reply

The internal `OutboundCommitJob` uses one guarded Chatwoot service. Inside the shared
Conversation serialization boundary it verifies:

- expected Account, Inbox and managed AgentBot;
- pending status and exact AgentBot owner;
- active binding and pinned versions;
- valid trigger message;
- no newer customer message;
- no newer public human reply;
- no post-scheduling terminal native response;
- idempotency ledger state.

It then creates one ordinary public outgoing `Message` with the managed AgentBot as
sender and commits the OutboundCommit ledger atomically. Native Chatwoot delivery takes
over after commit.

### 6.7 Shared serialization is scoped

The serialization invariant remains mandatory, but it is scoped to Inboxes with an
active or draining ChatRing Assistant binding. This includes their temporarily
human-owned Conversations so ownership cannot race an unlocked precheck.

The predicate is evaluated from authoritative state and rechecked after entering the
shared boundary. Assignment and binding transitions participate in the same boundary.
An unlocked `managed?` read is never the sole decision. A qualifying Web Widget public
write takes the Inbox row lock even when no binding currently exists, because otherwise
first binding activation could commit between the unlocked predicate and Message
commit. Without an active/draining binding it takes no Conversation or ledger lock.
Other channel writers take no ChatRing lock before their channel is approved.

It covers:

- qualifying public incoming customer writes;
- qualifying public human replies and external echoes;
- guarded public AI commit;
- conditional handoff, rebind reconciliation and other ownership transitions.

Non-managed conversations preserve upstream behavior. A channel is not declared
ChatRing-supported merely because its Message happens to use the shared model.

Lock acquisition order is fixed to prevent lifecycle deadlocks:

```text
configuration mutation: Account -> Inbox -> affected Conversations in ascending ID
managed message/turn transition: Inbox -> Conversation -> ChatRing ledger rows
```

Automation mutation takes the Account lock before validating active bindings. Binding,
disable, archive and rebind take the same Account lock, then the Inbox lock. Every
managed-message predicate is rechecked after the Inbox and Conversation locks are held.
An initial unlocked lookup may optimize the non-managed path, but it is never the
authoritative decision when an active or draining binding exists.

### 6.8 Handoff

Handoff is an application decision committed through native Chatwoot authority, not a
model-side mutation.

The guarded handoff:

1. locks the Conversation through the same boundary;
2. proves expected pending/AgentBot ownership and current binding;
3. records one idempotent customer-affecting outcome in the OutboundCommit ledger;
4. invokes native handoff semantics without redefining `Conversation#bot_handoff!`;
5. commits state;
6. dispatches the native handoff event only after committed state.

The upstream `bot_handoff!(dispatch_event:)` behavior is restored. ChatRing wraps it;
it does not replace it with a second nested transaction.

The OutboundCommit ledger makes the handoff state transition exactly-once for a turn.
Native event delivery keeps Chatwoot's existing retry/delivery semantics; this
contract does not falsely promise exactly-once event delivery. Event consumers must
be idempotent where duplicate observation matters.

---

## 7. Assignment and binding lifecycle

### 7.1 Native assignment remains authoritative

`Conversations::AssignmentService` remains the only normal manual assignment path:

- assigning the managed AgentBot clears the human assignee and sets pending;
- assigning a human clears AgentBot ownership and opens the Conversation.

ChatRing does not introduce a second takeover status.

A public human reply to an Assistant-bound Conversation is a takeover, not merely a
freshness signal. The dashboard's explicit native Take over action remains the normal
path. If a supported public writer reaches the server while the managed AgentBot still
owns the Conversation, the shared boundary performs the equivalent native human
assignment/open transition before committing the reply. On success the AgentBot is
cleared, so a later customer message cannot silently reactivate AI without an explicit
managed-AgentBot reassignment.

For the first release, Assistant binding itself accepts only a Web Widget Inbox.
Additional channels are rejected at provisioning—not merely filtered after a message
has already entered the runtime.

### 7.2 Managed-bot assignment filter

`AgentBot.accessible_to(account)` includes global bots and all account bots. That scope
is not sufficient for a specific Inbox.

For an Inbox selection:

- external/global AgentBots preserve upstream visibility rules;
- a `chatring_assistant` AgentBot is offered only when it is the active managed bot
  connected to every selected Inbox;
- the assignment service independently rejects a managed bot that is not the active
  connection for the Conversation's Inbox.

UI filtering is convenience; server-side enforcement is authority.

### 7.3 Rebinding an Inbox

A binding switch is not complete while Conversations remain owned by the old bot.

The fail-safe first-release policy is **handoff then switch**:

1. mark the old binding draining and reject new turns;
2. cancel/supersede its nonterminal turns;
3. enumerate pending Conversations owned by the old managed AgentBot;
4. lock each Conversation and perform native handoff;
5. verify none remain owned by the old bot;
6. replace `AgentBotInbox`;
7. activate the new immutable binding version.

If any handoff fails, the new binding is not activated. Silent reassignment of existing
customer conversations to a different Assistant is prohibited in the first release.

### 7.4 Disable and archive

Disabling an Inbox binding or archiving an Assistant follows the same drain/handoff
rule. It cannot merely update the ChatRing row while native Conversations retain the
managed AgentBot.

---

## 8. What Captain teaches—and what is forbidden

Captain was inspected only as a pattern study. ChatRing does not import, invoke, copy
or derive Enterprise/Captain implementation.

### 8.1 Useful integration lessons

Captain demonstrates that an AI responder can be scheduled internally from the
message-template seam, write an ordinary Chatwoot Message, reuse native delivery and
make template precedence explicit. Its human-response behavior is scoped to
Captain-bound conversations rather than globally altering every message.

These are lessons about CE seams, not Captain code dependencies.

### 8.2 Captain is not the ChatRing runtime

Captain is incompatible with this contract because it:

- uses `Captain::Assistant` as a message sender instead of an account-owned AgentBot;
- has no shared final-commit serialization boundary;
- does not resolve automation competition;
- mutates handoff from inside the model/tool loop;
- stores mutable Assistant configuration;
- loses outgoing speaker provenance in history;
- does not provide ChatRing's server-authorized tool gateway or safe rebind policy.

No Enterprise model, controller, service, job, prompt, tool, migration, route or source
is permitted in the ChatRing CE implementation or image.

---

## 9. Current implementation disposition

### 9.1 Keep

- Upstream AgentBot assignment/ownership reconciliation.
- Account-owned managed AgentBot identity.
- AgentBotInbox uniqueness and ownership constraints.
- Assistant, immutable AssistantVersion and versioned Inbox binding.
- AITurn, attempts, evidence and reply OutboundCommit records.
- Phase 2A account Knowledge Base, Knowledge Scope and Retriever.
- Ordinary AgentBot Message persistence and native delivery.
- Expected-owner, freshness and idempotency checks in the conditional service.
- Controlled database-barrier test utilities, re-aimed at the production lifecycle.

### 9.2 Rework

| Current behavior | Required correction |
|---|---|
| Public self-webhook to the same Rails app | Internal post-template turn scheduler |
| Live direct service plus unused HTTP endpoint | One internal commit boundary |
| Global `Message.before_create` Conversation lock | Narrow lock/recheck wrapper around the approved Widget/dashboard writers |
| Conflict detector checks AgentBot/Dialogflow/Captain only | Include native templates and conflicting automations |
| Rebind swaps Inbox pointer only | Drain/handoff old-bot Conversations before activation |
| Every accessible managed bot assignable | Only active Inbox-connected managed bot assignable |
| Custom `bot_handoff!` replacement | Restore upstream signature; wrap it safely |
| Audience/availability stored but unenforced | Server-side eligibility and final-gate enforcement |
| All contact identity sent to LLM | Purpose-based minimum fields |
| All outgoing history treated as Assistant | Typed speaker provenance |
| Exhausted retry only prepares fallback | Durably enqueue and audit fallback commit |
| Handoff lacks an OutboundCommit ledger | Generalize ledger to every customer-affecting outcome |
| `resolution_request` silently cancelled | Remove until implemented end to end |
| Knowledge cleanup ignores active turn pins | Protect nonterminal pinned indexes |
| Webhook job logs payload/secret-bearing arguments | Identifier-only job args and redacted logs |

### 9.3 Remove from the active internal path

- Managed AgentBot public `outgoing_url` pointing back to Chatwoot.
- Native AgentBot webhook delivery for managed in-process Assistants.
- WebhookDelivery as the trigger authority for the internal mode.
- Conditional HTTP route as a claimed live boundary in the internal mode.
- Global serialization effects on non-managed conversations.
- Unsupported `resolution_request` decision.

The signed-webhook and HTTP-client components may remain isolated for a future external
runtime package, but they are disabled and excluded from first-release completion
claims.

---

## 10. Security, privacy and operational corrections

Before any public response is re-enabled:

1. Close the compile-time public-response gate.
2. Disable the managed AgentBot public self-webhook path.
3. Stop logging full webhook payloads, job arguments and webhook secrets.
4. Rotate every exposed AgentBot webhook secret.
5. Rotate the OpenAI key previously supplied through chat and update the deployment
   secret store.
6. Enforce identifier-only job arguments.
7. Add per-Assistant and per-Workspace operational kill switches.
8. Add explicit model request and total turn deadlines.
9. Correlate the internal trigger, AITurn, evidence, customer-affecting commit and final
   Chatwoot Message.
10. Ensure audit failure can never cause a second customer action.

No secret, raw customer message, private storage URL or provider internals are exposed
to visitors or routine logs.

---

## 11. Corrected implementation sequence

The sequence is deliberately narrow and test-first.

### Stage 0 — containment

- Set the public-response gate to false.
- While the gate is false, do not create or enqueue new `AITurn` records. Terminally
  cancel any previously queued, unstarted `received` turns without inference or a
  customer-visible mutation.
- Freeze new Assistant binding, switching and channel expansion during remediation.
- Confirm no new AI public reply can commit.
- Preserve records for audit; do not delete customer Conversations or Messages.
- Rotate exposed credentials and redact logs.

### Stage 1 — native lifecycle contract tests

Write failing full-lifecycle tests for template precedence, automation conflicts,
managed assignment, rebind, handoff event timing, internal scheduling and scoped
serialization before changing the implementation.

### Stage 2 — one internal trigger path

- Add the post-template CE integration module.
- Create AITurn directly/idempotently from record identifiers.
- Remove managed self-webhook provisioning and recursion.
- Retain AgentBot only as native owner/sender.

### Stage 3 — native conflict and availability enforcement

- Implement the Section 5 template outcome contract.
- Reject conflicting automation at binding time, automation mutation time and runtime
  recheck.
- Enforce audience, Inbox hours and stricter Assistant availability server-side.

### Stage 4 — scoped serialization and native handoff

- Scope the shared lock to managed-Assistant Conversations.
- Restore upstream `bot_handoff!(dispatch_event:)` compatibility.
- Generalize the commit ledger for reply and handoff.
- Prove event-after-commit behavior.

### Stage 5 — assignment and rebind

- Filter and enforce valid managed-bot assignment.
- Implement drain/handoff-before-switch.
- Test disable/archive with existing bot-owned Conversations.

### Stage 6 — Brain failure/privacy correction

- Enforce bounded request/turn deadlines.
- Make exhausted retries commit the configured fallback.
- Remove unsupported decisions.
- Preserve typed speaker provenance and minimize Contact fields.
- Protect KnowledgeIndexes pinned by nonterminal turns.

### Stage 7 — complete production-path verification

Run Section 13 in CI and on the VPS using the exact immutable images. Only after every
gate passes may the Web Widget public-response constant change to true.

No additional channel, tool, Contact Memory, Q&A, Images or UI expansion is included
in these remediation stages.

---

## 12. Required full-lifecycle test topology

Service-level tests remain useful but are insufficient. The authoritative Web Widget
test must traverse:

```text
Widget HTTP request
  -> Conversation/Message commit
  -> native Message callbacks
  -> native templates
  -> automation conflict enforcement
  -> internal turn scheduling
  -> AITurn job and Phase 2A retrieval
  -> guarded commit/handoff
  -> ordinary Message
  -> native delivery scheduling / widget-visible record
```

Tests must invoke the same boundary used in production. They may use controlled
barriers, but may not bypass controller/callback/scheduler behavior and then claim the
end-to-end lifecycle passed.

---

## 13. Release gates

Public Web Widget AI remains disabled until all gates pass.

### 13.1 Native response arbitration

- Greeting enabled: one native greeting plus at most one grounded AI answer.
- Unknown-email contact with email collection enabled: email input only; no AI turn.
- Out of office: native OOO only; no AI turn.
- Conflicting public-message automation: binding/activation rejected.
- Conflicting assignment/status automation: binding/activation rejected.
- Conflicting automation created or activated after binding: rule change rejected.
- Allowed non-response automation: no duplicate response and no stale eligibility.

### 13.2 Internal boundary

- Managed AgentBot has no public self-webhook for the internal runtime.
- A previously valid signed managed-Assistant webhook is rejected and creates neither
  WebhookDelivery nor AITurn in internal mode.
- Incoming message creates exactly one AITurn without webhook delivery.
- AI outgoing message does not recursively create another AI turn.
- Conditional HTTP endpoint is not used or advertised by internal mode.
- No webhook failure can mutate a successful internal AI Conversation.

### 13.3 Ownership, assignment and rebind

- New Assistant-enabled Conversation is pending and owned by the exact Inbox AgentBot.
- Binding an unsupported non-Web-Widget Inbox is rejected before activation.
- Human takeover uses native assignment and prevents late AI output.
- A public human reply atomically completes native takeover and leaves no managed bot
  owner unless the user later reassigns it explicitly.
- Other-Inbox/global managed bot assignment is rejected server-side.
- Rebind with old-bot Conversations drains/hands off before new activation.
- Disable/archive leaves no Conversation stranded on the disabled managed bot.
- Handoff state transition is idempotent; the native event is dispatched only after
  committed state under Chatwoot's existing event-delivery semantics.

### 13.4 Serialization

Controlled barriers prove:

- customer message wins before AI commit: old reply is rejected;
- public human reply wins before AI commit: old reply is rejected;
- takeover wins before AI commit: old reply is rejected;
- binding switch/handoff wins: old reply is rejected;
- concurrent identical commits create one Message;
- timeout after a successful commit reconciles to the same Message;
- no qualifying write interleaves between final validation and AI insert.

The tests enter through real Web Widget and dashboard/public-reply writers, not only
direct model creation.

### 13.5 Failure and privacy

- Model timeout and provider failures reach a bounded, committed handoff outcome.
- Commit enqueue loss is recoverable without duplicate customer action.
- `resolution_request` cannot be produced in the first release.
- Audience and availability are enforced by application code.
- Routine logs contain no webhook secret, model key or raw payload.
- Context omits unnecessary Contact PII and preserves sender type.
- Nonterminal turn pins prevent premature KnowledgeIndex cleanup.
- Runtime kill switch suppresses new replies immediately.

### 13.6 Knowledge and reply quality

- Supported question returns grounded, version-pinned evidence and one reply.
- Unsupported question returns no fabricated answer and executes the configured
  handoff.
- Account and Assistant Knowledge Scope substitution is rejected.
- Citation/provenance fields survive to AITurn evidence and visitor-safe output.

### 13.7 Regression boundary

- Representative non-managed Web Widget, Email, API Inbox, WhatsApp, SMS/Twilio,
  Facebook/Instagram and Telegram writes preserve upstream behavior.
- An unbound Web Widget write takes only the short Inbox row lock needed to linearize
  first binding activation; it takes no ChatRing Conversation or ledger lock. Other
  unbound channel writers take no ChatRing lock. Ownership and binding transitions
  cannot race the scoped predicate.
- AgentBot, Dialogflow and existing external-bot behavior remains compatible.

### 13.8 Runtime proof

- Full focused and repository-wide CI is green.
- Exact Rails and Sidekiq image digest is deployed.
- VPS lifecycle suite passes against real PostgreSQL/Redis and the private DocsGPT
  service.
- Concurrency 10 produces no duplicate/stale response and no tenant crossover.
- Rails/Sidekiq/DocsGPT log scan is clean.
- Manual fresh-widget supported, unsupported and immediate-takeover scenarios pass.

---

## 14. V2.1 override map

The following v2.1 statements are replaced by this contract:

| V2.1 area | Replacement |
|---|---|
| Header architecture mode | Internal control plane for current deployment |
| Executive diagram | Section 1.1 of this contract |
| AgentBot as webhook ingress for internal mode | AgentBot is native owner/sender; Section 4 |
| No competing bot handlers | Full template/automation arbitration; Section 5 |
| Webhook unavailability as redelivery concern | Native webhook failure mutates state; self-webhook removed |
| Binding replacement invalidates old turns | Drain and hand off old-bot Conversations; Section 7.3 |
| Global qualifying-writer serialization | Scoped managed-Conversation serialization; Section 6.7 |
| Conditional HTTP endpoint required for current runtime | Direct guarded service is authoritative in internal mode |
| Section 21.7 service/barrier sufficiency | Full native lifecycle topology in Sections 12–13 |
| Locked external integration decision | Replaced by the explicit one-mode rule in Section 4 |
| Verification record declaring runtime boundary complete | Reopened until Section 13 passes |

All v2.1 tool, memory, identity-assurance and later-channel stages remain deferred.
They may proceed only after this remediation is complete and the gate is reopened.

---

## 15. Definition of done

The corrected Web Widget response loop is complete only when:

1. Chatwoot owns status, assignment, templates, automation, Message and delivery.
2. One internal post-template path creates each AITurn; no public self-webhook exists.
3. Native response precedence is deterministic and tested.
4. Conflicting automation cannot coexist silently.
5. AgentBot is the exact account-owned Inbox bot and Message sender.
6. Assignment, takeover, handoff, disable and rebind preserve native behavior.
7. Shared serialization affects only managed-Assistant Conversations and prevents
   stale/duplicate replies.
8. Reply and handoff are durable, idempotent, auditable customer-affecting commits.
9. Brain eligibility enforces audience, hours, ownership, freshness and kill switches.
10. Context is minimized and speaker-accurate.
11. Failure is bounded and reaches the configured safe outcome.
12. Phase 2A retrieval remains account/scope isolated and turn pins protect evidence.
13. Every Section 13 CI, VPS and manual test passes on the exact deployed image.
14. Only then is the Web Widget public-response gate set to true.

Additional channels remain disabled until each channel's native message semantics pass
the same lifecycle, serialization, takeover and delivery suite.

---

## 16. Source evidence map

### Chatwoot CE/current ChatRing

- Approved Widget writer: [`app/controllers/api/v1/widget/messages_controller.rb`](../../app/controllers/api/v1/widget/messages_controller.rb)
- Approved dashboard public-reply writer: [`app/controllers/api/v1/accounts/conversations/messages_controller.rb`](../../app/controllers/api/v1/accounts/conversations/messages_controller.rb)
- Narrow serialization wrapper: [`app/services/chat_ring/conversation_write_boundary.rb`](../../app/services/chat_ring/conversation_write_boundary.rb)
- Native template order: [`app/services/message_templates/hook_execution_service.rb`](../../app/services/message_templates/hook_execution_service.rb)
- AgentBot event selection and webhook enqueue: [`app/listeners/agent_bot_listener.rb`](../../app/listeners/agent_bot_listener.rb)
- AgentBot webhook retry/logging: [`app/jobs/agent_bots/webhook_job.rb`](../../app/jobs/agent_bots/webhook_job.rb)
- Webhook failure transition: [`lib/webhooks/trigger.rb`](../../lib/webhooks/trigger.rb)
- Async automation ordering: [`app/dispatchers/async_dispatcher.rb`](../../app/dispatchers/async_dispatcher.rb)
- Automation actions: [`app/services/automation_rules/action_service.rb`](../../app/services/automation_rules/action_service.rb)
- Native assignment: [`app/services/conversations/assignment_service.rb`](../../app/services/conversations/assignment_service.rb)
- Managed provisioning/self-webhook: [`app/services/chat_ring/assistant_provisioning/agent_bot_provisioner.rb`](../../app/services/chat_ring/assistant_provisioning/agent_bot_provisioner.rb)
- Current conflict detector: [`app/services/chat_ring/assistant_provisioning/inbox_conflict_detector.rb`](../../app/services/chat_ring/assistant_provisioning/inbox_conflict_detector.rb)
- Current rebind: [`app/services/chat_ring/assistant_provisioning/inbox_binding_activator.rb`](../../app/services/chat_ring/assistant_provisioning/inbox_binding_activator.rb)
- Current eligibility: [`app/services/chat_ring/brain/eligibility.rb`](../../app/services/chat_ring/brain/eligibility.rb)
- Current context: [`app/services/chat_ring/brain/context_builder.rb`](../../app/services/chat_ring/brain/context_builder.rb)
- Current commit path: [`app/jobs/chat_ring/outbound_commit_job.rb`](../../app/jobs/chat_ring/outbound_commit_job.rb)
- Guarded service: [`app/services/conversations/agent_bot_conditional_commit_service.rb`](../../app/services/conversations/agent_bot_conditional_commit_service.rb)
- Current fallback gap: [`app/services/chat_ring/brain/failure_finalizer.rb`](../../app/services/chat_ring/brain/failure_finalizer.rb)
- Public-response gate: [`app/services/chat_ring/assistant_spike.rb`](../../app/services/chat_ring/assistant_spike.rb)

### Upstream and Captain pattern verification

- Upstream ownership baseline: [`chatwoot/chatwoot@f125291`](https://github.com/chatwoot/chatwoot/commit/f12529105bff8b16793c836bde5bfe1ba7e2f470)
- Deployed ChatRing merge: [`noomi456/chatwoot@0309e77`](https://github.com/noomi456/chatwoot/commit/0309e77ea7954dec5185dc480f31dab610b468d4)

Captain was inspected read-only to identify which CE seams it extends. No Enterprise
source is an implementation dependency or permitted production source.

---

## 17. Audit limitation

This contract is based on a static, source-level lifecycle audit of the exact deployed
tree, upstream ownership baseline, v2.1 and Captain's integration seams. It is not
runtime proof of the corrected design because remediation has not yet been
implemented. Runtime claims begin only after Section 13 passes.
