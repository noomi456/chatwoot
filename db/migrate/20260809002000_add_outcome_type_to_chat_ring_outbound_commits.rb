class AddOutcomeTypeToChatRingOutboundCommits < ActiveRecord::Migration[7.1]
  def change
    add_column :chat_ring_outbound_commits, :outcome_type, :integer, null: false, default: 0
  end
end
