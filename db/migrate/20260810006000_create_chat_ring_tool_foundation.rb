class CreateChatRingToolFoundation < ActiveRecord::Migration[7.1]
  def change
    create_tool_policies
    create_tool_policy_versions
    connect_current_policy_version
  end

  private

  def create_tool_policies
    create_table :chat_ring_inbox_tool_policies do |t|
      t.references :workspace,
                   null: false,
                   foreign_key: { to_table: :chat_ring_workspaces, on_delete: :cascade }
      t.integer :chatwoot_inbox_id, null: false
      t.bigint :current_version_id
      t.integer :status, null: false, default: 0
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :chat_ring_inbox_tool_policies,
              :chatwoot_inbox_id,
              unique: true,
              name: 'idx_chatring_tool_policies_on_inbox'
    add_foreign_key :chat_ring_inbox_tool_policies,
                    :inboxes,
                    column: :chatwoot_inbox_id,
                    on_delete: :cascade
  end

  def create_tool_policy_versions
    create_table :chat_ring_inbox_tool_policy_versions do |t|
      t.references :inbox_tool_policy,
                   null: false,
                   index: false,
                   foreign_key: { to_table: :chat_ring_inbox_tool_policies, on_delete: :cascade }
      t.integer :version, null: false
      t.jsonb :enabled_tools, null: false, default: []
      t.jsonb :tool_configurations, null: false, default: {}
      t.jsonb :renderer_policy, null: false, default: {}
      t.bigint :created_by_id
      t.datetime :published_at, null: false
      t.timestamps
    end
    add_tool_policy_version_constraints
  end

  def add_tool_policy_version_constraints
    add_index :chat_ring_inbox_tool_policy_versions,
              [:inbox_tool_policy_id, :version],
              unique: true,
              name: 'idx_chatring_tool_policy_versions_unique'
    add_foreign_key :chat_ring_inbox_tool_policy_versions,
                    :users,
                    column: :created_by_id,
                    on_delete: :nullify
  end

  def connect_current_policy_version
    add_foreign_key :chat_ring_inbox_tool_policies,
                    :chat_ring_inbox_tool_policy_versions,
                    column: :current_version_id,
                    on_delete: :nullify
  end
end
