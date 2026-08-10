class IndexChatRingAiTurnRecovery < ActiveRecord::Migration[7.1]
  def change
    add_index :chat_ring_ai_turns,
              [:status, :deadline_at, :updated_at],
              where: 'status IN (0, 1, 2, 3, 4)',
              name: 'idx_chatring_ai_turns_recovery_due'
  end
end
