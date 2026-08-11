class CreateChatRingInboxPlaybookExecutions < ActiveRecord::Migration[7.1]
  CONTROLLING_STATUSES = [0, 1, 2, 3].freeze

  def change
    create_executions
    add_execution_indexes_and_foreign_keys
    connect_ai_turns
  end

  private

  def create_executions # rubocop:disable Metrics/MethodLength
    create_table :chat_ring_inbox_playbook_executions do |t|
      t.references :workspace,
                   null: false,
                   foreign_key: { to_table: :chat_ring_workspaces, on_delete: :cascade }
      t.references :inbox_playbook_version,
                   null: false,
                   index: false,
                   foreign_key: { to_table: :chat_ring_inbox_playbook_versions, on_delete: :restrict }
      t.integer :chatwoot_conversation_id, null: false
      t.integer :status, null: false, default: 0
      t.string :current_step_id, null: false
      t.jsonb :collected_fields, null: false, default: {}
      t.jsonb :field_sources, null: false, default: {}
      t.jsonb :transition_history, null: false, default: []
      t.integer :last_trigger_message_id
      t.integer :last_outcome_message_id
      t.datetime :started_at, null: false
      t.datetime :completed_at
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
  end

  def add_execution_indexes_and_foreign_keys # rubocop:disable Metrics/MethodLength
    add_index :chat_ring_inbox_playbook_executions,
              :chatwoot_conversation_id,
              unique: true,
              where: "status IN (#{CONTROLLING_STATUSES.join(', ')})",
              name: 'idx_chatring_one_controlling_playbook_execution'
    add_index :chat_ring_inbox_playbook_executions,
              [:inbox_playbook_version_id, :status],
              name: 'idx_chatring_playbook_execution_version_status'
    add_foreign_key :chat_ring_inbox_playbook_executions,
                    :conversations,
                    column: :chatwoot_conversation_id,
                    on_delete: :cascade
    add_foreign_key :chat_ring_inbox_playbook_executions,
                    :messages,
                    column: :last_trigger_message_id,
                    on_delete: :nullify
    add_foreign_key :chat_ring_inbox_playbook_executions,
                    :messages,
                    column: :last_outcome_message_id,
                    on_delete: :nullify
  end

  def connect_ai_turns
    add_reference :chat_ring_ai_turns,
                  :inbox_playbook_execution,
                  foreign_key: { to_table: :chat_ring_inbox_playbook_executions, on_delete: :cascade },
                  index: { name: 'idx_chatring_turns_on_playbook_execution' }
    add_column :chat_ring_ai_turns, :playbook_execution_lock_version, :integer
    add_column :chat_ring_ai_turns, :playbook_step_id, :string
  end
end
