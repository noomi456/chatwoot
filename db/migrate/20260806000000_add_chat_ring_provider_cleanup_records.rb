class AddChatRingProviderCleanupRecords < ActiveRecord::Migration[7.1]
  def change
    create_table :chat_ring_knowledge_provider_cleanups do |t|
      t.references :knowledge_version,
                   null: false,
                   foreign_key: { to_table: :chat_ring_knowledge_versions },
                   index: { unique: true, name: 'index_chatring_provider_cleanup_on_version' }
      t.string :provider_source_id, null: false
      t.string :binding_digest, null: false
      t.string :status, null: false, default: 'pending'
      t.integer :attempts, null: false, default: 0
      t.datetime :eligible_at, null: false
      t.datetime :cleaned_at
      t.string :last_error, limit: 1000
      t.timestamps
    end

    add_check_constraint :chat_ring_knowledge_provider_cleanups,
                         "status IN ('pending', 'retrying', 'succeeded', 'cancelled', 'failed')",
                         name: 'chatring_knowledge_provider_cleanups_status_check'
  end
end
