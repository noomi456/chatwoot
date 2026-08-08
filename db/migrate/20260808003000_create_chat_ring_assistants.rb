class CreateChatRingAssistants < ActiveRecord::Migration[7.1]
  def change
    create_assistants
    create_assistant_versions
    add_current_version_to_assistants
    create_agent_bot_connections
    create_inbox_bindings
  end

  private

  def create_assistants
    create_table :chat_ring_assistants do |t|
      t.references :workspace,
                   null: false,
                   index: false,
                   foreign_key: { to_table: :chat_ring_workspaces, on_delete: :cascade }
      t.string :name, null: false
      t.integer :status, null: false, default: 0
      t.timestamps
    end

    add_index :chat_ring_assistants, [:workspace_id, :name], unique: true
  end

  def create_assistant_versions
    create_table :chat_ring_assistant_versions do |t|
      t.references :assistant, null: false, index: false, foreign_key: { to_table: :chat_ring_assistants, on_delete: :cascade }
      t.references :knowledge_scope, null: false, foreign_key: { to_table: :chat_ring_knowledge_scopes, on_delete: :restrict }
      t.integer :version, null: false
      t.jsonb :identity, null: false, default: {}
      t.jsonb :goals, null: false, default: []
      t.text :instructions, null: false, default: ''
      t.jsonb :response_guidelines, null: false, default: []
      t.jsonb :guardrails, null: false, default: []
      t.jsonb :audience_policy, null: false, default: {}
      t.jsonb :availability_policy, null: false, default: {}
      t.jsonb :handoff_policy, null: false, default: {}
      t.jsonb :tool_grants, null: false, default: []
      t.jsonb :conversation_policy, null: false, default: {}
      t.datetime :published_at, null: false
      t.timestamps
    end

    add_index :chat_ring_assistant_versions, [:assistant_id, :version], unique: true
  end

  def add_current_version_to_assistants
    add_reference :chat_ring_assistants,
                  :current_version,
                  foreign_key: { to_table: :chat_ring_assistant_versions, on_delete: :nullify }
  end

  def create_agent_bot_connections
    create_table :chat_ring_assistant_agent_bot_connections do |t|
      t.references :workspace, null: false, foreign_key: { to_table: :chat_ring_workspaces, on_delete: :cascade }
      t.references :assistant,
                   null: false,
                   index: false,
                   foreign_key: { to_table: :chat_ring_assistants, on_delete: :cascade }
      t.references :agent_bot, null: false, index: false, foreign_key: { on_delete: :restrict }
      t.string :access_token_secret_ref
      t.string :webhook_secret_ref
      t.integer :status, null: false, default: 0
      t.datetime :last_verified_at
      t.timestamps
    end

    add_agent_bot_connection_indexes
  end

  def add_agent_bot_connection_indexes
    add_index :chat_ring_assistant_agent_bot_connections,
              :assistant_id,
              unique: true,
              name: 'idx_chatring_bot_connections_on_assistant'
    add_index :chat_ring_assistant_agent_bot_connections,
              :agent_bot_id,
              unique: true,
              name: 'idx_chatring_bot_connections_on_agent_bot'
  end

  def create_inbox_bindings
    create_table :chat_ring_inbox_assistant_bindings do |t|
      t.references :workspace, null: false, foreign_key: { to_table: :chat_ring_workspaces, on_delete: :cascade }
      t.integer :chatwoot_inbox_id, null: false
      t.references :assistant, null: false, foreign_key: { to_table: :chat_ring_assistants, on_delete: :cascade }
      t.references :assistant_agent_bot_connection,
                   null: false,
                   foreign_key: { to_table: :chat_ring_assistant_agent_bot_connections, on_delete: :cascade },
                   index: { name: 'idx_chatring_bindings_on_bot_connection' }
      t.integer :status, null: false, default: 0
      t.bigint :binding_version, null: false
      t.timestamps
    end

    add_inbox_binding_constraints
  end

  def add_inbox_binding_constraints
    add_foreign_key :chat_ring_inbox_assistant_bindings,
                    :inboxes,
                    column: :chatwoot_inbox_id,
                    on_delete: :cascade
    add_index :chat_ring_inbox_assistant_bindings,
              [:workspace_id, :chatwoot_inbox_id, :binding_version],
              unique: true,
              name: 'idx_chatring_bindings_on_inbox_version'
    add_index :chat_ring_inbox_assistant_bindings,
              [:workspace_id, :chatwoot_inbox_id],
              unique: true,
              where: 'status = 1',
              name: 'idx_chatring_bindings_one_active_per_inbox'
  end
end
