class CreateChatRingWebhookDeliveriesAndAiTurns < ActiveRecord::Migration[7.1]
  def change
    add_webhook_key
    create_webhook_deliveries
    create_ai_turns
  end

  private

  def add_webhook_key
    add_column :chat_ring_assistant_agent_bot_connections,
               :webhook_key,
               :uuid,
               default: -> { 'gen_random_uuid()' },
               null: false
    add_index :chat_ring_assistant_agent_bot_connections, :webhook_key, unique: true
  end

  # rubocop:disable Metrics/MethodLength
  def create_webhook_deliveries
    create_table :chat_ring_webhook_deliveries do |t|
      t.references :workspace, null: false, foreign_key: { to_table: :chat_ring_workspaces, on_delete: :cascade }
      t.references :assistant_agent_bot_connection,
                   null: false,
                   foreign_key: { to_table: :chat_ring_assistant_agent_bot_connections, on_delete: :cascade },
                   index: { name: 'idx_chatring_deliveries_on_bot_connection' }
      t.string :delivery_id, null: false
      t.string :event_type, null: false
      t.integer :payload_account_id, null: false
      t.integer :payload_inbox_id, null: false
      t.integer :payload_conversation_id
      t.bigint :payload_message_id
      t.string :payload_hash, null: false
      t.integer :verification_status, null: false, default: 0
      t.integer :processing_status, null: false, default: 0
      t.string :error_code
      t.datetime :received_at, null: false
      t.timestamps
    end

    add_index :chat_ring_webhook_deliveries, :delivery_id, unique: true
    add_index :chat_ring_webhook_deliveries, [:workspace_id, :received_at], name: 'idx_chatring_deliveries_on_workspace_time'
  end

  def create_ai_turns
    create_table :chat_ring_ai_turns do |t|
      t.references :workspace, null: false, foreign_key: { to_table: :chat_ring_workspaces, on_delete: :cascade }
      t.integer :chatwoot_conversation_id, null: false
      t.integer :trigger_message_id, null: false
      t.references :inbox_assistant_binding,
                   null: false,
                   foreign_key: { to_table: :chat_ring_inbox_assistant_bindings, on_delete: :restrict },
                   index: { name: 'idx_chatring_turns_on_inbox_binding' }
      t.bigint :binding_version, null: false
      t.references :assistant, null: false, foreign_key: { to_table: :chat_ring_assistants, on_delete: :restrict }
      t.references :assistant_version,
                   null: false,
                   foreign_key: { to_table: :chat_ring_assistant_versions, on_delete: :restrict }
      t.bigint :expected_agent_bot_id, null: false
      t.integer :status, null: false, default: 0
      t.datetime :started_at
      t.datetime :completed_at
      t.string :decision_type
      t.string :failure_code
      t.timestamps
    end

    add_foreign_key :chat_ring_ai_turns, :conversations, column: :chatwoot_conversation_id, on_delete: :cascade
    add_foreign_key :chat_ring_ai_turns, :messages, column: :trigger_message_id, on_delete: :cascade
    add_foreign_key :chat_ring_ai_turns, :agent_bots, column: :expected_agent_bot_id, on_delete: :restrict
    add_index :chat_ring_ai_turns,
              [:workspace_id, :chatwoot_conversation_id, :trigger_message_id],
              unique: true,
              name: 'idx_chatring_turns_one_per_trigger'
  end
  # rubocop:enable Metrics/MethodLength
end
