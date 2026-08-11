class CreateChatRingInboxPlaybooks < ActiveRecord::Migration[7.1]
  def change
    create_playbooks
    create_versions
    connect_current_version
  end

  private

  def create_playbooks # rubocop:disable Metrics/MethodLength
    create_table :chat_ring_inbox_playbooks do |t|
      t.references :workspace,
                   null: false,
                   foreign_key: { to_table: :chat_ring_workspaces, on_delete: :cascade }
      t.integer :chatwoot_inbox_id, null: false
      t.bigint :current_version_id
      t.bigint :created_by_id
      t.string :name, null: false
      t.text :purpose, null: false, default: ''
      t.jsonb :draft_definition, null: false, default: {}
      t.integer :status, null: false, default: 0
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :chat_ring_inbox_playbooks,
              'chatwoot_inbox_id, lower(name)',
              unique: true,
              name: 'idx_chatring_playbooks_unique_inbox_name'
    add_foreign_key :chat_ring_inbox_playbooks,
                    :inboxes,
                    column: :chatwoot_inbox_id,
                    on_delete: :cascade
    add_foreign_key :chat_ring_inbox_playbooks,
                    :users,
                    column: :created_by_id,
                    on_delete: :nullify
  end

  def create_versions # rubocop:disable Metrics/MethodLength
    create_table :chat_ring_inbox_playbook_versions do |t|
      t.references :inbox_playbook,
                   null: false,
                   index: false,
                   foreign_key: { to_table: :chat_ring_inbox_playbooks, on_delete: :cascade }
      t.integer :version, null: false
      t.string :name, null: false
      t.text :purpose, null: false, default: ''
      t.jsonb :definition, null: false, default: {}
      t.jsonb :capability_snapshot, null: false, default: {}
      t.jsonb :validation_result, null: false, default: {}
      t.bigint :created_by_id
      t.datetime :published_at, null: false
      t.timestamps
    end
    add_index :chat_ring_inbox_playbook_versions,
              [:inbox_playbook_id, :version],
              unique: true,
              name: 'idx_chatring_playbook_versions_unique'
    add_foreign_key :chat_ring_inbox_playbook_versions,
                    :users,
                    column: :created_by_id,
                    on_delete: :nullify
  end

  def connect_current_version
    add_foreign_key :chat_ring_inbox_playbooks,
                    :chat_ring_inbox_playbook_versions,
                    column: :current_version_id,
                    on_delete: :nullify
  end
end
