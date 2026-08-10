# ChatRing AI v2.2 implementation plan

**PR #17 authority:** `ChatRing_AI_Chatwoot_Integration_Contract_v2.2.md`

**Post-PR #17 production authority:** `ChatRing_Complete_Production_Foundation_Direction.md`

**Base tree:** deployed-equivalent `0309e77ea7954dec5185dc480f31dab610b468d4`

**Release rule:** `PUBLIC_AI_RELEASE_READY` remains `false` until every v2.2 Section 13 gate and the complete production-foundation release gate pass on the exact deployed paths.

## 1. Verified integration map

This plan is based on the exact Chatwoot CE and ChatRing paths below. It does not use
Enterprise or Captain code.

| Concern | Verified authority | Integration decision |
|---|---|---|
| Incoming message | `Message#execute_after_create_commit_callbacks` | Preserve native callback order |
| Templates | `MessageTemplates::HookExecutionService` | Schedule only after the native hook returns |
| Template result | Inbox, Contact, Conversation and Message rows | Record before/after state; template return values are not authoritative |
| Automation | `AutomationRule` and `AutomationRules::ActionService` | Reject responder/ownership conflicts; no timing barrier exists |
| Conversation owner/status | `Conversation` and `Conversations::AssignmentService` | Reuse native transitions under shared locks |
| Inbox bot | `AgentBotInbox` | Keep one exact account-owned managed bot |
| AI identity/sender | managed `AgentBot` | Keep identity and Message sender; remove self-webhook transport |
| AI trigger | post-template CE extension | Create one durable AITurn using record IDs only |
| AI reasoning | ChatRing Brain | Revalidate native state before every expensive/final stage |
| Knowledge | Phase 2A Retriever | Pin exact index and protect it while a turn is nonterminal |
| Customer reply | ordinary Chatwoot `Message` | One guarded in-process commit, then native delivery |
| Handoff | native `bot_handoff!(dispatch_event:)` | Wrap; do not replace native semantics |
| External runtime APIs | signed webhook plus conditional HTTP endpoint | Inactive and rejected in internal mode |

Every implementation change must pass the contract's native-first test before a new
ChatRing component is introduced. The only new serialization wrapper exists because
Chatwoot has no native cross-writer compare-and-commit boundary; it wraps the approved
Widget/dashboard writers and invokes native Message, AssignmentService and handoff
behavior rather than replacing them.

Captain was used only to confirm useful CE seams: internal post-template scheduling,
ordinary Message persistence and native delivery. Its models, jobs, prompts, tools,
policies and Enterprise overrides are not implementation sources.

## 2. Locked first-release behavior

- Web Widget only.
- One managed AgentBot per active Assistant.
- One active immutable AssistantVersion per Assistant turn.
- Empty audience policy means every visitor to the bound Widget Inbox.
- Empty availability policy means native Inbox working hours.
- Non-empty audience or availability policies are rejected until their schema and UI
  are separately approved.
- No Contact name, email, phone, identifier or private notes enter model context.
- Decisions are grounded reply/clarification or handoff only.
- No tools, memory, Q&A, Images, additional channels or public Assistant management UI
  are included in this remediation.

## 3. Lock and mutation contract

The fixed lock order is:

```text
configuration: Account -> Inbox -> affected Conversations ordered by ID
managed message/turn: Inbox -> Conversation -> AITurn/OutboundCommit
```

Rules:

1. Binding, disable, archive, rebind and AutomationRule mutation take the Account lock.
2. Binding transitions then take the Inbox lock.
3. Rebind/handoff takes each affected Conversation lock in ascending ID order.
4. The approved Web Widget incoming and dashboard public-human writer paths first take the Inbox row lock
   to linearize first binding activation. Only an active/draining binding proceeds to
   the Conversation lock. AI commit uses the same Inbox then Conversation order.
5. The managed-binding predicate is rechecked after both locks are held.
6. An Inbox with no active/draining ChatRing binding keeps upstream Conversation and
   Message behavior and does not take the Conversation or ledger locks. The short
   Web Widget Inbox row lock is solely the activation-race boundary.
