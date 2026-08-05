#!/usr/bin/env bash
set -euo pipefail

readonly backup_env="${CHATRING_BACKUP_ENV:-/etc/chatring/r2-backup.env}"

[[ "${EUID}" -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
[[ -r "${backup_env}" ]] || { echo "Missing backup environment: ${backup_env}" >&2; exit 1; }

set -a
source "${backup_env}"
set +a

readonly postgres_container="${CHATRING_POSTGRES_CONTAINER:-chatring-conversation-core-go5l4m-postgres-1}"
readonly rails_container="${CHATRING_RAILS_CONTAINER:-chatring-conversation-core-go5l4m-rails-1}"
readonly database="${CHATRING_POSTGRES_DATABASE:-chatring_conversation}"
readonly database_user="${CHATRING_POSTGRES_USERNAME:-chatring}"
readonly staging_root="${CHATRING_BACKUP_STAGING:-/var/backups/chatring/conversation-core}"

for required in RESTIC_REPOSITORY RESTIC_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
  [[ -n "${!required:-}" ]] || { echo "Missing ${required}." >&2; exit 1; }
done

install -d -m 0700 "${staging_root}"
run_dir="$(mktemp -d "${staging_root}/run-XXXXXXXX")"
trap 'rm -rf "${run_dir}"' EXIT

dump_path="${run_dir}/chatring-conversation.dump"
storage_path="${run_dir}/chatring-storage.tar.gz"
manifest_path="${run_dir}/manifest.json"

docker exec "${postgres_container}" pg_dump \
  --format=custom --no-owner --no-privileges \
  --username="${database_user}" "${database}" > "${dump_path}"

docker exec "${rails_container}" tar -czf - -C /app/storage . > "${storage_path}"

counts="$(docker exec "${postgres_container}" psql --tuples-only --no-align \
  --username="${database_user}" --dbname="${database}" \
  --command="SELECT json_build_object('accounts',(SELECT count(*) FROM accounts),'conversations',(SELECT count(*) FROM conversations),'messages',(SELECT count(*) FROM messages),'attachments',(SELECT count(*) FROM attachments));")"

image_ref="$(docker inspect --format '{{.Config.Image}}' "${rails_container}")"
git_sha="$(docker exec "${rails_container}" sh -c 'cat /app/.git_sha 2>/dev/null || true')"

jq -n \
  --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg database "${database}" \
  --arg image_ref "${image_ref}" \
  --arg git_sha "${git_sha}" \
  --arg database_sha256 "$(sha256sum "${dump_path}" | awk '{print $1}')" \
  --arg storage_sha256 "$(sha256sum "${storage_path}" | awk '{print $1}')" \
  --argjson counts "${counts}" \
  '{created_at:$created_at,database:$database,image_ref:$image_ref,git_sha:$git_sha,database_sha256:$database_sha256,storage_sha256:$storage_sha256,counts:$counts}' \
  > "${manifest_path}"

snapshot_id="$(restic backup \
  --host chatring-vps \
  --tag chatring-conversation-core \
  --json "${dump_path}" "${storage_path}" "${manifest_path}" | jq -r 'select(.message_type == "summary") | .snapshot_id')"

[[ -n "${snapshot_id}" && "${snapshot_id}" != 'null' ]] || { echo 'Restic did not return a snapshot ID.' >&2; exit 1; }
echo "ChatRing Conversation Core backup complete: ${snapshot_id}"
