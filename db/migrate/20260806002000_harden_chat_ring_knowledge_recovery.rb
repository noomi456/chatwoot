class HardenChatRingKnowledgeRecovery < ActiveRecord::Migration[7.1]
  def up # rubocop:disable Metrics/MethodLength
    add_column :chat_ring_knowledge_versions, :abandoned_at, :datetime
    add_column :chat_ring_knowledge_versions, :abandon_reason, :string, limit: 1000
    add_index :chat_ring_knowledge_versions, [:status, :evaluation_status, :evaluated_at],
              name: 'index_chatring_knowledge_versions_on_abandonment_candidates'
    remove_check_constraint :chat_ring_knowledge_versions,
                            name: 'chatring_knowledge_versions_status_check'
    add_check_constraint :chat_ring_knowledge_versions,
                         "status IN ('pending', 'crawling', 'ingesting', 'ready', 'published', 'retired', 'failed', 'abandoned')",
                         name: 'chatring_knowledge_versions_status_check'
    add_check_constraint :chat_ring_knowledge_versions,
                         "status != 'abandoned' OR (abandoned_at IS NOT NULL AND abandon_reason IS NOT NULL)",
                         name: 'chatring_knowledge_versions_abandonment_fields_check'

    add_column :chat_ring_knowledge_provider_cleanups, :lease_token, :string
    add_column :chat_ring_knowledge_provider_cleanups, :lease_expires_at, :datetime
    add_column :chat_ring_knowledge_provider_cleanups, :next_attempt_at, :datetime
    add_column :chat_ring_knowledge_provider_cleanups, :last_enqueued_at, :datetime
    add_column :chat_ring_knowledge_provider_cleanups, :manual_retry_count, :integer, null: false, default: 0
    execute <<~SQL.squish
      UPDATE chat_ring_knowledge_provider_cleanups
      SET next_attempt_at = eligible_at
      WHERE next_attempt_at IS NULL
    SQL
    execute <<~SQL.squish
      UPDATE chat_ring_knowledge_provider_cleanups
      SET status = 'pending',
          next_attempt_at = CURRENT_TIMESTAMP,
          last_enqueued_at = NULL
      WHERE status = 'retrying'
    SQL
    change_column_null :chat_ring_knowledge_provider_cleanups, :next_attempt_at, false
    add_index :chat_ring_knowledge_provider_cleanups, :lease_token,
              unique: true,
              where: 'lease_token IS NOT NULL',
              name: 'index_chatring_provider_cleanups_on_lease_token'
    add_index :chat_ring_knowledge_provider_cleanups, [:status, :next_attempt_at],
              name: 'index_chatring_provider_cleanups_on_due_work'
    add_index :chat_ring_knowledge_provider_cleanups, [:status, :lease_expires_at],
              name: 'index_chatring_provider_cleanups_on_expired_leases'
    add_check_constraint :chat_ring_knowledge_provider_cleanups,
                         '(lease_token IS NULL) = (lease_expires_at IS NULL)',
                         name: 'chatring_provider_cleanups_lease_pair_check'
    add_check_constraint :chat_ring_knowledge_provider_cleanups,
                         "(status = 'retrying') = (lease_token IS NOT NULL)",
                         name: 'chatring_provider_cleanups_lease_status_check'
  end

  def down # rubocop:disable Metrics/MethodLength
    remove_check_constraint :chat_ring_knowledge_provider_cleanups,
                            name: 'chatring_provider_cleanups_lease_status_check'
    remove_check_constraint :chat_ring_knowledge_provider_cleanups,
                            name: 'chatring_provider_cleanups_lease_pair_check'
    remove_index :chat_ring_knowledge_provider_cleanups,
                 name: 'index_chatring_provider_cleanups_on_expired_leases'
    remove_index :chat_ring_knowledge_provider_cleanups,
                 name: 'index_chatring_provider_cleanups_on_due_work'
    remove_index :chat_ring_knowledge_provider_cleanups,
                 name: 'index_chatring_provider_cleanups_on_lease_token'
    remove_column :chat_ring_knowledge_provider_cleanups, :manual_retry_count
    remove_column :chat_ring_knowledge_provider_cleanups, :last_enqueued_at
    remove_column :chat_ring_knowledge_provider_cleanups, :next_attempt_at
    remove_column :chat_ring_knowledge_provider_cleanups, :lease_expires_at
    remove_column :chat_ring_knowledge_provider_cleanups, :lease_token

    execute <<~SQL.squish
      UPDATE chat_ring_knowledge_versions
      SET status = 'failed',
          failure_code = 'abandoned_migration_rollback',
          failure_message = COALESCE(abandon_reason, 'Abandoned before lifecycle-hardening rollback')
      WHERE status = 'abandoned'
    SQL
    remove_check_constraint :chat_ring_knowledge_versions,
                            name: 'chatring_knowledge_versions_abandonment_fields_check'
    remove_check_constraint :chat_ring_knowledge_versions,
                            name: 'chatring_knowledge_versions_status_check'
    add_check_constraint :chat_ring_knowledge_versions,
                         "status IN ('pending', 'crawling', 'ingesting', 'ready', 'published', 'retired', 'failed')",
                         name: 'chatring_knowledge_versions_status_check'
    remove_index :chat_ring_knowledge_versions,
                 name: 'index_chatring_knowledge_versions_on_abandonment_candidates'
    remove_column :chat_ring_knowledge_versions, :abandon_reason
    remove_column :chat_ring_knowledge_versions, :abandoned_at
  end
end