7. No global `Message` callback implements ChatRing serialization. Other native
   message writers remain untouched until their channel is separately approved.

Controlled-barrier tests must prove activation, rebind and assignment cannot race the
predicate and that non-managed channel writers remain unchanged.

## 4. Delivery batches

PR #17 contains only Batches 0–5: containment and native-lifecycle remediation. It is
frozen after the five-question checkpoint below passes. Brain policy, failure handling,
knowledge pinning and production proof are separate follow-up PRs so regressions remain
attributable. A later PR starts only after the previous PR's focused tests and combined
static review pass.

### Batch 0 — containment

Contract: v2.2 Sections 1, 4 and 10.

Changes:

- Set `PUBLIC_AI_RELEASE_READY = false` and correct its stale comment.
- Return from the post-template scheduling seam before creating or enqueuing an
  `AITurn` while that gate is false.
- Terminally cancel queued, unstarted `received` turns that reach `AiTurnJob` after
  the gate closes, and forward-migrate stale gate-created rows to the same state.
- Keep the existing console-only Assistant binding/switching service operationally
  frozen while remediation is active. There is no user-facing Assistant binding API or
  UI in this release; do not introduce a temporary product control solely for the freeze.
- Make `AiTurnJob` and `OutboundCommitJob` inert while the gate is false.
- Stop provisioning managed AgentBots with a public self-webhook URL.
- Clear existing managed AgentBot `outgoing_url` values in a forward migration.
- Reject the managed ChatRing webhook route before signature parsing or persistence.
- Disable the conditional HTTP endpoint in internal mode.
- Remove the legacy deterministic Assistant spike responder, job and global Message
  extension; retain only the public-response and external-runtime constants.
- Set `AgentBots::WebhookJob.log_arguments = false` and remove full-payload retry logs.
- Rotate deployed managed webhook secrets after deployment.
- Require a newly rotated model key from the deployment secret store; the repository
  cannot rotate the provider account credential itself.

Proof:

- No public AI Message can commit.
- A gate-closed native message creates no `AITurn`, and an already queued unstarted
  turn is cancelled without inference or native mutation.
- A valid old managed webhook creates no WebhookDelivery or AITurn.
- Existing Conversations and Messages are preserved.
- Routine Rails/Sidekiq logs expose no payload, managed webhook secret or model key.

### Batch 1 — native lifecycle characterization

Contract: v2.2 Sections 2, 5, 6.7, 7 and 12.

Write failing integration tests before production corrections for:

- Widget HTTP request through native callbacks and template hook.
- Greeting, email collection and out-of-office precedence.
- Email collection remains terminal on later messages while Contact email is absent.
- Automation response and ownership conflicts.
- Managed and non-managed message serialization paths.
- Native assignment, public-human takeover and old-bot rebind.
- Native handoff event occurring only after committed state.
- Real internal reply/handoff path through ordinary Message delivery scheduling.

These tests may add controlled barriers but must enter through the real Widget and
dashboard/public-reply writers. Direct service tests remain supplemental.

### Batch 2 — one internal post-template trigger

Contract: v2.2 Sections 4, 5.4 and 6.1.

Changes:

- Replace the legacy spike hook with a ChatRing-owned CE post-template scheduler.
- Capture template Message IDs before the native hook, invoke `super`, reload native
  state, and capture the resulting template delta.
- Persist `AiTurn.native_handling_snapshot` and `AiTurn.deadline_at`.
- Create/find one AITurn by Workspace, Conversation and trigger Message.
- Enqueue by AITurn ID only and verify ActiveJob enqueue success.
- Do not create WebhookDelivery for internal turns.
- Remove the deterministic spike runtime; keep only compile-time gates.

The causal snapshot records Inbox-hours result, Contact-email requirement, greeting,
email-input and out-of-office template IDs. It contains no raw message body or secret.

### Batch 3 — response arbitration and policy

Contract: v2.2 Sections 5 and 6.2.

Changes:

