class CreateChatRingNativeHandlingCompletions < ActiveRecord::Migration[7.1]
  def change
    create_table :chat_ring_native_handling_completions do |t|
      t.references :trigger_message, null: false, index: false, foreign_key: { to_table: :messages, on_delete: :cascade }
      t.references :ai_turn, index: false, foreign_key: { to_table: :chat_ring_ai_turns, on_delete: :nullify }
      t.jsonb :template_snapshot, null: false, default: {}
      t.jsonb :automation_snapshot, null: false, default: {}
      t.datetime :template_completed_at
      t.datetime :automation_completed_at
      t.datetime :released_at
      t.timestamps
    end

    add_index :chat_ring_native_handling_completions,
              :trigger_message_id,
              unique: true,
              name: 'idx_chatring_native_handling_one_per_message'
    add_index :chat_ring_native_handling_completions,
              :ai_turn_id,
              unique: true,
              where: 'ai_turn_id IS NOT NULL',
              name: 'idx_chatring_native_handling_one_per_turn'
  end
end
