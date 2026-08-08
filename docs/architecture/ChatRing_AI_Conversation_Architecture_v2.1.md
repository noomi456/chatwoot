# ChatRing AI Conversation Architecture

## Implementation Specification v2.1

**Status:** Implementation Ready - Locked Architecture Boundary  
**Architecture mode:** External ChatRing AI runtime integrated with Chatwoot AgentBot, with a Chatwoot-side conditional commit and shared per-conversation serialization boundary  
**Verified against:** `chatwoot/chatwoot` `develop` at commit `f12529105bff8b16793c836bde5bfe1ba7e2f470`  
**Verification date:** 2026-08-07  

---

## 1. Executive Decision

ChatRing adds AI intelligence to Chatwoot without creating a parallel conversation system.

The architecture is based on six hard ownership rules:

1. **Chatwoot owns the customer-service conversation system.** Accounts, inboxes, channels, contacts, contact-inbox identities, conversations, messages, attachments, human agents, teams, assignment, conversation status, AgentBot ownership, and customer-channel delivery remain authoritative in Chatwoot.
2. **ChatRing Workspace owns AI-business configuration.** Knowledge, Assistants, AI memories, external integration connections, tool grants, AI policy, turn records, authorization decisions, and AI audit records belong to ChatRing.
3. **Chatwoot AgentBot is an integration and conversation-ownership principal, not the AI Assistant.** It is the Chatwoot identity used to receive events, own bot-handled conversations, and persist bot messages.
4. **ChatRing Assistant is the role and permission profile.** It defines who the AI is, how it behaves, what knowledge it may use, which tools it may request, when it participates, and when it must hand off.
5. **ChatRing Brain is the shared reasoning engine.** The Brain does not become a Support Brain, Sales Brain, or Billing Brain. The active Assistant configures the role for the current turn.
6. **The LLM is never an authorization or conversation-state boundary.** Application code verifies permissions, identity assurance, tenant scope, conversation ownership, freshness, and idempotency before any sensitive action is committed.

The implementation is therefore:

```text
Customer
   |
   v
Chatwoot
   |  conversation + message + ownership authority
   v
Chatwoot AgentBot
   |  signed webhook
   v
ChatRing Event Ingress
   |
   v
Inbox/Assistant Binding
   |
   v
ChatRing Assistant
   |
   v
ChatRing Brain
   |
   +--> Knowledge Service
   +--> Contact Memory Service
   +--> Authorization / Tool Gateway --> External Systems
   |
   v
Final Commit Gate
   |
   v
Chatwoot Conditional Commit + Serialization Boundary
   |
   v
Chatwoot Message / Handoff / State
   |
   v
Customer
```

### 1.1 Production readiness condition

This specification is implementation-ready and the architecture boundary is locked for the first implementation.

**Production activation condition:** public AI replies must not be enabled until the Chatwoot-side conditional commit path in Section 15 and the shared per-conversation serialization invariant are implemented and the concurrency tests in Section 21.7 pass.

A Chatwoot `Conversation` row lock held only by the AI conditional-commit endpoint is **not sufficient**. At the verified Chatwoot commit, ordinary `Message` creation inserts the message without taking that Conversation lock, and conversation activity/state callbacks run after the message has committed. Therefore a qualifying incoming customer message or public human reply could otherwise commit between the AI freshness check and the AI message insert.

The required property is that the AI conditional commit and every message write that can supersede the trigger participate in the same database-backed per-conversation serialization/version boundary, so no qualifying public message can commit between freshness validation and AI message commit.

---

## 2. Scope

### 2.1 In scope

This document defines the implementation boundary for:

- Chatwoot Account to ChatRing Workspace tenancy.
- Inbox and AgentBot provisioning.
- Inbox to Assistant binding.
- AI eligibility and conversation ownership.
- Assistant configuration and versioning.
- Shared Business Knowledge and Assistant knowledge scopes.
- Contact context and AI memory.
- Channel identity evidence and business identity assurance.
- Signed AgentBot webhook ingress.
- Event deduplication and ordering.
- AI turn creation and idempotency.
- Context assembly and retrieval.
- Tool selection, authorization, and execution.
- Human handoff.
- Final reply freshness and ownership checks.
- Atomic Chatwoot-side conditional commit with shared per-conversation serialization.
- Failure handling and recovery.
- Audit, observability, security, privacy, and implementation acceptance tests.

### 2.2 Out of scope

The following are deliberately not reimplemented by ChatRing:

- Customer channel adapters.
- Chatwoot contact management.
- Chatwoot conversation storage.
- Chatwoot message delivery.
- Human agent and team management.
- Chatwoot queue UI behavior.
- Chatwoot working-hours implementation.
- A second conversation-state machine.
- A second customer identity record replacing Chatwoot Contact.

---

## 3. Architecture Principles and Invariants

These are implementation invariants, not design preferences.

### 3.1 Conversation authority

> If a fact determines where a customer conversation exists, who currently owns it, what its status is, which messages exist, or how a reply reaches the customer, Chatwoot is authoritative.

ChatRing may cache identifiers and bounded snapshots for execution, but any mutation to conversation ownership or customer-visible messaging must be committed through Chatwoot.

### 3.2 AgentBot is not Assistant

`AgentBot` is a Chatwoot-side integration/ownership identity.

`Assistant` is a ChatRing-side role, policy, knowledge-scope, and capability profile.

They must never be represented as the same database entity.

**Implementation decision:** each active ChatRing Assistant has one Chatwoot AgentBot identity within its linked Chatwoot Account. The same Assistant/AgentBot pair may serve multiple compatible Chatwoot Inboxes. An Inbox may have at most one active ChatRing Assistant binding.

**Hard tenant invariant:** a ChatRing Assistant may only be connected to an AgentBot whose `account_id` is non-null and exactly equals the Workspace's `chatwoot_account_id`. A system/global AgentBot (`account_id = NULL`) and an AgentBot owned by another Account must be rejected. Chatwoot's `AgentBot.accessible_to(account)` includes global/system AgentBots, so "accessible to this Account" must never be treated as proof that the AgentBot belongs to the Workspace.

This gives the Chatwoot queue and ownership UI a bot identity that matches the active Assistant role while still allowing one Assistant to serve multiple Inboxes.

### 3.3 No parallel customer-service data model

ChatRing stores foreign identifiers such as:

- `chatwoot_account_id`
- `chatwoot_inbox_id`
- `chatwoot_agent_bot_id`
- `chatwoot_contact_id`
- `chatwoot_contact_inbox_id`
- `chatwoot_conversation_id`
- `chatwoot_message_id`

These references do not make ChatRing the owner of those records.

### 3.4 No prompt-based security

Assistant instructions such as "do not refund" are behavior guidance only.

Tool/action authorization must be independently checked by application code for:

- Workspace scope.
- Assistant grant.
- Integration connection ownership.
- Contact/identity assurance.
- Conversation state.
- Operation-specific policy.
- Approval requirement.
- Credential scope.

### 3.5 No unbounded context

The Brain receives the minimum relevant context for the turn.

Previous conversations, large knowledge collections, and long-term memory are retrieved on demand and are not injected wholesale into every prompt.

### 3.6 No competing bot handlers

A ChatRing binding must not be activated for an Inbox when another external AgentBot, Dialogflow handler, Captain handler, or other AI automation is configured to respond to the same conversation path.

Provisioning must fail closed on a detected conflict.

### 3.7 Pending status alone is not AI ownership

Chatwoot `pending` is not treated as a universal synonym for "ChatRing owns this conversation."

For a ChatRing turn, AI ownership requires all of the following:

```text
conversation.status == pending
AND
conversation.assignee_agent_bot_id == expected ChatRing AgentBot ID
AND
active InboxAssistantBinding exists
AND
binding Assistant matches expected Assistant
```

---

## 4. System Context and Ownership

### 4.1 Chatwoot Account

A Chatwoot Account is the authoritative customer-service tenant.

It owns operational entities including:

- Contacts.
- ContactInboxes.
- Inboxes and Channels.
- Conversations.
- Messages and attachments.
- Human users and teams.
- AgentBots.
- Conversation assignment and status.
- Working hours and delivery behavior.

### 4.2 ChatRing Workspace

A ChatRing Workspace is the AI/business-configuration tenant linked one-to-one with a Chatwoot Account.

```text
ChatRing Workspace
  id
  chatwoot_account_id  UNIQUE
  status
  policy_version
  created_at
  updated_at
```

It owns:

- Assistants.
- Assistant versions.
- Knowledge sources/documents/chunks.
- Assistant knowledge scopes.
- External integration connections.
- Tool catalog references and Assistant grants.
- AI contact memory.
- Identity-assurance records managed by ChatRing.
- Webhook-delivery records.
- AI turn records.
- Tool/action execution audit.
- Final commit records.

### 4.3 Ownership matrix

| Capability / Data | Source of truth | Notes |
|---|---|---|
| Account | Chatwoot | ChatRing references by `chatwoot_account_id`. |
| Inbox / Channel | Chatwoot | Channel delivery remains entirely Chatwoot. |
| Contact | Chatwoot | ChatRing does not create a parallel authoritative Contact. |
| ContactInbox / source identity | Chatwoot | Includes channel-specific identity evidence such as HMAC verification. |
| Conversation | Chatwoot | Includes status, owner, team, priority, and queue state. |
| Incoming / outgoing messages | Chatwoot | Final customer-visible AI reply is a normal Chatwoot message. |
| Human agent / team | Chatwoot | ChatRing may request handoff; Chatwoot records it. |
| AgentBot identity | Chatwoot | Integration and bot ownership principal. |
| Bot conversation ownership | Chatwoot | `assignee_agent_bot_id` is authoritative. |
| ChatRing Workspace | ChatRing | AI tenant linked to Chatwoot Account. |
| Inbox to Assistant binding | ChatRing | Anchored to Chatwoot Inbox and AgentBot IDs. |
| Assistant role / behavior | ChatRing | Versioned configuration. |
| Assistant tool grants | ChatRing | Enforced server-side. |
| Assistant knowledge scope | ChatRing | Grants over canonical business knowledge. |
| Canonical Business Knowledge | ChatRing / Business | Shared source, not copied per Assistant. |
| AI contact memory | ChatRing | Keyed to Chatwoot Contact ID. |
| External integration credentials | ChatRing secret store | Never placed in LLM prompt. |
| Tool implementation/catalog | ChatRing platform | Workspace connections expose configured capabilities. |
| Tool selection | ChatRing Brain | Selection is not authorization. |
| Tool authorization | ChatRing authorization gateway | Server-side hard boundary. |
| Business identity assurance | ChatRing identity policy | Consumes Chatwoot/channel evidence and stronger verification when required. |
| Webhook authentication/idempotency | ChatRing ingress | Signature, timestamp, delivery ID, payload hash. |
| Final AI-send authorization | ChatRing commit gate + Chatwoot conditional commit/serialization boundary | Both layers are required. |
| Final message persistence | Chatwoot | Conditional commit creates the Chatwoot message inside the shared serialization boundary. |

---

## 5. Chatwoot Repository Mapping

This architecture was verified against `chatwoot/chatwoot` `develop` at commit `f12529105bff8b16793c836bde5bfe1ba7e2f470`.

The following repository behavior is treated as the integration contract at that commit:

| Repository artifact | Verified architectural meaning |
|---|---|
| `app/models/account.rb` | Account owns contacts, conversations, messages, inboxes, AgentBots, teams, channels, and related operational records. |
| `app/models/inbox.rb` | Inbox belongs to Account/Channel and has one AgentBot association through `agent_bot_inbox`. |
| `app/models/conversation.rb` | Conversation stores `assignee_agent_bot_id`; assigned/unassigned semantics include AgentBot ownership; bot handoff clears bot ownership and opens the conversation. |
| `app/services/conversations/assignment_service.rb` | AgentBot assignment is performed under a DB lock, clears human assignee, and sets `pending`; human takeover clears AgentBot and can reopen bot-owned pending conversation. |
| `app/models/agent_bot_inbox.rb` | Inbox/AgentBot binding has active/inactive state and Account scope. |
| `app/listeners/agent_bot_listener.rb` | Chatwoot sends conversation/message events to active/assigned AgentBots via webhook. |
| `lib/webhooks/trigger.rb` | AgentBot webhook requests include delivery ID and, when secret exists, timestamp plus HMAC signature; selected failures are retryable. |
| `app/presenters/conversations/event_data_presenter.rb` | Conversation webhook metadata contains assignee type and `hmac_verified` channel identity evidence. |
| `app/controllers/concerns/access_token_auth_helper.rb` | AgentBot tokens can access selected conversation mutation endpoints; therefore ChatRing requires its own finer authorization boundary. |
| `app/controllers/api/v1/accounts/conversations/messages_controller.rb` | Normal message create delegates directly to `Messages::MessageBuilder`; no atomic expected-owner/freshness precondition is enforced here. |
| `app/builders/messages/message_builder.rb` | Normal message creation builds and saves the `Message` without acquiring the Conversation row lock; AgentBot sender lookup also permits account-owned or system/global AgentBots. |
| `app/models/message.rb` | Message conversation/activity/state work is dispatched from `after_create_commit`; it does not serialize the message insert with a Conversation lock before commit. |
| `app/controllers/api/v1/accounts/agent_bots_controller.rb` | Account-created AgentBots are account-owned, but `show/index` may use `AgentBot.accessible_to`, which includes system/global AgentBots. |
| `app/policies/conversation_policy.rb` | AgentBot conversation access is broad; it is not a per-Assistant fine-grained authorization model. |
| `enterprise/app/models/captain/assistant.rb` | Captain demonstrates account-scoped Assistant configuration with guardrails, audience/schedule behavior, tools, documents, and Inbox associations. |
| `enterprise/app/models/captain_inbox.rb` | Captain enforces one Assistant per Inbox while allowing one Assistant to be associated with multiple Inboxes. |
| `enterprise/app/jobs/captain/conversation/response_builder_job.rb` | Captain demonstrates repeated `pending` and newer-message checks to reduce stale responses. |

### 5.1 Compatibility rule

ChatRing must pin and test against a known Chatwoot version/commit range. Any Chatwoot upgrade that changes:

- AgentBot webhook headers.
- AgentBot assignment behavior.
- Conversation ownership fields.
- Message create behavior.
- AgentBot token permissions.
- Conversation status semantics.

must trigger the compatibility test suite in Section 21 before deployment.

---

## 6. Core ChatRing Components

### 6.1 Workspace Service

Responsibilities:

- Maintain one ChatRing Workspace per linked Chatwoot Account.
- Enforce tenant isolation.
- Resolve Chatwoot Account ID to Workspace ID at ingress.
- Own workspace-level AI policy and feature switches.
- Provide the scope root for every query and authorization decision.

Hard rule: no Workspace query may be resolved only by a conversation/message ID without first binding that ID to the verified Chatwoot Account/Workspace context.

### 6.2 Assistant Service

An Assistant is a versioned role/security configuration.

An Assistant owns:

- Name and customer-facing identity.
- Role/purpose.
- Goals.
- Instructions.
- Response guidelines.
- Guardrails.
- Audience policy.
- Availability policy.
- Handoff policy.
- Knowledge scope.
- Tool grants.
- Identity requirements per operation class.
- Escalation rules.

It does not own:

- Chatwoot conversation state.
- Chatwoot customer messages.
- Integration credentials.
- Tool implementation code.
- The central LLM runtime.

Assistant changes are versioned. Each AI turn records the exact Assistant version used so the turn can be audited later.

### 6.3 Chatwoot AgentBot Connection

Each active Assistant has one Chatwoot AgentBot connection within the Workspace's Chatwoot Account.

Activation and connection health checks must fetch the AgentBot from Chatwoot and require `agent_bot.account_id IS NOT NULL` and `agent_bot.account_id == workspace.chatwoot_account_id`. `AgentBot.accessible_to` is a discovery/access scope, not an ownership assertion.

Recommended model:

```text
AssistantAgentBotConnection
  id
  workspace_id
  assistant_id              UNIQUE
  chatwoot_agent_bot_id     UNIQUE within workspace
  access_token_secret_ref
  webhook_secret_ref
  status
  last_verified_at
```

Secrets are references to a secret manager; raw credentials are not stored in prompt-visible application tables or logs.

### 6.4 InboxAssistantBinding

This is the deployment boundary for AI.

```text
InboxAssistantBinding
  id
  workspace_id
  chatwoot_inbox_id
  assistant_id
  assistant_agent_bot_connection_id
  status                   active | inactive
  binding_version
  created_at
  updated_at
```

Constraints:

- Unique active binding per `(workspace_id, chatwoot_inbox_id)`.
- Connection must belong to the same Workspace and Assistant.
- Chatwoot Inbox must belong to the linked Chatwoot Account.
- Chatwoot AgentBot must have non-null `account_id` exactly equal to the Workspace `chatwoot_account_id`.
- System/global AgentBots (`account_id = NULL`) are never valid ChatRing Assistant identities.
- Chatwoot AgentBot must be connected to that Inbox and active.
- Activation fails if a conflicting bot/AI handler is detected.

### 6.5 Event Ingress

Responsibilities:

- Receive Chatwoot AgentBot webhook events.
- Verify signature and timestamp.
- Deduplicate `X-Chatwoot-Delivery`.
- Resolve Workspace and AgentBot connection.
- Validate Account/Inbox/AgentBot binding.
- Persist an immutable ingress audit record.
- Enqueue only eligible event types for AI processing.

The ingress layer does not call the LLM directly.

### 6.6 ChatRing Brain

The Brain is a shared execution runtime that:

- Interprets the customer's request.
- Applies the active Assistant role.
- Decides which context is relevant.
- Requests knowledge retrieval.
- Requests previous-conversation retrieval when relevant.
- Selects candidate tools.
- Reasons over structured tool results.
- Produces a decision: reply, clarification, tool request, verification request, handoff, resolution request, or safe abstention.

The Brain does not:

- Bypass the authorization gateway.
- Hold integration credentials.
- Directly update Chatwoot ownership.
- Directly persist a customer-visible message.

### 6.7 Authorization and Tool Gateway

The gateway is the security enforcement boundary.

For every requested tool/action it independently checks:

```text
Workspace scope
   +
Assistant grant
   +
Integration connection scope
   +
Identity assurance requirement
   +
Conversation state requirement
   +
Operation policy
   +
Approval requirement
   +
Credential scope
```

Only after all checks pass is the tool executed.

### 6.8 Final Commit Gate

The ChatRing-side gate verifies that an AI result is still eligible to be committed.

It then calls the Chatwoot-side conditional commit path, which repeats authoritative checks inside the shared database-backed per-conversation serialization/version boundary and persists the message only if all conditions still hold. A Conversation row lock used only by this endpoint is insufficient.

---

## 7. Knowledge Architecture

### 7.1 Canonical Business Knowledge

The Workspace owns one canonical logical Business Knowledge Base.

```text
Workspace Knowledge
  |
  +-- Website content
  +-- Product documentation
  +-- Pricing
  +-- Policies
  +-- Help articles
  +-- Manuals
  +-- Uploaded files
  +-- Internal approved procedures
```

Knowledge is not duplicated in full for every Assistant.

### 7.2 Assistant knowledge scope

Every Assistant receives an explicit scope over canonical knowledge.

Examples:

```text
Support Assistant
  allow: public product docs, support policies, troubleshooting
  deny: internal pricing approvals, legal-only documents

Sales Assistant
  allow: product catalog, plans, approved pricing, sales playbooks
  deny: private support notes, restricted legal docs
```

Default business-wide access may be configured, but the data model must support deny/restrict scopes from day one.

### 7.3 Retrieval rules

- Retrieve only relevant chunks/evidence.
- Enforce Workspace and Assistant scope before vector/text retrieval results are returned.
- Tag each returned item with document/chunk IDs and source metadata.
- Do not trust the LLM to remove unauthorized retrieved content after the fact.
- Do not place the full knowledge corpus into the prompt.
- Separate stable factual knowledge from live customer/business state.

### 7.4 Live data is not knowledge

Order status, inventory, subscription status, appointment availability, CRM state, and similar changing/customer-specific data are tools, not static knowledge.

---

## 8. Contact Context, Identity Evidence, and Assurance

### 8.1 Chatwoot Contact context

Chatwoot provides the authoritative Contact and ContactInbox relationship.

The Brain may receive relevant fields such as:

- Chatwoot Contact ID.
- Name.
- Email.
- Phone number.
- Identifier.
- Custom attributes approved for AI use.
- Inbox/source identity.
- Channel identity evidence.

### 8.2 Channel identity evidence

Chatwoot webhook conversation metadata may contain `hmac_verified` from ContactInbox.

This is **evidence**, not a universal authorization result.

A verified web-widget HMAC can support confidence that the widget user identity was signed by the integrating application. It does not by itself establish that the user may perform every sensitive business action.

### 8.3 ChatRing business identity assurance

ChatRing evaluates action-specific assurance.

Recommended assurance levels:

| Level | Meaning | Example use |
|---|---|---|
| A0 | Unverified / anonymous | Public FAQ, product information. |
| A1 | Channel-bound identity evidence | Low-risk account context where policy allows. |
| A2 | Verified customer claim | Order lookup, private subscription status. |
| A3 | Strong / step-up verification or human approval | Refund, cancellation, account security change. |

The exact verification method is integration-specific and may include signed application session, OTP, authenticated portal assertion, CRM match, or human approval.

Suggested record:

```text
IdentityAssurance
  workspace_id
  chatwoot_contact_id
  chatwoot_contact_inbox_id
  assurance_level
  verified_claims_json
  verification_method
  verified_at
  expires_at
  evidence_reference
```

The LLM consumes the resulting trusted assurance state; it does not decide whether an arbitrary email or order number written in a message proves identity.

---

## 9. Contact Memory

AI long-term memory belongs to the Workspace and is keyed to Chatwoot Contact ID.

Memory is distinct from Chatwoot Contact attributes and distinct from conversation history.

Examples:

- Communication preference learned from prior interactions.
- Stable product/account context approved for retention.
- Previously confirmed recurring issue.

Rules:

- Store only policy-allowed memory.
- Store provenance and timestamp.
- Apply retention/expiry rules.
- Do not convert sensitive transient facts into durable memory by default.
- Retrieve only relevant memory per turn.
- Never use memory to override fresher authoritative tool data.

---

## 10. Webhook Ingress, Authentication, and Idempotency

### 10.1 Required headers

ChatRing expects AgentBot webhooks with:

- `X-Chatwoot-Delivery`.
- `X-Chatwoot-Timestamp` when a webhook secret is configured.
- `X-Chatwoot-Signature` when a webhook secret is configured.

### 10.2 Verification algorithm

For every request:

1. Resolve the receiving AgentBot connection from the webhook endpoint/route configuration.
2. Read the raw request body exactly as received.
3. Require a delivery ID.
4. Require timestamp and signature for production connections.
5. Reject timestamps outside the configured replay window. Recommended default: 5 minutes.
6. Parse `X-Chatwoot-Signature` exactly as `sha256=<hex_digest>`. Reject a missing `sha256=` prefix, unsupported algorithm, empty digest, or malformed hexadecimal digest.
7. Compute `expected_hex_digest = HMAC-SHA256(secret, timestamp + "." + raw_body)` using the raw body bytes and the exact `X-Chatwoot-Timestamp` string.
8. Constant-time compare the received `<hex_digest>` with `expected_hex_digest`; reject on mismatch.
9. Resolve payload Account/Inbox to the same Workspace/connection.
10. Re-verify that the connected AgentBot has non-null `account_id` exactly equal to the Workspace's `chatwoot_account_id`.
11. Calculate and store a body hash for audit.
12. Insert the delivery record using a unique constraint on delivery ID.
13. If the delivery already exists with the same body hash, return success without reprocessing.
14. If the same delivery ID appears with a different body hash, reject and alert.

At the pinned Chatwoot commit, the sender format is `X-Chatwoot-Signature: sha256=<hex HMAC>` over `timestamp + "." + raw JSON body`.

### 10.3 WebhookDelivery record

```text
WebhookDelivery
  delivery_id              PRIMARY/UNIQUE external key
  workspace_id
  assistant_agent_bot_connection_id
  event_type
  payload_account_id
  payload_inbox_id
  payload_conversation_id
  payload_message_id
  payload_hash
  received_at
  verification_status
  processing_status
  error_code
```

### 10.4 Events eligible to trigger an AI turn

The primary trigger is a Chatwoot `message_created` event where the message is an incoming, customer-originated message and the conversation is currently eligible for ChatRing.

Conversation status/assignment events are processed for state synchronization and cancellation but do not independently generate customer replies unless an explicit product flow requires it.

### 10.5 Webhook payloads are not final authority

After ingress verification, ChatRing must re-read current Chatwoot conversation state before starting the AI turn.

A valid signed webhook can still describe state that became stale between event creation and processing.

---

## 11. AI Eligibility

Before starting a turn, ChatRing verifies all of the following:

```text
Workspace active
AND
InboxAssistantBinding active
AND
Assistant active
AND
AssistantAgentBotConnection active
AND
connected AgentBot.account_id IS NOT NULL
AND
connected AgentBot.account_id == Workspace chatwoot_account_id
AND
payload Account == Workspace Chatwoot Account
AND
payload Inbox == binding Inbox
AND
no conflicting AI/bot handler
AND
fresh Chatwoot conversation.status == pending
AND
fresh conversation.assignee_agent_bot_id == expected AgentBot
AND
incoming trigger message still exists
AND
trigger message is customer/incoming/public
AND
Assistant audience policy matches
AND
Assistant availability policy matches
AND
conversation is not resolved or snoozed
AND
no completed AI turn already exists for trigger message
```

If any condition fails, no LLM call is made.

### 11.1 Human takeover

Human takeover is represented by Chatwoot ownership/state changes, not by a ChatRing boolean.

When a human takes over, ChatRing must cancel or invalidate any in-flight turn that has not committed.

A cancellation signal is an optimization. The final authoritative prevention is the Chatwoot-side conditional commit plus authoritative ownership and shared per-conversation serialization checks.

---

## 12. AI Turn Model and Context Assembly

### 12.1 AITurn record

```text
AITurn
  id
  workspace_id
  chatwoot_conversation_id
  trigger_message_id
  inbox_assistant_binding_id
  binding_version
  assistant_id
  assistant_version
  expected_agent_bot_id
  status
  started_at
  completed_at
  decision_type
  failure_code
```

Recommended unique constraint:

```text
UNIQUE(workspace_id, chatwoot_conversation_id, trigger_message_id)
```

This prevents duplicate webhook deliveries from creating duplicate AI replies for the same customer message.

### 12.2 Base context

The Brain receives:

1. ChatRing core system policy.
2. Active Assistant version.
3. Triggering customer message.
4. A bounded current public conversation window or summary.
5. Trusted Contact context.
6. Current identity-assurance result.
7. Relevant Contact memory.
8. Relevant authorized Business Knowledge evidence.
9. Authorized tool schemas only.
10. Runtime metadata required for safe decision-making, without secrets.

### 12.3 Previous conversations

Previous conversations are retrieved on demand.

The retrieval operation must:

- Scope to the same Workspace/Chatwoot Account.
- Scope to the same Chatwoot Contact.
- Return only relevant conversations or bounded summaries.
- Respect retention/privacy policy.
- Exclude private/internal notes unless the Assistant is explicitly permitted to use them.

### 12.4 Prompt separation

The runtime should preserve conceptual layers:

```text
Core System Policy
  "How ChatRing AI must operate"

Assistant Configuration
  "Who the AI is and how it should behave"

Retrieved Evidence
  "What facts are relevant to this turn"

Tool Results
  "What live/private state was authorized and returned"
```

---

## 13. Tool Architecture

### 13.1 Three ownership layers

**Workspace owns integration connection**

Example: Shopify credentials/store association.

**Assistant receives tool grant**

Example: Support may look up orders but cannot issue refunds.

**Brain selects candidate tool**

Example: Customer asks "Where is my order?" and the Brain requests order lookup.

The authorization gateway still decides whether the requested operation is permitted.

### 13.2 Tool definition

Each tool should declare:

- Stable tool ID and version.
- Input schema.
- Output schema.
- Required integration type.
- Required Assistant grant.
- Required assurance level.
- Risk class.
- Whether human approval is required.
- Side-effect classification: read-only or mutating.
- Idempotency strategy for mutations.
- Timeout/retry behavior.
- Audit/redaction policy.

### 13.3 Tool execution flow

```text
Brain tool request
   |
   v
Schema validation
   |
   v
Workspace scope check
   |
   v
Assistant grant check
   |
   v
Identity assurance check
   |
   v
Conversation state check
   |
   v
Operation policy / approval check
   |
   v
Credential resolution
   |
   v
Tool execution
   |
   v
Structured result
   |
   v
Brain
```

### 13.4 Tool results

Tool results must be structured and bounded.

Credentials, access tokens, secret headers, raw provider debug payloads, and unrelated records must never be returned to the LLM.

### 13.5 Mutating tools

Mutating tools require an idempotency key derived from the AI turn plus operation intent where the downstream system supports it.

If the downstream system does not support idempotency, ChatRing must maintain an operation ledger and fail safe on ambiguous retry state.

---

## 14. Human Handoff

The Brain may request handoff, but Chatwoot owns the actual state transition.

```text
Brain
   |
   | handoff request + reason
   v
ChatRing Authorization Gateway
   |
   | validates grant/state
   v
Chatwoot
   |
   | bot handoff / assignment transition
   v
Human queue / agent / team
```

### 14.1 Handoff rules

Typical Assistant handoff triggers:

- Customer explicitly asks for a human.
- Required action is unavailable to the Assistant.
- Required identity assurance cannot be established.
- Human approval is required.
- Repeated tool/LLM failure.
- Policy or risk rule requires escalation.
- Conversation falls outside Assistant audience/availability while already active.

### 14.2 Post-handoff rule

After Chatwoot no longer shows the expected AgentBot as owner, ChatRing must not commit any public AI reply from an earlier in-flight turn.

Private audit/internal notes are separate operations and require their own explicit policy.

---

## 15. Final Commit and Atomic Chatwoot Guard

### 15.1 Why a Chatwoot-side guard is required

The normal external AgentBot flow allows an authenticated AgentBot to create an outgoing message through Chatwoot's message controller/builder. At the verified commit, that message-create path does not atomically assert that:

- The conversation is still `pending`.
- The calling/expected AgentBot is still the conversation owner.
- No newer customer message superseded the AI turn.
- No human public reply appeared after the trigger.
- The same AI turn has not already committed a reply.

An external preflight read cannot guarantee those conditions remain true until the subsequent create request commits.

There is a second race that a Conversation lock in the AI endpoint alone does not solve: ordinary Chatwoot `Message` creation saves the message without acquiring that same Conversation row lock, and message-driven conversation updates occur from `after_create_commit`. A qualifying customer/human message can therefore be inserted concurrently unless both write paths share a serialization/version boundary.

### 15.2 Required Chatwoot extension

Implement a Chatwoot-side service and API action specifically for conditional AgentBot commit.

Suggested service name:

```text
Conversations::AgentBotConditionalCommitService
```

Suggested request contract:

```text
conversation_id
expected_agent_bot_id
responding_to_message_id
idempotency_key
message:
  content
  content_type
  private=false
  allowed channel-specific message fields
```

The authenticated principal must be the same AgentBot as `expected_agent_bot_id`, and that AgentBot must have non-null `account_id` exactly equal to the conversation/Workspace Chatwoot Account. System/global AgentBots are rejected.

### 15.3 Mandatory per-conversation serialization invariant

The required correctness property is **not** merely "the conditional AI endpoint locks the Conversation row."

For each conversation, the following operations must participate in the same database-backed per-conversation serialization/version boundary:

- Conditional public AI message commit.
- Public incoming customer message writes that can supersede the trigger.
- Public outgoing human replies that can supersede the trigger, including any external-echo path Chatwoot treats as a human response.
- Any additional public message path that product policy defines as superseding an in-flight AI turn.

Private/internal notes participate only if product policy explicitly treats them as superseding.

The invariant is:

```text
No qualifying public message can commit
between:

freshness validation
        |
        v
AI public message commit
```

A Conversation row lock used only by the conditional AI endpoint is insufficient because normal message inserts do not acquire it at the pinned Chatwoot commit.

The implementation may use a shared Conversation row lock on **all** qualifying message writers, a transaction-scoped advisory lock, a conversation/message sequence or version with compare-and-swap semantics, a database trigger-backed mechanism, or another DB-backed strategy. The architecture intentionally does not prescribe the exact mechanism; it requires the serialization property and the tests in Section 21.7.

If a qualifying customer/human message wins the serialization order before the old AI commit, the old AI commit must fail as superseded. If the AI commit has already entered the serialization boundary first, the later qualifying message must not interleave between validation and AI insert; it is serialized after the AI commit. Product requirements that demand "human/customer always wins even after AI commit serialization has begun" require a stronger priority/cancellation design and are outside this minimum atomicity contract.

### 15.4 Conditional commit algorithm

Inside Chatwoot:

1. Resolve Account and Conversation through normal authenticated Account scope.
2. Verify the authenticated AgentBot has non-null `account_id` equal to the Conversation Account and matches `expected_agent_bot_id`.
3. Start a DB transaction.
4. Enter the shared per-conversation serialization/version boundary used by every qualifying public customer/human message writer.
5. Verify `conversation.status == pending`.
6. Verify `conversation.assignee_agent_bot_id == expected_agent_bot_id`.
7. Verify `responding_to_message_id` is an incoming customer message in this conversation.
8. Verify no newer qualifying incoming customer message exists after `responding_to_message_id`.
9. Verify no newer public outgoing human message exists after `responding_to_message_id`.
10. Verify the serialization sequence/version has not changed in a way that represents a superseding qualifying message, when the chosen mechanism uses version/CAS semantics.
11. Verify the idempotency key has not already produced a committed message.
12. Create the outgoing message with the authenticated AgentBot as sender **inside the same serialization boundary**.
13. Persist the idempotency/commit marker with the resulting message ID in the same transaction, or use a unique Chatwoot-side key attached to the created message if implemented that way.
14. Commit.
15. Return the Chatwoot message ID and final conversation state/serialization snapshot.

If any precondition fails, return a conflict/precondition error and **do not create a message**.

### 15.5 ChatRing preflight gate

ChatRing should still perform its own final gate before calling the conditional endpoint:

```text
AITurn still active
AND
binding active and same version
AND
Assistant still active and same version
AND
expected AgentBot unchanged
AND
no previous ChatRing commit record
AND
latest observed Chatwoot state appears eligible
```

This avoids unnecessary failed commit calls and produces clearer audit reasons.

### 15.6 Commit idempotency

Recommended ChatRing key:

```text
sha256("chatring:reply:" + workspace_id + ":" + ai_turn_id)
```

The same key is sent on all retries for that AI turn.

ChatRing records:

```text
OutboundCommit
  id
  ai_turn_id             UNIQUE
  idempotency_key        UNIQUE
  chatwoot_message_id
  status
  attempted_at
  committed_at
  failure_code
```

### 15.7 Conditional handoff

For the strongest consistency, provide a similar expected-owner check for bot-initiated handoff, either in a dedicated service or as an option on the existing handoff path:

- Conversation must be `pending`.
- Expected AgentBot must still own it.
- Authenticated AgentBot must match expected owner.
- Authenticated AgentBot must be account-owned by the Conversation Account; system/global AgentBots are rejected.

This prevents one AgentBot credential from handing off another bot's conversation accidentally.

## 16. Complete Runtime Flow

### Step 1 - Customer sends a message

Chatwoot receives the message through its existing Channel and creates/updates the normal Contact, ContactInbox, Conversation, and Message relationships.

### Step 2 - Chatwoot establishes bot handling state

For an active AgentBot Inbox, Chatwoot's existing ownership/assignment behavior places the bot-handled conversation into its bot ownership flow.

ChatRing does not synthesize an independent "AI owned" state.

### Step 3 - Chatwoot emits signed AgentBot webhook

Chatwoot sends the message event to the configured AgentBot webhook, including delivery/signature headers when configured.

### Step 4 - ChatRing verifies and deduplicates ingress

ChatRing Event Ingress validates signature, timestamp, delivery ID, Account/Inbox/AgentBot binding, and persists the delivery record.

Duplicates stop here.

### Step 5 - Resolve Workspace and binding

ChatRing resolves:

```text
Chatwoot Account
  -> ChatRing Workspace

Chatwoot Inbox
  -> active InboxAssistantBinding

Binding
  -> Assistant
  -> AssistantAgentBotConnection
```

### Step 6 - Re-read authoritative Chatwoot state

ChatRing fetches current conversation state rather than trusting the webhook snapshot.

It verifies expected AgentBot ownership, status, trigger message, and no conflicting handler.

### Step 7 - Evaluate Assistant audience and availability

The Assistant determines whether the conversation is in its configured audience and response window.

If not, ChatRing performs the configured no-AI behavior, normally handoff/open-human routing.

### Step 8 - Create idempotent AI turn

ChatRing inserts `AITurn` using the unique trigger-message constraint.

If a turn already exists, processing resumes or exits according to its state; a second turn is not created.

### Step 9 - Assemble bounded context

The runtime loads:

- Core system policy.
- Assistant version.
- Trigger message.
- Current conversation window.
- Contact context and channel identity evidence.
- Current ChatRing identity-assurance result.
- Relevant memory.
- Relevant scoped knowledge.
- Authorized tool definitions.

### Step 10 - Brain decides

Possible decisions:

- Reply.
- Ask clarification.
- Search additional knowledge.
- Retrieve prior conversation context.
- Request identity verification.
- Request a read-only tool.
- Request a mutating tool.
- Request handoff.
- Request conversation resolution.
- Safely abstain.

### Step 11 - Execute tools through authorization gateway

Every tool request is independently validated and executed outside the LLM.

Structured results return to the Brain.

### Step 12 - Produce final decision

The Brain produces a final customer reply or an authorized non-reply action such as handoff.

### Step 13 - ChatRing final preflight gate

ChatRing verifies binding/version/state/idempotency one final time.

### Step 14 - Atomic Chatwoot commit

For a reply, ChatRing calls the Chatwoot conditional commit service with:

- Expected AgentBot.
- Trigger message ID.
- Stable idempotency key.
- Final message payload.

Chatwoot enters the shared per-conversation serialization/version boundary, revalidates state/freshness, and creates the message inside that same boundary.

### Step 15 - Channel delivery

The committed message enters the normal Chatwoot outgoing-message/channel-delivery pipeline.

### Step 16 - Complete audit

ChatRing stores decision metadata, commit result, tool execution references, evidence IDs, and safe observability metrics.

---

## 17. Failure Handling and Recovery

| Failure | Required behavior |
|---|---|
| Invalid webhook signature | Reject; no AI turn; security event. |
| Webhook timestamp outside replay window | Reject; no AI turn. |
| Duplicate delivery ID, same payload | Return success/idempotent no-op. |
| Duplicate delivery ID, different payload | Reject and alert. |
| Workspace/binding not found | No AI processing; configuration alert. |
| Conflicting bot handler detected | Fail binding activation or hand off; never run two responders. |
| Chatwoot state says human owns conversation | Cancel/skip AI turn. |
| New customer message arrives during generation | If it commits/wins the shared serialization order before the old AI commit, invalidate the old turn commit and process the new message as a separate turn; it must never interleave between AI freshness validation and AI insert. |
| Human takes over during generation | Ownership transition and AI commit serialize on authoritative Chatwoot state; if takeover wins first, conditional commit returns precondition failure and the generated public reply is discarded. |
| Knowledge retrieval fails | Answer only if safe without missing facts; otherwise clarify/handoff. |
| Read-only tool times out | Retry within tool policy, then degrade/clarify/handoff. |
| Mutating tool result is ambiguous | Do not blindly retry; consult idempotency ledger/provider status. |
| LLM generation fails | Retry within bounded policy; then handoff or safe failure behavior. |
| Chatwoot conditional commit conflicts | Mark turn superseded/cancelled; do not retry with a new message. |
| Chatwoot transient commit error | Retry same idempotency key after rechecking turn state. |
| Chatwoot webhook endpoint unavailable | Chatwoot retry behavior may redeliver; delivery ID dedupe prevents duplicate turn. |

---

## 18. Security Model

### 18.1 Trust boundaries

**Untrusted / model-controlled**

- Customer message content.
- Retrieved web/business text unless source-controlled.
- LLM-generated tool arguments until validated.
- LLM decision text.

**Trusted application state**

- Workspace scope resolved from verified integration mapping.
- Chatwoot Account/Inbox/Conversation state read through authenticated APIs.
- Server-side Assistant grants.
- Identity-assurance result.
- Secret-manager credentials.
- Tool policy.
- Chatwoot conditional commit result.

### 18.2 Prompt injection containment

- Treat knowledge/tool outputs as data, not instructions that override system/Assistant policy.
- Never expose tool credentials to the model.
- Validate all tool arguments against schemas and policy.
- Use explicit allowlists for tool availability.
- Do not let retrieved content modify Assistant grants or identity assurance.
- Preserve separation between private tool results and customer-visible response.

### 18.3 Tenant isolation

Every ChatRing persistence query for customer-related AI data must include Workspace scope.

AgentBot ownership must be exact: `agent_bot.account_id` must be non-null and equal to the Workspace `chatwoot_account_id`. A system/global AgentBot that Chatwoot merely exposes through `accessible_to` is not a valid ChatRing tenant identity.

