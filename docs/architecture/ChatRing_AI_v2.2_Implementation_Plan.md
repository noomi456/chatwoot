# ChatRing AI v2.2 implementation plan

**PR #17 authority:** `ChatRing_AI_Chatwoot_Integration_Contract_v2.2.md`

**Post-PR #17 production authority:** `ChatRing_Complete_Production_Foundation_Direction.md`

**Base tree:** deployed-equivalent `0309e77ea7954dec5185dc480f31dab610b468d4`

**Release rule:** `PUBLIC_AI_RELEASE_READY` remains `false` until every v2.2 Section 13 gate and the complete Sales Core v1 release gate pass on the exact deployed paths.

## 1. Verified integration map

This plan is based on the exact Chatwoot CE and ChatRing paths below. It does not use
Enterprise or Captain code.

| Concern | Verified authority | Integration decision |
|---|---|---|
| Incoming message | `Message#execute_after_create_commit_callbacks` | Preserve native callback order |
| Templates | `MessageTemplates::HookExecutionService` | Record the synchronous-template half of native handling after the hook returns |
| Template result | Inbox, Contact, Conversation and Message rows | Record before/after state; template return values are not authoritative |
| Automation | `AutomationRuleListener` and `AutomationRules::ActionService` | PR #17 fails closed on possible conflicts; the first stacked PR must observe actual immediate effects and complete the two-sided barrier without re-evaluating rules |
| Conversation owner/status | `Conversation` and `Conversations::AssignmentService` | Reuse native transitions under shared locks |
| Inbox bot | `AgentBotInbox` | Keep one exact account-owned managed bot |
| AI identity/sender | managed `AgentBot` | Keep identity and Message sender; remove self-webhook transport |
| AI trigger | native template completion plus native immediate-Automation completion | PR #17 contains only the gate-closed template-side seam; the first stacked PR selects and proves the minimal durable two-sided completion boundary before inference |
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
  are included in PR #17. Basic Assistant create, publish, bind, disable and failure
  inspection is a required production-foundation PR; console-only operation is not an
  acceptable v1 release state.

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
- Retain the designated testing model key in the deployment secret store throughout
  pre-production testing; never commit or log it. Rotate it only at production cutover.

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

### Batch 2 — contained post-template half of the internal trigger

Contract: v2.2 Sections 4, 5.4 and 6.1.

Changes:

- Replace the legacy spike hook with a ChatRing-owned CE post-template extension that
  records synchronous template outcomes. Do not freeze this as the final AI scheduling
  seam because current Automations execute through the asynchronous dispatcher.
- Capture template Message IDs before the native hook, invoke `super`, reload native
  state, and capture the resulting template delta.
- Persist `AiTurn.native_handling_snapshot` and `AiTurn.deadline_at`.
- With the public gate closed, create or enqueue no AITurn. The directly stacked native-
  handling completion PR will create/find one turn only after both immediate native
  sides finish.
- Do not create WebhookDelivery for internal turns.
- Remove the deterministic spike runtime; keep only compile-time gates.

The template-side snapshot records Inbox-hours result, Contact-email requirement,
greeting, email-input and out-of-office template IDs. It contains no raw message body
or secret. It is containment evidence, not proof that Automation processing is complete.

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

### Follow-up PR A — native handling completion

Native authority reused:

- `MessageTemplates::HookExecutionService` for synchronous template effects;
- `AutomationRuleListener` and `AutomationRules::ActionService` for immediate native
  Automation evaluation and actions;
- the resulting Conversation and Message rows as effect authority.

Work:

- Characterize both native paths with real callback/job tests before choosing storage.
- Record completion and actual effect provenance from both paths without duplicating or
  re-evaluating Automation conditions/actions.
- Release exactly one AITurn only after both immediate paths complete and the trigger is
  still eligible.
- Keep the broad `AutomationConflictClassifier` as fail-closed containment until actual-
  effect arbitration passes; then narrow it so orthogonal label/priority/private-note
  effects can coexist.
- Decide storage from evidence: reuse `AiTurn.native_handling_snapshot` only if it can do
  so without making AITurn native lifecycle authority; otherwise add the smallest durable
  completion record keyed to the trigger Message.
- Treat delayed Automations separately. The current fork has no delayed-execution model;
  do not claim support or import it implicitly. A later source-audited PR may port the
  current upstream capability, with later native effects superseding any still-
  nonterminal AI turn according to native state.

This PR is required before Brain expansion. PR #17 freezes native authority and
containment, not the current post-template scheduling location.

Characterization selected the minimal durable record permitted above:
`ChatRing::NativeHandlingCompletion`, uniquely keyed to the native trigger Message.
The scoped Web Widget writer creates it only after the locked managed-binding recheck,
so a pre-binding Message cannot be adopted by a later activation. It records the
synchronous-template snapshot and immediate-Automation completion/effect snapshot,
then links the single released `AiTurn`. It is a two-sided completion latch,
not a responder or Conversation lifecycle state machine. The template extension calls
the native template hook with `super`; the Automation extension wraps the native
listener/action execution and observes its resulting rows without duplicating condition
evaluation or action execution. Release rechecks the native managed relationship under
the established Inbox then Conversation lock order.

### Follow-up PR B — BrainInvocation, context and policy

Native authority reused: Account, Inbox, Contact/ContactInbox, Conversation, Message,
Inbox hours and Phase 2A Retriever.

Work:

- Add an immutable `BrainInvocation` value contract and inbound builder; do not add a
  second conversation or customer record.
- Separate trusted native runtime context from the allowlisted model projection.
- Reject unsupported non-empty audience/availability policies until their schemas and UI
  exist; enforce native Inbox hours plus Workspace/Assistant status and kill switches.
- Enforce the persisted turn deadline before retrieval, inference, retry and commit.
- Remove `resolution_request` from schema, parser, prompt and commit handling.
- Preserve speaker provenance: customer, human_agent, managed_ai, native_template,
  automation and external_bot_or_system.
- Omit Contact name, email, phone, identifier and private notes from the first-release
  model projection unless a later purpose-specific policy explicitly allows a field.

### Follow-up PR C — failure reliability and durable outcome delivery

Native authority reused: ActiveJob/Sidekiq execution, native handoff and ordinary
Message delivery. `OutboundCommit` remains only an idempotency/audit ledger.

Work:

- Make ActiveJob the single cross-attempt retry owner. Configure RubyLLM per invocation
  with internal retries disabled and a request timeout bounded by the remaining turn
  budget.
- Classify transient provider/network/rate-limit failures separately from permanent
  configuration, authorization, schema, tenant and expired-deadline failures.
- On exhaustion, transactionally create/reuse a pending handoff `OutboundCommit`; enqueue
  after commit through the existing native handoff path.
- Make pending outcomes automatically recoverable after enqueue/process failure through
  a small condition-driven recovery job. Operator resume is supplemental, not the only
  durability mechanism.
- Prove crashes before/after enqueue, duplicate jobs, timeout, terminal rejection and
  native fallback without adding a second handoff, retry or delivery lifecycle.

### Follow-up PR D — Knowledge safety and audit correlation

- Exclude every KnowledgeIndex pinned by a nonterminal AITurn from provider cleanup.
- Correlate trigger Message, native-handling completion, AITurn, attempt, evidence,
  OutboundCommit and final native Message/handoff.
- Prove cleanup cannot invalidate running inference or retained audit evidence.

### Follow-up PR E — native actions, Automation coexistence and memory

- Extend actual native-effect observation from PR A into deterministic arbitration.
- Authorize AI-requested effects server-side, then invoke native Message, assignment,
  status, labels, priority and note behavior; do not clone native actions.
- Add a governed memory record only where native private notes cannot meet provenance and
  retention requirements; human-visible projections use native notes.

### Follow-up PR F — basic Assistant administration

- Provide account-scoped administrator API/UI for create, immutable publish, Inbox bind,
  switch, disable/archive, managed secret rotation and failure inspection.
- Reuse the existing provisioning/binding services and Chatwoot permissions; do not make
  the UI a second authority.
- Keep advanced analytics, marketplaces and design tooling outside this bounded PR.

### Follow-up PR G — bounded Web Widget production proof

Run, in order:

1. focused model/service/job/controller tests;
2. full Chatwoot CE backend/frontend/lint checks;
3. immutable CE Rails/Sidekiq and private DocsGPT image builds;
4. isolated migration/restore test from deployed data shape;
5. real Widget HTTP lifecycle with PostgreSQL, Redis, Sidekiq and DocsGPT;
6. both human/AI race orderings and concurrency 10 across real process boundaries;
7. non-managed Widget plus representative Email/API/provider regression checks;
8. timeout, retry, automatic recovery, fallback, knowledge pin and tenant-isolation tests;
9. clean Rails/Sidekiq/DocsGPT security/error scan;
10. manual fresh-widget supported, unsupported and immediate-takeover scenarios.

PR G proves the bounded Web Widget core but does not open
`PUBLIC_AI_RELEASE_READY`. Sales Core still requires the shared Brain/context and
reliability boundary, native actions and Automation coexistence, Inbox-scoped Tool
policy, Inbox-owned Playbooks, Website Engagement starter pills, sales administration,
the approved channel set, human voice/calls and the full production proof in
`ChatRing_Complete_Production_Foundation_Direction.md`. External business-event outbound,
AI Navigator, media-aware Knowledge and Microsites are separately gated later stages.
Any failed Sales Core gate leaves the constant false.

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
- Confirm public AI remains disabled through every remediation and foundation PR; only
  the separate final production release commit may change the gate.
- Update DOX only when a durable contract changed.

## 7. PR #17 and v2.2 completion boundary

The work has three distinct checkpoints:

1. **Architecture frozen:** PR #17 passes its five-question native-first review, CI and
   containment deployment. No new transport, ownership, assignment, handoff or delivery
   architecture is added afterward without runtime evidence disproving an invariant.
2. **v2.2 Web Widget path proven:** the stacked native-handling, Brain, reliability,
   Knowledge-safety and production-proof PRs pass the exact Web Widget path and every
   v2.2 Section 13 concurrency/reliability gate. This proves the bounded native lifecycle;
   it is not ChatRing v1 product completion and does not open the public gate.
3. **Sales Core v1 production foundation proven:** the shared BrainInvocation/context
   boundary, native Automation/action integration, Inbox-scoped Tool policy, Inbox-owned
   Playbooks, Website Engagement starter pills, sales administration, enabled-channel
   certification, human voice/calls and full production proof pass the release definition
   in `ChatRing_Complete_Production_Foundation_Direction.md`.

Green unit tests, service-only barriers or a single successful widget response are not
sufficient completion evidence.
