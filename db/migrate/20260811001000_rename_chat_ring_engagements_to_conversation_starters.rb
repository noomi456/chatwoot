class RenameChatRingEngagementsToConversationStarters < ActiveRecord::Migration[7.1]
  def change
    rename_table :chat_ring_inbox_engagements, :chat_ring_inbox_conversation_starters
    rename_index :chat_ring_inbox_conversation_starters,
                 'idx_chatring_engagements_unique_inbox',
                 'idx_chatring_starters_unique_inbox'
  end
end