External IDs alone are insufficient authorization.

### 18.4 Secret handling

- Store AgentBot access tokens and webhook secrets in a secret manager or encrypted secret subsystem.
- Store only secret references in ordinary relational records.
- Never log raw secrets.
- Rotate secrets without changing Assistant identity.
- Support revocation and connection health checks.

### 18.5 Logging

Logs must redact:

- Access tokens.
- API keys.
- Authorization headers.
- OTPs and verification secrets.
- High-risk personal data according to policy.
- Full provider payloads when not necessary.

---

## 19. Observability and Audit

Every AI turn should be traceable without requiring raw chain-of-thought storage.

Record:

- Workspace ID.
- Chatwoot Account/Inbox/Conversation/trigger message IDs.
- Delivery ID.
- Assistant ID/version and binding version.
- Expected AgentBot ID.
- Turn timestamps and status transitions.
- Retrieved knowledge document/chunk IDs.
- Memory item IDs used.
- Tool IDs/versions requested and authorization outcomes.
- Identity-assurance level used.
- Final decision type.
- Handoff reason category if applicable.
- Commit idempotency key hash/reference.
- Resulting Chatwoot message ID.
- Failure/supersession reason.
- Model/provider metadata needed for cost/performance debugging, without hidden reasoning content.

Recommended metrics:

- Ingress verification failures.
- Duplicate deliveries.
- AI eligibility rejection reasons.
- Turn latency by phase.
- Knowledge/tool latency.
- Tool authorization denials.
- Human handoff rate and reason.
- Conditional commit conflict rate.
- Duplicate commit prevention count.
- AI reply success rate.
- LLM/tool error rate.
- Cost/token usage by Workspace/Assistant.

---

## 20. Provisioning and Configuration Lifecycle

### 20.1 Workspace linking

1. Administrator connects ChatRing to a Chatwoot Account.
2. ChatRing verifies authenticated Account identity.
3. Create or reuse the one-to-one Workspace mapping.
4. Store connection metadata and secrets securely.

### 20.2 Assistant creation

1. Create Assistant draft.
2. Configure role, guidelines, guardrails, audience, availability, handoff rules.
3. Assign knowledge scope.
4. Assign tool grants and required assurance levels.
5. Publish Assistant version.
6. Provision a Chatwoot AgentBot for the Assistant or link a previously provisioned matching AgentBot.
7. Fetch the AgentBot and require `account_id IS NOT NULL` and `account_id == workspace.chatwoot_account_id`; reject system/global or cross-Account AgentBots.
8. Store AgentBot connection and secret references.

### 20.3 Inbox activation

1. Select Chatwoot Inbox.
2. Verify Inbox belongs to Workspace's Chatwoot Account.
3. Re-verify the Assistant AgentBot is account-owned by that same Account and is not a system/global AgentBot.
4. Check existing AgentBot/Dialogflow/Captain/other responder conflicts.
5. Connect the Assistant's Chatwoot AgentBot to the Inbox.
6. Verify AgentBotInbox active state.
7. Create active `InboxAssistantBinding`.
8. Perform webhook health/signature test.
9. Perform controlled test conversation before production activation.

### 20.4 Assistant change on an Inbox

Switching Assistants must be transactional from ChatRing's perspective:

1. Mark old binding draining/inactive for new turns.
2. Prevent new AI turns on old binding.
3. Update Chatwoot Inbox AgentBot connection to the new Assistant AgentBot.
4. Create/activate new binding version.
5. Verify Chatwoot state.
6. Any old in-flight turn fails final binding/AgentBot checks and cannot commit.

---

## 21. Verification and Acceptance Test Matrix

Implementation must not be considered production-ready until the following tests pass.

### 21.1 Chatwoot ownership compatibility

- New ChatRing-enabled conversation becomes/appears bot-owned using the configured Assistant AgentBot.
- Bot-owned conversation has the expected Chatwoot status used by the integration.
- Human takeover clears AgentBot ownership and restores human/open handling as expected.
- Unassignment/assignment behavior does not accidentally recreate ChatRing ownership.
- Resolved and snoozed conversations do not receive ChatRing replies unless explicitly re-entered through a valid new eligible flow.

### 21.2 Webhook security/idempotency

- Valid `sha256=<hex_digest>` HMAC webhook accepted.
- Invalid HMAC rejected.
- Missing/unsupported signature algorithm prefix rejected.
- Malformed hexadecimal digest rejected.
- Expired timestamp rejected.
- Signature verification uses the exact raw body bytes and exact timestamp header string.
- Same delivery ID/same body processes once.
- Same delivery ID/different body is rejected.
- Chatwoot retry of the same AgentBot delivery cannot produce two AI turns.

### 21.3 Tenant isolation

- Workspace A cannot resolve Workspace B Account/Inbox/AgentBot/Contact/Conversation.
- Tampered payload Account/Inbox identifiers are rejected even with a valid connection endpoint.
- Tool connections cannot be used across Workspaces.
- System/global AgentBot with `account_id = NULL` is rejected for ChatRing Assistant connection/activation.
- AgentBot owned by another Chatwoot Account is rejected.
- AgentBot whose `account_id` exactly matches the Workspace `chatwoot_account_id` is accepted when all other checks pass.

### 21.4 Assistant binding

- One Inbox cannot have two active ChatRing Assistant bindings.
- One Assistant can serve multiple Inboxes through the same Assistant AgentBot.
- Binding activation fails on conflicting bot/AI handler.
- Assistant switch invalidates old in-flight turns.

### 21.5 Authorization

- Tool omitted from Assistant grant is rejected server-side even if the model requests it.
- Tool with insufficient assurance is rejected and produces verification/handoff behavior.
- Integration from another Workspace is rejected.
- Mutating tool requiring approval cannot execute without approval.

### 21.6 Knowledge privacy

- Assistant cannot retrieve chunks outside its knowledge scope.
- Cross-Workspace vector/text retrieval is impossible.
- Full KB is not inserted into a normal turn prompt.

### 21.7 Concurrency and stale reply prevention

These tests are mandatory and must use controlled barriers/hooks so the critical interleavings are actually exercised rather than relying on timing sleeps:

1. Start AI generation, then human takes over before the AI commit wins the authoritative serialization order. Conditional commit must create **no AI public message**.
2. Start AI generation, then commit a public human reply before the old AI commit wins the shared message serialization order. Conditional commit must create **no AI public message**.
3. Start AI generation, then commit a newer incoming customer message before the old AI commit wins the shared message serialization order. Old conditional commit must fail; the newer message receives its own turn.
4. Force a qualifying incoming customer writer to attempt commit after the AI freshness query but before the AI message insert. The two writes must not interleave; if the customer write wins serialization, the old AI commit fails.
5. Force a qualifying public human reply writer through the same validation-to-insert window. The two writes must not interleave; if the human reply wins serialization, the old AI commit fails.
6. Verify every supported public inbound-message path and human/public-reply path participates in the same per-conversation serialization/version mechanism used by conditional AI commit.
7. Deliver the same webhook multiple times. Exactly one public AI reply may be committed.
8. Retry ChatRing commit after a timeout where the first commit actually succeeded. Same idempotency key returns the existing result and creates no duplicate.
9. Run concurrent identical conditional commit requests. Exactly one message may be created.
10. Change Inbox Assistant/AgentBot during generation. Old turn cannot commit.
11. Handoff during generation. Old turn cannot commit afterward.

The minimum atomicity contract is serialization, not unconditional wall-clock priority. Once one operation has already entered the shared serialization boundary, later qualifying writes wait and cannot appear between that operation's validation and insert.

### 21.8 Failure recovery

- LLM outage leads to configured bounded retry then handoff/safe failure.
- Knowledge service outage does not cause fabricated business facts.
- Tool timeout does not cause the model to claim the action succeeded.
- Chatwoot transient error retries with the same idempotency key.
- Ambiguous mutating external operation is not duplicated.

### 21.9 Channel regression

Run representative Chatwoot channel tests for every supported production channel because message windows, templates, and delivery constraints vary by channel.

At minimum validate the ChatRing commit contract on the channels that will launch first.

---

## 22. Implementation Sequence

### Phase 1 - Foundations

- Workspace/Account mapping.
- Assistant + versioning.
- Assistant AgentBot connection.
- InboxAssistantBinding.
- Secret storage.
- Webhook ingress verification/dedupe.
- AITurn persistence.

### Phase 2 - Safe response loop

