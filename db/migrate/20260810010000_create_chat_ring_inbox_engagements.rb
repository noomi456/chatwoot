class CreateChatRingInboxEngagements < ActiveRecord::Migration[7.1]
  def change
    create_engagements_table
    add_engagement_indexes
    add_engagement_foreign_keys
  end

  private

  def create_engagements_table
    create_table :chat_ring_inbox_engagements do |t|
      t.references :workspace,
                   null: false,
                   foreign_key: { to_table: :chat_ring_workspaces, on_delete: :cascade }
      t.integer :chatwoot_inbox_id, null: false
      t.bigint :updated_by_id
      t.boolean :enabled, null: false, default: true
      t.jsonb :starters, null: false, default: []
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
  end

  def add_engagement_indexes
    add_index :chat_ring_inbox_engagements,
              :chatwoot_inbox_id,
              unique: true,
              name: 'idx_chatring_engagements_unique_inbox'
    add_index :chat_ring_inbox_engagements, :updated_by_id
  end

  def add_engagement_foreign_keys
    add_foreign_key :chat_ring_inbox_engagements,
                    :inboxes,
                    column: :chatwoot_inbox_id,
                    on_delete: :cascade
    add_foreign_key :chat_ring_inbox_engagements,
                    :users,
                    column: :updated_by_id,
                    on_delete: :nullify
  end
end
