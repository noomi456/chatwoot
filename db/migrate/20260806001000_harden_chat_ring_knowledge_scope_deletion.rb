class HardenChatRingKnowledgeScopeDeletion < ActiveRecord::Migration[7.1]
  def change # rubocop:disable Metrics/MethodLength
    add_column :chat_ring_knowledge_provider_cleanups, :account_id, :bigint
    add_column :chat_ring_knowledge_provider_cleanups, :inbox_id, :bigint
    reversible do |direction|
      direction.up do
        execute <<~SQL.squish
          UPDATE chat_ring_knowledge_provider_cleanups AS cleanups
          SET account_id = versions.account_id,
              inbox_id = versions.inbox_id
          FROM chat_ring_knowledge_versions AS versions
          WHERE cleanups.knowledge_version_id = versions.id
        SQL
      end
    end
    change_column_null :chat_ring_knowledge_provider_cleanups, :account_id, false
    change_column_null :chat_ring_knowledge_provider_cleanups, :inbox_id, false
    add_index :chat_ring_knowledge_provider_cleanups, [:account_id, :inbox_id],
              name: 'index_chatring_provider_cleanups_on_scope'
    remove_foreign_key :chat_ring_knowledge_provider_cleanups, :chat_ring_knowledge_versions

    replace_foreign_key :chat_ring_knowledge_documents, :chat_ring_knowledge_versions, column: :knowledge_version_id
    replace_foreign_key :chat_ring_knowledge_versions, :accounts
    replace_foreign_key :chat_ring_knowledge_versions, :inboxes
    replace_foreign_key :chat_ring_knowledge_publications, :accounts
    replace_foreign_key :chat_ring_knowledge_publications, :inboxes
    replace_foreign_key :chat_ring_knowledge_publication_events, :accounts
    replace_foreign_key :chat_ring_knowledge_publication_events, :inboxes
  end

  private

  def replace_foreign_key(from_table, to_table, column: nil)
    remove_foreign_key from_table, to_table
    options = { on_delete: :cascade }
    options[:column] = column if column
    add_foreign_key from_table, to_table, **options
  end
end