- Add one conflict classifier for active AutomationRules.
- Treat public Message/attachment, assignment/team removal or change, status/open/
  pending/resolve/snooze and ambiguous webhook/bot response actions as conflicts.
- Validate conflicts during binding and during AutomationRule create, update, clone and
  activation under the Account lock.
- Fail closed when rule conditions cannot prove exclusion from the bound Inbox/event.
- Recheck conflicts at turn scheduling and final commit.
- Enforce Web Widget, pending state, exact managed owner, native Inbox hours and the
  locked empty-policy semantics.

Allowed non-response automation remains native and unmodified. No sleep, poll or queue
priority is used as an automation barrier.

### Batch 4 — scoped serialization and native handoff

Contract: v2.2 Sections 6.6–6.8.

Changes:

- Replace the global Conversation lock with the scoped Inbox/Conversation boundary.
- Include active and draining bindings so transitions cannot escape serialization.
- Restore upstream `Conversation#bot_handoff!(dispatch_event:)` unchanged.
- Make the conditional wrapper perform final validation and native handoff under the
  shared boundary, then dispatch according to native post-commit semantics.
- Add `OutboundCommit.outcome_type` for reply or handoff.
- Make both outcomes idempotent through the same ledger.
- A public human reply under managed-bot ownership performs native takeover before the
  reply commits; future customer messages remain human-owned until explicit reassignment.

Proof includes message-vs-reply, message-vs-handoff, duplicate commit and timeout-after-
commit barriers through the production writers.

### Batch 5 — assignment, disable and rebind

Contract: v2.2 Section 7.

Changes:

- Filter managed bots in assignable-agent responses to the exact active bot connected
  to every selected Inbox.
- Enforce the same restriction inside `Conversations::AssignmentService`.
- Accept only Web Widget Inboxes for first-release bindings.
- Rebind: Account lock, Inbox lock, old binding draining, cancel/supersede nonterminal
  turns, native handoff of old-bot Conversations in ID order, verify none remain,
  replace AgentBotInbox, create the new immutable binding.
- If any handoff fails, do not activate the replacement.
- Disable/archive uses the same drain/handoff path.

No existing customer Conversation is silently reassigned to a different Assistant.

### PR #17 architecture-freeze checkpoint

The combined source must answer these questions before PR #17 is frozen:

1. ChatRing does not own Conversation status or ownership; `AITurn` records computation
   only, while native `Conversation` and `AssignmentService` remain authoritative.
2. ChatRing does not bypass ordinary Message persistence or native channel delivery.
3. ChatRing does not redefine assignment or handoff; guarded commits invoke the native
   services and `Conversation#bot_handoff!`.
4. Non-managed Chatwoot paths receive no ChatRing lifecycle mutation. An unbound Widget
   takes only the short Inbox lock required to linearize first binding activation, then
   performs the unchanged native write.
5. The Brain, evidence and guarded-commit core are channel-neutral. A later channel adds
   a certified native scheduling and serialization adapter; it does not clone the core.

The legacy deterministic Assistant spike responder, job and global Message extension
must not remain compiled as an alternate path. External webhook/HTTP contracts remain
hard-disabled and unreachable in the internal deployment.

### Follow-up PR A — Brain policy and privacy

Contract: v2.2 Sections 6.2–6.5 and 10.

Changes:

- Reject unsupported non-empty audience and availability policies until their contract
  exists; enforce native Inbox hours and Workspace/Assistant availability.
- Enforce the persisted turn deadline before retrieval, inference, retry and commit.
- Remove `resolution_request` from schema, parser, prompt and commit handling.
- Preserve speaker provenance: customer, human_agent, managed_ai, native_template,
  automation and external_bot_or_system.
- Omit Contact PII for the first release.
- Include operational Workspace/Assistant status in every eligibility/final check.

### Follow-up PR B — failure reliability

Contract: v2.2 Sections 6.3, 6.5 and 8.

Changes:

- Add an explicit provider request timeout through RubyLLM's actual supported transport
  seam and retain the total turn deadline from PR A.
