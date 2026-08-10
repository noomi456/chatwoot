#!/bin/sh
set -eu

if [ "$#" -ne 4 ]; then
  echo "usage: $0 ENV_FILE SOURCE_IMAGE SOURCE_COMMIT PROOF_COMMIT" >&2
  exit 64
fi

env_file=$1
source_image=$2
source_commit=$3
proof_commit=$4
compose_file=deploy/proof/compose.yml
proof_image="chatring-web-widget-proof:${proof_commit}"

test -f "$env_file"
case "$source_image" in
  *@sha256:*) ;;
  *) echo "SOURCE_IMAGE must be immutable name@sha256:digest" >&2; exit 64 ;;
esac

cleanup() {
  PROOF_IMAGE="$proof_image" docker compose --env-file "$env_file" -f "$compose_file" --profile driver down --volumes --remove-orphans
}
trap cleanup EXIT INT TERM

docker build \
  --file deploy/proof/Dockerfile \
  --tag "$proof_image" \
  --build-arg "BASE_IMAGE=$source_image" \
  --build-arg "CHATRING_SOURCE_COMMIT=$source_commit" \
  --build-arg "CHATRING_PROOF_COMMIT=$proof_commit" \
  .

PROOF_IMAGE="$proof_image" docker compose --env-file "$env_file" -f "$compose_file" config --quiet
PROOF_IMAGE="$proof_image" docker compose --env-file "$env_file" -f "$compose_file" up -d --wait postgres redis docs-postgres docs-redis docs-gpt-backend docs-gpt-worker llm-proxy rails sidekiq
PROOF_IMAGE="$proof_image" docker compose --env-file "$env_file" -f "$compose_file" --profile driver run --rm driver
PROOF_IMAGE="$proof_image" docker compose --env-file "$env_file" -f "$compose_file" exec -T rails \
  ruby -rjson -e 'path="/proof-state/result.json"; payload=JSON.parse(File.read(path)); abort("proof failed") if payload.empty?; STDOUT.write(JSON.pretty_generate(payload))'
