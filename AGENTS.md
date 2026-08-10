# ChatRing Conversation Core — DOX Rail

This repository is ChatRing's Community Edition conversation foundation, derived from Chatwoot CE. These instructions and every child `AGENTS.md` are binding work contracts for their subtrees.

## DOX Core Contract

- Before editing, read this file and every `AGENTS.md` from the repository root to each target path.
- The nearest `AGENTS.md` controls local implementation details; no child may weaken this root contract.
- After every meaningful change, re-check the affected DOX chain and update the nearest owning docs when purpose, ownership, structure, contracts, workflows, permissions, constraints, verification, or durable behavior changed.
- Keep DOX concise and operational. Remove stale or contradictory rules instead of preserving historical commentary.
- Do not rely on remembered repository rules; re-read the applicable chain in the current session.

## Product Boundary

- Phase 1 owns the conventional omnichannel conversation foundation only: inboxes, conversations, contacts, agents, teams, assignment, handoff, channel delivery, attachments, notes, canned responses, history, and the classic website widget.
- The Chatwoot-derived Rails/PostgreSQL application is ChatRing's conversational control plane. ChatRing-owned Phase 2 control-plane code may live here for Workspace/Knowledge Base ownership, Assistant/inbox configuration, internal turn scheduling, evidence contracts, turn/audit state, Playbook/action/artifact references, and ordinary outgoing Chatwoot Message creation.
- Heavy or independently scalable execution remains replaceable behind narrow contracts: Firecrawl website extraction, DocsGPT ingestion/retrieval, model inference, long-running Skills, and artifact compilation. These dependencies must not create a second conversation ledger or send customer replies.
- ChatRing is Sales-first. Stage A is the complete text-first Sales Core v1 defined in `docs/architecture/ChatRing_Complete_Production_Foundation_Direction.md`; Stage B adds AI Navigator, media-aware Knowledge, Sales Entities and visual Microsites only after Sales Core is stable. Engagement starter pills, Inbox-owned Playbooks, shared Tools with Inbox policy, Campaigns, Automations, AI Navigator and Microsites are distinct product/runtime concepts and must not be collapsed into one model.
- The `ChatRing::AssistantSpike` compile-time gate remains disabled while the Sales Core v1 production foundation is incomplete. The v2.2 native-lifecycle gates are necessary but not sufficient; the gate must not open until `docs/architecture/ChatRing_Complete_Production_Foundation_Direction.md` is implemented and proven on the exact deployed paths.
- `ChatRing::Knowledge` may define provider-neutral evidence contracts and selected-provider adapters. It must return evidence only; it cannot author or deliver a customer answer.
- Phase 2A owns one account-level business Knowledge Base, user-triggered website/page/file extraction, one Training Materials catalog, and evidence retrieval. It never sends a customer-facing response.
- Public AI responses remain disabled until both `docs/architecture/ChatRing_AI_Chatwoot_Integration_Contract_v2.2.md` Section 13 and the complete Sales Core v1 release gate pass. For the current single deployment, ChatRing schedules turns internally through a source-verified native seam; the account-owned AgentBot remains the Chatwoot owner/sender and must not public-webhook back into the same Rails application.
- The governing engineering sequence is **Audit Chatwoot first → Reuse → Extend → Adapt → Build only what is genuinely missing**. Before designing or changing a ChatRing subsystem, inspect the current deployed/PR source, pinned CE source, relevant upstream source, official documentation and real configured provider path; classify the capability as `NATIVE`, `EXTEND`, `ADAPT` or `NEW`. Deployed source/runtime behavior wins when evidence conflicts, and the discrepancy must be recorded.
- Native Chatwoot lifecycle is always authoritative. Every implementation PR must identify the native authority, exact seam reused, minimal ChatRing extension and native mutation/delivery path. Add a ChatRing-only component only when the audited capability is genuinely absent, and keep it subordinate to native ownership, state, mutation and delivery.
- The legacy DocsGPT `POST /api/search` response is not a production evidence contract because it omits scores and bypasses DocsGPT's configured Dispatcher path. Production retrieval must expose provider scores and permit an empty EvidenceSet.
- Preserve supported Chatwoot CE APIs, webhook contracts, database identifiers, migrations, SDK events, and environment variables unless an approved migration contract explicitly changes them.
- ChatRing branding is a customer-facing presentation layer. Do not perform global internal identifier replacement.

