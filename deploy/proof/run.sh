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
test "$(stat -c '%a' "$env_file")" = "600"
set -a
. "$env_file"
set +a
case "${PROOF_RUN_ID:-}" in
  ''|*[!a-z0-9-]*) echo "PROOF_RUN_ID must contain only lowercase letters, digits and hyphens" >&2; exit 64 ;;
esac
COMPOSE_PROJECT_NAME="chatring-proof-${PROOF_RUN_ID}"
export COMPOSE_PROJECT_NAME

test "$(git rev-parse HEAD)" = "$proof_commit"
git cat-file -e "${proof_commit}^{commit}"
test -z "$(git status --porcelain -- deploy/proof)"
proof_manifest=$(git ls-tree -r "$proof_commit" -- deploy/proof | sha256sum | awk '{print $1}')
case "$source_image" in
  *@sha256:*) ;;
  *) echo "SOURCE_IMAGE must be immutable name@sha256:digest" >&2; exit 64 ;;
esac
log_file=$(mktemp /tmp/chatring-proof-logs.XXXXXX)

cleanup() {
  PROOF_IMAGE="$proof_image" docker compose --env-file "$env_file" -f "$compose_file" --profile driver down --volumes --remove-orphans
  rm -f "$log_file"
}
trap cleanup EXIT INT TERM

docker build \
  --file deploy/proof/Dockerfile \
  --tag "$proof_image" \
  --build-arg "BASE_IMAGE=$source_image" \
  --build-arg "CHATRING_SOURCE_COMMIT=$source_commit" \
  --build-arg "CHATRING_PROOF_COMMIT=$proof_commit" \
  --build-arg "CHATRING_PROOF_MANIFEST=$proof_manifest" \
  .

test "$(docker image inspect "$proof_image" --format '{{ index .Config.Labels "io.chatring.proof.base_commit" }}')" = "$source_commit"
test "$(docker image inspect "$proof_image" --format '{{ index .Config.Labels "io.chatring.proof.commit" }}')" = "$proof_commit"
test "$(docker image inspect "$proof_image" --format '{{ index .Config.Labels "io.chatring.proof.manifest" }}')" = "$proof_manifest"

PROOF_IMAGE="$proof_image" docker compose --env-file "$env_file" -f "$compose_file" config --quiet
PROOF_IMAGE="$proof_image" docker compose --env-file "$env_file" -f "$compose_file" up -d --wait postgres redis docs-postgres docs-redis docs-gpt-backend docs-gpt-worker llm-proxy rails sidekiq
PROOF_IMAGE="$proof_image" docker compose --env-file "$env_file" -f "$compose_file" --profile driver run --rm driver
PROOF_IMAGE="$proof_image" docker compose --env-file "$env_file" -f "$compose_file" logs --no-color \
  rails sidekiq docs-gpt-backend docs-gpt-worker > "$log_file"
PROOF_IMAGE="$proof_image" docker compose --env-file "$env_file" -f "$compose_file" exec -T rails \
  bundle exec ruby /app/deploy/proof/log_scan.rb < "$log_file" >/dev/null
PROOF_IMAGE="$proof_image" docker compose --env-file "$env_file" -f "$compose_file" exec -T rails \
  ruby -rjson -e 'result=JSON.parse(File.read("/proof-state/result.json")); result["log_scan"]=JSON.parse(File.read("/proof-state/log_scan.json")); abort("proof failed") if result.empty?; STDOUT.write(JSON.pretty_generate(result))'
