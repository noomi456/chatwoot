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
- Build the approved DocsGPT source commit in CI when the derived knowledge-image source changes, build the ChatRing-derived image from that exact base, and run scoped retrieval, mutation, provenance, and maintenance tests inside the resulting image before publishing it by immutable ChatRing commit tag. Rails-only changes reuse the last verified DocsGPT digest.
- Build ChatRing with a content-addressed dependency image derived only from the Ruby/Node dependency manifests and its base Dockerfile. Resolve that base to an immutable registry digest before the application build.
- Keep the final ChatRing application layer source-addressed by the full commit SHA. Do not serialize its build behind an unchanged DocsGPT image build.

## Work Guidance

- Pin maintained GitHub Actions by major version and review upgrades deliberately.
- Keep validation and build jobs explicit so a failed gate cannot publish an image.

## Verification

- `pnpm run eslint`
- `pnpm exec vitest app/javascript/shared/helpers/specs/InstallationBranding.spec.js --run --no-cache`
- Confirm the workflow's CE-boundary checks pass before accepting a GHCR artifact.
- Confirm the published DocsGPT image records the approved upstream source commit, source-built base digest, and ChatRing source commit.
- Confirm the application image records the full ChatRing source commit and the dependency base reference contains a registry digest.

## Child DOX Index

- No child DOX files currently required.