## Community Edition Boundary

- Production images must be built as Community Edition with `CW_EDITION=ce` and `DISABLE_ENTERPRISE=true`.
- Do not modify, unlock, copy, port, or derive implementation from `enterprise/` or `spec/enterprise/`.
- Do not bypass feature gates or licensing checks.
- Keep the upstream Enterprise source untouched for upstream compatibility; the ChatRing CE image workflow must exclude it from the build context before the image is built.
- Independently built ChatRing capabilities live outside the Enterprise overlay and must use CE-supported APIs and extension boundaries.
- The legacy deterministic Assistant spike responder is removed. `ChatRing::AssistantSpike` retains only compile-time release/runtime gates; no alternate responder may bypass the v2.2 production path.

## Build / Test / Lint

- **Setup**: `bundle install && pnpm install`
- **Run Dev**: `pnpm dev` or `overmind start -f ./Procfile.dev`
- **Seed Local Test Data**: `bundle exec rails db:seed` (quickly populates minimal data for standard feature verification)
- **Seed Search Test Data**: `bundle exec rails search:setup_test_data` (bulk fixture generation for search/performance/manual load scenarios)
- **Seed Account Sample Data (richer test data)**: `Seeders::AccountSeeder` is available as an internal utility and is exposed through Super Admin `Accounts#seed`, but can be used directly in dev workflows too:
  - UI path: Super Admin → Accounts → Seed (enqueues `Internal::SeedAccountJob`).
  - CLI path: `bundle exec rails runner "Internal::SeedAccountJob.perform_now(Account.find(<id>))"` (or call `Seeders::AccountSeeder.new(account: Account.find(<id>)).perform!` directly).
- **Lint JS/Vue**: `pnpm eslint` / `pnpm eslint:fix`
- **Lint Ruby**: `bundle exec rubocop -a`
- **Test JS**: `pnpm test` or `pnpm test:watch`
- **Test Ruby**: `bundle exec rspec spec/path/to/file_spec.rb`
- **Single Test**: `bundle exec rspec spec/path/to/file_spec.rb:LINE_NUMBER`
- **Run Project**: `overmind start -f Procfile.dev`
- **Ruby Version**: Manage Ruby via `rbenv` and install the version listed in `.ruby-version` (e.g., `rbenv install $(cat .ruby-version)`)
- **rbenv setup**: Before running any `bundle` or `rspec` commands, init rbenv in your shell (`eval "$(rbenv init -)"`) so the correct Ruby/Bundler versions are used
- Always prefer `bundle exec` for Ruby CLI tasks (rspec, rake, rubocop, etc.)

## Code Style

- **Ruby**: Follow RuboCop rules (150 character max line length)
- **Vue/JS**: Use ESLint (Airbnb base + Vue 3 recommended)
- **Vue Components**: Use PascalCase
- **Events**: Use camelCase
- **I18n**: No bare strings in templates; use i18n
- **Error Handling**: Use custom exceptions (`lib/custom_exceptions/`)
- **Models**: Validate presence/uniqueness, add proper indexes
- **Type Safety**: Use PropTypes in Vue, strong params in Rails
- **Naming**: Use clear, descriptive names with consistent casing
- **Vue API**: Always use Composition API with `<script setup>` at the top

## Styling

- **Tailwind Only**:  
  - Do not write custom CSS  
  - Do not use scoped CSS  
  - Do not use inline styles  
  - Always use Tailwind utility classes  
- **Colors**: Refer to `tailwind.config.js` for color definitions

## General Guidelines

