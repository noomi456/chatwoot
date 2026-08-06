class HardenChatRingKnowledgeLifecycle < ActiveRecord::Migration[7.1]
  def change # rubocop:disable Metrics/MethodLength
    add_column :chat_ring_knowledge_versions, :processing_lease_token, :string
    add_column :chat_ring_knowledge_versions, :processing_lease_expires_at, :datetime
    add_index :chat_ring_knowledge_versions, :processing_lease_token, unique: true, where: 'processing_lease_token IS NOT NULL'

    create_table :chat_ring_knowledge_publication_events do |t|
      t.references :account, null: false, foreign_key: true
      t.references :inbox, null: false, foreign_key: true
      t.references :from_knowledge_version,
                   foreign_key: { to_table: :chat_ring_knowledge_versions },
                   index: { name: 'index_chatring_publication_events_on_from_version' }
      t.references :to_knowledge_version,
                   null: false,
                   foreign_key: { to_table: :chat_ring_knowledge_versions },
                   index: { name: 'index_chatring_publication_events_on_to_version' }
      t.string :action, null: false
      t.jsonb :metadata, null: false, default: {}
      t.datetime :created_at, null: false
    end

    add_check_constraint :chat_ring_knowledge_publication_events,
                         "action IN ('publish', 'rollback')",
                         name: 'chatring_knowledge_publication_events_action_check'

    reversible do |direction|
      direction.up do
        execute <<~SQL.squish
          UPDATE chat_ring_knowledge_versions
          SET provider_agent_id = NULL,
              provider_agent_api_key = NULL,
              provider_agent_creation_started_at = NULL
        SQL
      end
    end
  end
end
