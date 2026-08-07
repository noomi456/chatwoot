#!/usr/bin/env bash
set -euo pipefail

: "${DOCSGPT_BASE_IMAGE:?DOCSGPT_BASE_IMAGE must name the pinned upstream image}"
: "${DOCSGPT_BASE_DIGEST:?DOCSGPT_BASE_DIGEST must identify the source-built upstream image}"
: "${DOCSGPT_TARGET_IMAGE:?DOCSGPT_TARGET_IMAGE must be an immutable ChatRing image tag}"
: "${CHATRING_SOURCE_COMMIT:?CHATRING_SOURCE_COMMIT must identify the ChatRing source}"

case "${DOCSGPT_BASE_IMAGE}" in
  *@sha256:*) ;;
  *)
    echo "DOCSGPT_BASE_IMAGE must be pinned as name@sha256:digest" >&2
    exit 1
    ;;
esac

DOCSGPT_SOURCE_COMMIT=616e6fe9c435bbc6bb472636db6b3ee2b9bcaf66

docker build \
  --build-arg "DOCSGPT_BASE_IMAGE=${DOCSGPT_BASE_IMAGE}" \
  --build-arg "DOCSGPT_SOURCE_REPOSITORY=https://github.com/arc53/DocsGPT" \
  --build-arg "DOCSGPT_SOURCE_COMMIT=${DOCSGPT_SOURCE_COMMIT}" \
  --build-arg "DOCSGPT_BASE_DIGEST=${DOCSGPT_BASE_DIGEST}" \
  --build-arg "CHATRING_SOURCE_COMMIT=${CHATRING_SOURCE_COMMIT}" \
  --file deploy/knowledge/Dockerfile \
  --tag "${DOCSGPT_TARGET_IMAGE}" \
  .