- Chatwoot state fetch adapter.
- Eligibility engine.
- Bounded context assembly.
- Brain interface.
- ChatRing final preflight gate.
- **Chatwoot conditional AgentBot commit path.**
- **Shared per-conversation serialization/version boundary used by conditional AI commit and every qualifying public customer/human message writer.**
- OutboundCommit idempotency ledger.
- Human takeover/new-message cancellation behavior.

Do not launch public AI replies before this phase passes the concurrency tests in Section 21.7.

### Phase 3 - Knowledge and memory

- Canonical KB ingestion.
- Assistant knowledge scopes.
- Retrieval service.
- Contact memory service and retention.

### Phase 4 - Tools and identity

- Integration connection framework.
- Tool registry and schema validation.
- Authorization gateway.
- Identity assurance framework.
- Read-only tools first.
- Mutating tools after idempotency/approval controls exist.

### Phase 5 - Operations

- Audit explorer.
- Metrics/alerts.
- Cost controls.
- Assistant test harness.
- Chatwoot upgrade compatibility suite.

---

## 23. Recommended Service Boundaries

A practical first implementation may use a modular monolith while preserving these logical boundaries:

```text
chatring/
  workspace/
  assistants/
  chatwoot_integration/
    webhook_ingress/
    state_reader/
    conditional_commit_client/
  eligibility/
  brain/
  context/
  knowledge/
  memory/
  identity/
  tools/
    authorization/
    executors/
  turns/
  audit/
```

These are ownership boundaries, not a requirement to deploy a microservice for every directory.

### 23.1 Recommended transaction boundaries

Use local DB transactions for:

- Webhook delivery insert/dedupe.
- AITurn creation.
- Tool mutation ledger transitions.
- OutboundCommit state transitions.

Do not attempt a distributed transaction between ChatRing and external systems. Use idempotency keys, status reconciliation, and explicit state machines.

The conversation/message atomicity requirement lives inside Chatwoot. Conditional AI commit and every qualifying public customer/human message writer must use the same DB-backed per-conversation serialization/version boundary. A Conversation row lock used only by the AI endpoint does not satisfy this requirement.

---

## 24. State Machines

### 24.1 AITurn state

Recommended states:

```text
received
  -> eligible
  -> running
  -> awaiting_tool
  -> running
  -> ready_to_commit
  -> committed

Terminal alternatives:
  ineligible
  superseded
  handed_off
  failed
  cancelled
```

Rules:

- Only `ready_to_commit` may call the conditional commit endpoint.
- `committed` is terminal for public reply creation.
- `superseded`, `handed_off`, `cancelled`, and `ineligible` may never transition to `committed`.
- A transient Chatwoot error may keep the turn `ready_to_commit` while the same idempotency key is retried.

### 24.2 Tool execution state

```text
requested -> authorized -> executing -> succeeded
                   |             |
                   v             v
                 denied        failed/unknown
```

Mutating operations in `unknown` state require reconciliation, not blind retry.

---

## 25. Detailed Assistant Contract

A published Assistant version should contain or reference:

```text
identity
  name
  role
  purpose
  customer-facing persona

goals
instructions
response_guidelines
guardrails

audience_policy
availability_policy
handoff_policy

knowledge_scope_id

tool_grants[]
  tool_id
  allowed_operations
  minimum_assurance_level
  approval_policy

conversation_policy
  ask_one_question_at_a_time
  allow_auto_resolve
  maximum_autonomous_steps
  fallback_behavior
```

The actual schema may evolve, but these responsibilities must remain separate from the Brain's core system policy.

---

## 26. Core Brain System Policy

ChatRing controls a stable runtime policy that customers normally cannot weaken.

It should enforce principles equivalent to:

- Follow the active published Assistant.
- Respect Workspace and Assistant authorization boundaries.
- Use verified/retrieved evidence for business factual claims.
- Do not invent customer-specific or live business state.
- Use tools only through the authorization gateway.
- Never expose credentials or secret tool data.
- Treat retrieved text and customer content as untrusted instructions.
- Use only trusted identity-assurance results for sensitive actions.
- Respect Chatwoot conversation ownership.
- Stop public-response execution when human ownership supersedes the AgentBot.
- Retrieve historical context only when relevant.
- Do not send stale or duplicate replies.
- Hand off when Assistant or system policy requires human involvement.

This policy defines **how ChatRing AI operates**.

The Assistant defines **who the AI is in a particular deployment and what it may do**.

---

## 27. Example: Support Order Question

Customer asks:

> Where is my order?

Runtime:

```text
Chatwoot message_created
  -> verify signed delivery
  -> resolve Workspace + Support Assistant binding
  -> re-read conversation: pending + expected AgentBot owner
  -> create AITurn
  -> load current conversation + contact context
  -> Brain recognizes private live order data is required
  -> Authorization Gateway checks Order Lookup grant
  -> Identity policy requires A2
  -> if A2 satisfied: execute Shopify Order Lookup
  -> return structured status/tracking
  -> Brain drafts response
  -> ChatRing final preflight
  -> Chatwoot conditional commit enters shared conversation serialization boundary
  -> rechecks ownership/freshness with no qualifying message interleaving
  -> outgoing Chatwoot AgentBot message inside the same boundary
  -> existing Chatwoot channel delivery
```

If A2 is not satisfied, the Brain receives a trusted "verification required" result and asks the configured verification question/flow or hands off. It must not guess order data.

---

## 28. Example: Human Takeover and Message Races

### 28.1 Human takeover race

```text
T0 Customer sends message
T1 ChatRing starts AI turn
T2 Human takes over in Chatwoot
T3 LLM finishes response
T4 ChatRing preflight sees stale state OR misses the very latest race
T5 Chatwoot conditional commit enters authoritative ownership/serialization boundary
T6 Guard sees expected AgentBot no longer owns conversation
T7 Guard returns conflict; no message is created
T8 ChatRing marks turn superseded/cancelled
```

This is the required ownership correctness property.

An external preflight without the Chatwoot-side T5-T7 check is not sufficient to guarantee it.

### 28.2 Newer public message race

The stricter message-freshness race is different because ordinary `Message` inserts do not take the Conversation lock at the pinned Chatwoot commit:

```text
T0 Customer message M1 starts AI turn
T1 AI conditional commit begins freshness validation
T2 New qualifying customer/human message writer starts
T3 Shared per-conversation serialization boundary orders the writers

If M2/human reply wins first:
  -> message commits
  -> old AI freshness/version check observes supersession
  -> old AI commit fails

If AI commit wins first:
  -> later message writer cannot interleave
     between AI freshness validation and AI insert
  -> AI message commits first
  -> later message commits afterward
```

The forbidden state is a qualifying public message committed between the old AI freshness validation and the old AI message insert.

## 29. Example: Duplicate Webhook Retry

```text
Delivery D1 arrives
  -> verified
  -> WebhookDelivery D1 inserted
  -> AITurn T1 created

Chatwoot retries D1
  -> signature verified
  -> WebhookDelivery D1 already exists with same hash
  -> return success
  -> no second AITurn

Commit retry for T1
  -> same idempotency key
  -> conditional commit returns existing message if already committed
  -> no duplicate public reply
```

Ingress idempotency and commit idempotency solve different duplicate risks and both are required.

---

## 30. Architecture Decisions Locked by This Specification

The following decisions are considered locked for the first implementation:

1. Chatwoot remains the sole conversation/message/customer-service state authority.
2. ChatRing uses the external AgentBot integration model, not Captain as the ChatRing runtime.
3. ChatRing Workspace is separate from Chatwoot Account and linked one-to-one.
4. ChatRing Assistant and Chatwoot AgentBot are separate entities.
5. One active Assistant has one AgentBot identity per Workspace; it may serve multiple Inboxes.
6. A ChatRing AgentBot identity must be account-owned: non-null `account_id` exactly equal to the Workspace `chatwoot_account_id`; system/global AgentBots are prohibited.
7. One Inbox has at most one active ChatRing Assistant binding.
8. Canonical Business Knowledge is shared at Workspace level with Assistant-specific scopes.
9. ChatRing Contact Memory is keyed to Chatwoot Contact and is not a replacement Contact store.
10. Chatwoot channel identity evidence is distinct from ChatRing business identity assurance.
11. Previous conversations are on-demand context, not automatically injected history.
12. Live/private systems are accessed through tools.
13. Tool selection by the Brain is never authorization.
14. Signed webhook verification uses the exact Chatwoot `sha256=<hex_digest>` format and delivery dedupe is mandatory.
15. Every trigger message maps to at most one AI turn.
16. Human takeover, newer qualifying public messages, and Assistant rebinding invalidate older public-response turns according to authoritative serialization order.
17. Public AI replies require a Chatwoot-side conditional commit guard.
18. Conditional AI commit and every qualifying public customer/human message writer share one DB-backed per-conversation serialization/version boundary; an AI-only Conversation row lock is insufficient.
19. Chatwoot creates and delivers the final customer-visible message.

