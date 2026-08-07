# CI and Image Publication

## Purpose

Own GitHub Actions validation and immutable ChatRing Conversation Core image publication.

## Ownership

- Frontend validation required before image publication.
- CE-only build-context enforcement.
- GHCR image naming and immutable commit tags.

## Local Contracts

- Published images must exclude `enterprise/` and `spec/enterprise/` before Docker build.
- Images must set `CW_EDITION=ce` and `DISABLE_ENTERPRISE=true`; deployment must set them again at runtime.
- Publish `linux/amd64` images tagged with the full source commit SHA.
- Do not publish `latest` from the Phase 1 branch.
- A build may not continue when branding tests or lint fail.
- Build the approved DocsGPT source commit in CI, build the ChatRing-derived image from that exact base, and run scoped retrieval, mutation, provenance, and maintenance tests inside the resulting image before publishing it by immutable ChatRing commit tag.

## Work Guidance

- Pin maintained GitHub Actions by major version and review upgrades deliberately.
- Keep validation and build jobs explicit so a failed gate cannot publish an image.

## Verification

- `pnpm run eslint`
- `pnpm exec vitest app/javascript/shared/helpers/specs/InstallationBranding.spec.js --run --no-cache`
- Confirm the workflow's CE-boundary checks pass before accepting a GHCR artifact.
- Confirm the published DocsGPT image records the approved upstream source commit, source-built base digest, and ChatRing source commit.

## Child DOX Index

- No child DOX files currently required.
