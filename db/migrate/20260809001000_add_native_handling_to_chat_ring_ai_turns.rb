class AddNativeHandlingToChatRingAiTurns < ActiveRecord::Migration[7.1]
  def up
    add_column :chat_ring_ai_turns, :native_handling_snapshot, :jsonb, null: false, default: {}
    add_column :chat_ring_ai_turns, :deadline_at, :datetime
    execute <<~SQL.squish
      UPDATE chat_ring_ai_turns
      SET deadline_at = COALESCE(completed_at, created_at) + INTERVAL '2 minutes'
      WHERE deadline_at IS NULL
    SQL
  end

  def down
    remove_column :chat_ring_ai_turns, :deadline_at
    remove_column :chat_ring_ai_turns, :native_handling_snapshot
  end
end
