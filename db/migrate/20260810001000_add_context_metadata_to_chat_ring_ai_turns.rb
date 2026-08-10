class AddContextMetadataToChatRingAiTurns < ActiveRecord::Migration[7.1]
  def change
    add_column :chat_ring_ai_turns, :context_metadata, :jsonb, null: false, default: {}
  end
end