## 31. Implementation Definition of Done

The architecture implementation is complete enough for production rollout when:

- All core entities and uniqueness constraints in this document exist.
- Workspace isolation tests pass.
- AgentBot/Inbox/Assistant provisioning is automated and conflict-aware.
- AgentBot tenant ownership validation rejects system/global and cross-Account AgentBots.
- Webhook HMAC/timestamp verification is enabled in production using exact `sha256=<hex_digest>` parsing and constant-time digest comparison.
- Delivery dedupe is durable.
- AITurn trigger uniqueness is durable.
- Assistant versions and binding versions are recorded per turn.
- Knowledge retrieval enforces Workspace and Assistant scope before returning results.
- Tool authorization is server-side and independently tested.
- Identity assurance is server-side and action-specific.
- Human handoff uses Chatwoot authoritative state.
- Chatwoot conditional AgentBot commit path exists.
- Every qualifying public customer/human message writer and conditional AI commit use the same per-conversation serialization/version boundary.
- All barrier-controlled concurrency tests in Section 21.7 pass.
- Commit idempotency survives timeout/retry scenarios.
- No AI public message can be committed after a superseding qualifying message or ownership/binding transition that wins authoritative serialization before the old AI commit.
- Observability and audit fields required by Section 19 are available.
- Failure behavior never represents an unconfirmed external mutation as successful.
- Compatibility tests pass against the exact Chatwoot release/commit being deployed.

## 32. Verification Record

### 32.1 Repository verification

This specification was checked against `chatwoot/chatwoot` `develop` commit:

`f12529105bff8b16793c836bde5bfe1ba7e2f470`

The verification confirmed:

- Chatwoot Account owns the operational customer-service entities referenced by this architecture.
- Inbox has an AgentBot association through AgentBotInbox.
- Conversation stores AgentBot ownership and treats AgentBot-owned conversations as assigned.
- AgentBot assignment/human takeover has explicit status/ownership behavior under a database lock.
- `AgentBot.accessible_to(account)` deliberately includes `account_id = NULL` system/global AgentBots as well as account-owned AgentBots.
- Account AgentBot creation uses `Current.account.agent_bots.create!`, so newly provisioned tenant bots are account-owned.
- AgentBot events are sent to webhooks.
- AgentBot webhooks use `X-Chatwoot-Signature: sha256=<hex HMAC>` over `timestamp + "." + raw JSON body`, plus timestamp and delivery ID headers when configured.
- Conversation webhook metadata exposes channel HMAC identity evidence.
- AgentBot API permissions are broader than ChatRing Assistant permissions and therefore cannot replace ChatRing authorization.
- Normal AgentBot message create does not provide the atomic expected-owner/newer-message precondition required by ChatRing's strict stale-reply guarantee.
- `Messages::MessageBuilder#perform` saves the Message without acquiring the Conversation row lock, while message-driven conversation updates occur from `after_create_commit`; therefore an AI-only Conversation lock does not serialize qualifying message inserts.
- Captain independently validates the usefulness of Assistant-to-Inbox association, audience/availability controls, tools/guardrails, and repeated stale-state checks as architectural patterns.

### 32.2 Architectural inference vs repository fact

The following are **ChatRing design decisions**, not claims that upstream Chatwoot already implements them:

- ChatRing Workspace.
- One account-owned AgentBot per ChatRing Assistant.
- InboxAssistantBinding and its versioning.
- Canonical shared Workspace KB with Assistant scopes.
- ChatRing AITurn/WebhookDelivery/OutboundCommit models.
- Identity assurance levels A0-A3.
- ChatRing Authorization and Tool Gateway.
- Chatwoot `Conversations::AgentBotConditionalCommitService` (required extension).
- A shared DB-backed per-conversation serialization/version boundary across conditional AI commit and every qualifying public customer/human message writer.
- The proposed idempotency-key format.

### 32.3 Final verification conclusion

The architectural boundary is correct and complete for implementation **with both the required conditional commit extension and the shared message-serialization invariant**.

The resulting separation is:

```text
CHATWOOT
  Conversation + Contact + Inbox + Messages
  Human ownership + AgentBot ownership + delivery
        |
        v
CHATRING BINDING
  Account-owned AgentBot + Inbox -> Assistant
        |
        v
ASSISTANT
  Role + Guardrails + Knowledge Scope + Tool Grants
        |
        v
BRAIN
  Reasoning + Retrieval + Tool Selection + Decision
        |
        v
APPLICATION SECURITY
  Tenant + Permission + Identity + State + Freshness
        |
        v
CHATWOOT CONDITIONAL COMMIT + SHARED SERIALIZATION / EXTERNAL SYSTEM
  Authoritative execution
```

No implementation team should collapse these boundaries without a new architecture review.

## Appendix A - Reference File Set

Verified repository paths at the pinned commit:

- `app/models/account.rb`
- `app/models/inbox.rb`
- `app/models/conversation.rb`
- `app/models/agent_bot.rb`
- `app/models/agent_bot_inbox.rb`
- `app/services/conversations/assignment_service.rb`
- `app/listeners/agent_bot_listener.rb`
- `app/jobs/agent_bots/webhook_job.rb`
- `lib/webhooks/trigger.rb`
- `app/models/contact.rb`
- `app/models/contact_inbox.rb`
- `app/presenters/conversations/event_data_presenter.rb`
- `app/controllers/concerns/access_token_auth_helper.rb`
- `app/policies/conversation_policy.rb`
- `app/controllers/api/v1/accounts/conversations/messages_controller.rb`
- `app/builders/messages/message_builder.rb`
- `app/models/message.rb`
- `app/controllers/api/v1/accounts/agent_bots_controller.rb`
- `enterprise/app/models/captain/assistant.rb`
- `enterprise/app/models/captain_inbox.rb`
- `enterprise/app/jobs/captain/conversation/response_builder_job.rb`

## Appendix B - Mandatory Database Constraints

At minimum, ChatRing should enforce:

```text
Workspace.chatwoot_account_id                         UNIQUE
AssistantAgentBotConnection(workspace_id, assistant_id) UNIQUE
AssistantAgentBotConnection(workspace_id, chatwoot_agent_bot_id) UNIQUE
InboxAssistantBinding active per (workspace_id, chatwoot_inbox_id) UNIQUE
WebhookDelivery.delivery_id                          UNIQUE
AITurn(workspace_id, chatwoot_conversation_id,
       trigger_message_id)                           UNIQUE
OutboundCommit.ai_turn_id                            UNIQUE
OutboundCommit.idempotency_key                       UNIQUE
```

Use partial unique indexes where active/inactive historical binding rows must coexist.

## Appendix C - Required Chatwoot Patch Tests

The conditional commit/serialization implementation must have focused server-side tests for:

- Authenticated AgentBot matches expected owner.
- Authenticated AgentBot has non-null `account_id` equal to the Conversation Account.
- System/global AgentBot (`account_id = NULL`) rejected.
- AgentBot from another Account rejected.
- Wrong AgentBot rejected.
- Human-owned conversation rejected.
- Open/resolved/snoozed conversation rejected.
- Expected pending account-owned AgentBot conversation accepted.
- `responding_to_message_id` belongs to same conversation and is incoming.
- Newer incoming message committed first causes conflict.
- Newer public human reply committed first causes conflict.
- Private human note behavior is explicitly tested according to product policy.
- Duplicate idempotency key returns the original message / creates no duplicate.
- Concurrent identical commit requests create exactly one message.
- Concurrent human takeover vs bot commit cannot leave a late AI reply after takeover wins authoritative ordering.
- Barrier-controlled customer-message insertion in the freshness-check-to-AI-insert window cannot interleave; if the customer message wins serialization, old AI commit fails.
- Barrier-controlled public human reply in that same window cannot interleave; if the human reply wins serialization, old AI commit fails.
- Every supported public inbound and human/public-reply message write path participates in the same per-conversation serialization/version mechanism.
- Audit/result response contains enough identifiers and serialization/version state for ChatRing reconciliation.
