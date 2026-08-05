# Frontend Runtime and Branding

## Purpose

Own ChatRing presentation across the dashboard, widget, survey, and frontend entrypoints without renaming stable Chatwoot internals.

## Ownership

- Installation-name replacement and browser title behavior.
- Customer-visible dashboard, widget, survey, and Help Center branding.
- Frontend branding regression tests.

## Local Contracts

- `InstallationBranding` and `useBranding` are the authoritative frontend identity adapters.
- Apply branding at display boundaries; preserve SDK globals, event names, package names, routes, storage keys, and API payload fields unless a migration specification approves a change.
- Do not introduce independent AI, retrieval, Playbook, Skill, Voice, or microsite authority in frontend components.
- Keep i18n source changes limited to English source files; community translations remain upstream-managed.

## Work Guidance

- Use Vue Composition API and existing Tailwind patterns.
- Add focused regression coverage when a new customer-visible brand surface is normalized.

## Verification

- `pnpm run eslint`
- `pnpm exec vitest app/javascript/shared/helpers/specs/InstallationBranding.spec.js --run --no-cache`
- Scan rendered and built customer-facing surfaces for unintended `Chatwoot` names, domains, and logo assets.

## Child DOX Index

- No child DOX files currently required.
