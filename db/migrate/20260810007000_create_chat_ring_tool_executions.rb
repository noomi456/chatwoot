class CreateChatRingToolExecutions < ActiveRecord::Migration[7.1]
  def change
    create_table :chat_ring_tool_executions do |t|
      add_native_references(t)
      add_tool_payload(t)
      add_execution_state(t)
      t.timestamps
    end

    add_index :chat_ring_tool_executions, :idempotency_key, unique: true
  end

  private

  def add_native_references(table)
    table.references :ai_turn, null: false, index: { unique: true },
                               foreign_key: { to_table: :chat_ring_ai_turns, on_delete: :cascade }
    table.references :inbox_tool_policy_version,
                     null: false,
                     index: { name: 'idx_chatring_tool_executions_on_policy_version' },
                     foreign_key: { to_table: :chat_ring_inbox_tool_policy_versions, on_delete: :restrict }
    table.references :outbound_commit,
                     null: false,
                     index: { unique: true },
                     foreign_key: { to_table: :chat_ring_outbound_commits, on_delete: :cascade }
  end

  def add_tool_payload(table)
    table.string :tool_key, null: false
    table.integer :tool_version, null: false
    table.jsonb :validated_arguments, null: false, default: {}
    table.jsonb :result_payload, null: false, default: {}
    table.string :renderer, null: false
    table.text :rendered_content, null: false
  end

  def add_execution_state(table)
    table.integer :status, null: false, default: 0
    table.string :authorization_result, null: false
    table.string :idempotency_key, null: false
    table.string :failure_code
    table.datetime :attempted_at
    table.datetime :committed_at
  end
end
