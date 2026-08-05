# Installation Configuration

## Purpose

Own ChatRing installation identity defaults while preserving configuration compatibility with upstream Chatwoot CE.

## Ownership

- Product name, domains, support URLs, and installation defaults in `installation_config.yml`.
- Compatibility-sensitive environment-variable mappings.

## Local Contracts

- Default customer-facing values must resolve to ChatRing-owned names and domains.
- Preserve upstream environment-variable names and configuration keys unless an explicit migration is implemented and tested.
- Phase 1 configuration must not enable Enterprise or Captain features.
- The ChatRing deterministic Assistant spike may register CE-owned prepend modules, but activation belongs to an explicitly enabled spike AgentBot and must never depend on Enterprise loading.

## Work Guidance

- Prefer value changes over key renames.
- Do not place deployment secrets in repository configuration.

## Verification

- Parse changed YAML successfully.
- Confirm deployed runtime settings resolve to ChatRing values and `CW_EDITION=ce`, `DISABLE_ENTERPRISE=true`.

## Child DOX Index

- No child DOX files currently required.