- Prefer the smallest production-ready change that solves the current problem.
- Build for the expected production path first. Do not add speculative guards, fallbacks, retries, or edge-case handling unless the caller can actually hit that case or production has proven it necessary.
- When an impossible or misconfigured state would indicate a setup/deployment bug, let it fail loudly instead of silently skipping behavior.
- For locked/internal configs that must exist in production, prefer direct reads (`find`, `find_by!`, required hash keys) over silent fallbacks.
- Do not add validation or response checks unless the code uses the result or the check changes behavior meaningfully.
- Prefer existing repo dependencies/client libraries over hand-rolled protocol code for auth, signing, parsing, or API plumbing.
- Avoid one-use private helpers unless they hide real complexity or make the main flow meaningfully easier to read.
- Prefer minimal, readable code over elaborate abstractions; clarity beats cleverness
- Break down complex tasks into small, testable units
- Iterate after confirmation
- Avoid writing specs unless explicitly asked
- In specs, avoid custom helper methods for setup/data. Prefer `let` values and direct per-example setup; only add a helper when it removes meaningful repeated complexity.
- Remove dead/unreachable/unused code
- Don’t write multiple versions or backups for the same logic — pick the best approach and implement it
- Prefer `with_modified_env` (from spec helpers) over stubbing `ENV` directly in specs
- Specs in parallel/reloading environments: prefer comparing `error.class.name` over constant class equality when asserting raised errors

## Codex Worktree Workflow

- Use a separate git worktree + branch per task to keep changes isolated.
- Keep Codex-specific local setup under `.codex/` and use `Procfile.worktree` for worktree process orchestration.
- The setup workflow in `.codex/environments/environment.toml` should dynamically generate per-worktree DB/port values (Rails, Vite, Redis DB index) to avoid collisions.
- Start each worktree with its own Overmind socket/title so multiple instances can run at the same time.

## Commit Messages

- Prefer Conventional Commits: `type(scope): subject` (scope optional)
- Example: `feat(auth): add user authentication`
- Don't reference Claude in commit messages

## PR Description Format

- Start with a short, user-facing paragraph describing the product change.
- Add a `Closes` section with relevant issue links (GitHub, Linear, etc.).
- For feature PRs, add `How to test` from a product/UX standpoint.
- For bugfix PRs, use `How to reproduce` when helpful.
- Optionally add a `What changed` section for implementation highlights.
- Do not add a `How this was tested` section listing specs/commands.

## Project-Specific

- **Translations**:
  - For product and source-string changes, only update `en.yml` and `en.json`; other languages are handled through Crowdin and the community
  - Crowdin-generated translation sync PRs may update non-English locale files; do not flag those changes solely for modifying translated locale files
  - Backend i18n → `en.yml`, Frontend i18n → `en.json`
- **Frontend**:
  - Use `components-next/` for message bubbles (the rest is being deprecated)

## Ruby Best Practices

- Use compact `module/class` definitions; avoid nested styles

## Branding / White-labeling note

- For user-facing strings that currently contain "Chatwoot" but should adapt to branded/self-hosted installs, prefer applying `replaceInstallationName` from `shared/composables/useBranding` in the UI layer (for example tooltip and suggestion labels) instead of adding hardcoded brand-specific copy.

## DOX Closeout

1. Re-check changed paths against this file and the applicable child DOX files.
2. Update the closest owning DOX when a durable contract changed.
3. Refresh affected Child DOX Index entries.
4. Run the relevant existing verification.
5. Report any applicable DOX file intentionally left unchanged and why.

## Child DOX Index

- `.github/AGENTS.md` — CI validation, CE-only image publication, and immutable image contracts.
- `app/AGENTS.md` — Rails views, customer-visible application behavior, and the `app/javascript` child boundary.
- `config/AGENTS.md` — installation identity defaults and compatibility-sensitive configuration.
- `deploy/AGENTS.md` — Dokploy Compose topology, secret handling, persistence, and runtime verification.
- `public/AGENTS.md` — public brand assets, manifests, and browser/device metadata.
