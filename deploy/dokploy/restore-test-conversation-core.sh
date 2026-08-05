#!/usr/bin/env bash
set -euo pipefail

readonly backup_env="${CHATRING_BACKUP_ENV:-/etc/chatring/r2-backup.env}"

[[ "${EUID}" -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
[[ -r "${backup_env}" ]] || { echo "Missing backup environment: ${backup_env}" >&2; exit 1; }

set -a
source "${backup_env}"
set +a

readonly postgres_container="${CHATRING_POSTGRES_CONTAINER:-chatring-conversation-core-go5l4m-postgres-1}"
readonly database_user="${CHATRING_POSTGRES_USERNAME:-chatring}"

restore_root="$(mktemp -d)"
restore_database="chatring_restore_test_$(date +%s)"
cleanup() {
  docker exec "${postgres_container}" dropdb --if-exists --username="${database_user}" "${restore_database}" >/dev/null 2>&1 || true
  rm -rf "${restore_root}"
}
trap cleanup EXIT

restic restore latest \
  --host chatring-vps \
  --tag chatring-conversation-core \
  --target "${restore_root}" >/dev/null

dump_path="$(find "${restore_root}" -type f -name chatring-conversation.dump -print -quit)"
storage_path="$(find "${restore_root}" -type f -name chatring-storage.tar.gz -print -quit)"
manifest_path="$(find "${restore_root}" -type f -name manifest.json -print -quit)"

[[ -s "${dump_path}" && -s "${storage_path}" && -s "${manifest_path}" ]]
[[ "$(sha256sum "${dump_path}" | awk '{print $1}')" == "$(jq -r '.database_sha256' "${manifest_path}")" ]]
[[ "$(sha256sum "${storage_path}" | awk '{print $1}')" == "$(jq -r '.storage_sha256' "${manifest_path}")" ]]
tar -tzf "${storage_path}" >/dev/null

docker exec "${postgres_container}" createdb --username="${database_user}" "${restore_database}"
docker exec -i "${postgres_container}" pg_restore \
  --no-owner --no-privileges \
  --username="${database_user}" --dbname="${restore_database}" < "${dump_path}"

restored_counts="$(docker exec "${postgres_container}" psql --tuples-only --no-align \
  --username="${database_user}" --dbname="${restore_database}" \
  --command="SELECT json_build_object('accounts',(SELECT count(*) FROM accounts),'conversations',(SELECT count(*) FROM conversations),'messages',(SELECT count(*) FROM messages),'attachments',(SELECT count(*) FROM attachments));")"

jq -e --argjson restored "${restored_counts}" '.counts == $restored' "${manifest_path}" >/dev/null
jq -n --arg database "${restore_database}" --argjson counts "${restored_counts}" \
  '{status:"passed",temporary_database:$database,checksums:true,storage_archive:true,counts:$counts}'
