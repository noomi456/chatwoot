#!/usr/bin/env bash
set -euo pipefail

: "${DOCSGPT_BASE_IMAGE:?DOCSGPT_BASE_IMAGE must name the pinned upstream image}"
: "${DOCSGPT_TARGET_IMAGE:?DOCSGPT_TARGET_IMAGE must be an immutable ChatRing image tag}"

docker build \
  --build-arg "DOCSGPT_BASE_IMAGE=${DOCSGPT_BASE_IMAGE}" \
  --file deploy/knowledge/Dockerfile \
  --tag "${DOCSGPT_TARGET_IMAGE}" \
  .