- Bound attempts; exhausted retries create/reuse a handoff `OutboundCommit` and enqueue
  it, rather than only changing turn status.
- Treat commit-enqueue failure as recoverably pending; add one explicit operator resume
  task instead of a new periodic reconciliation system.
- Prove retry, timeout, ambiguous enqueue and native fallback behavior without adding a
  second handoff, retry or delivery lifecycle.

### Follow-up PR C — Knowledge safety

Contract: v2.2 Sections 6.3 and 10.

Changes:

- Exclude any KnowledgeIndex pinned by a nonterminal AITurn from provider cleanup.
- Correlate trigger Message, AITurn, attempt, evidence, OutboundCommit and final Message.

### Follow-up PR D — production proof and release gate

Contract: v2.2 Sections 12, 13 and 15.

Run, in order:

1. focused model/service/job/controller tests;
2. full Chatwoot CE backend/frontend/lint checks;
3. immutable CE Rails/Sidekiq and private DocsGPT image builds;
4. isolated migration/restore test from deployed data shape;
5. VPS lifecycle suite with PostgreSQL, Redis and DocsGPT;
6. Section 13 controlled concurrency at 10 workers;
7. representative non-managed channel regression suite;
8. clean Rails/Sidekiq/DocsGPT security/error scan;
9. manual fresh-widget supported, unsupported and immediate-takeover scenarios.

PR D does not open `PUBLIC_AI_RELEASE_READY`. It proves the bounded v2.2 lifecycle and
execution path only. A separate final release commit may change the gate to true only
after the complete production foundation in
`ChatRing_Complete_Production_Foundation_Direction.md` is implemented and proven. Any
failed gate leaves the constant false; no partial public rollout is claimed as product
completion.

## 5. Migration and deployment safety

- Batch 0 migrations only clear managed self-webhook URLs and add no destructive data
  conversion.
- Batch 2/4 additive columns are nullable or safely backfilled before constraints.
- Existing WebhookDelivery rows remain audit history but cease to trigger internal mode.
- Existing nonterminal turns are cancelled or completed as handoff before the repaired
  trigger is enabled.
- Existing Assistant/binding rows are preflighted for unsupported channels, conflicts
  and old-bot-owned Conversations before remediation activation.
- A database backup and isolated restore precede any production migration.
- Old workers are drained before migration; Rails and Sidekiq use the same immutable
  source digest.
- The public-response gate remains false across every intermediate deployment.

## 6. Static-review checklist after every batch

- Re-read the changed files plus the complete production path, not only the diff.
- State which Chatwoot native authority is reused.
- Confirm no Enterprise/Captain source changed or entered the CE build.
- Confirm non-managed Inboxes retain upstream behavior.
- Confirm all job arguments are identifiers and enqueue failure is handled.
- Confirm no network call occurs inside database locks.
- Confirm lock acquisition follows the fixed order.
- Confirm every customer-affecting outcome uses OutboundCommit.
- Confirm public AI remains disabled unless Batch 7 is complete.
- Update DOX only when a durable contract changed.

## 7. PR #17 and v2.2 completion boundary

The work has three distinct checkpoints:

1. **Architecture frozen:** PR #17 passes its five-question native-first review, CI and
   containment deployment. No new transport, ownership, assignment, handoff or delivery
   architecture is added afterward without runtime evidence disproving an invariant.
2. **v2.2 Web Widget path proven:** Follow-up PRs A–D pass the exact Web Widget path and
   every v2.2 Section 13 concurrency/reliability gate. This proves the bounded native
   lifecycle; it is not ChatRing v1 product completion and does not open the public gate.
3. **ChatRing v1 production foundation proven:** the BrainInvocation/context boundary,
   native Automation/action integration, enabled-channel certification, one real external
   capability, trusted business events, transactional and AI-assisted outbound, and full
   production proof pass the release definition in
   `ChatRing_Complete_Production_Foundation_Direction.md`.

Green unit tests, service-only barriers or a single successful widget response are not
sufficient completion evidence.
