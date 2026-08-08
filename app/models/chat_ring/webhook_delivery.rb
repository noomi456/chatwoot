class ChatRing::WebhookDelivery < ApplicationRecord
  self.table_name = 'chat_ring_webhook_deliveries'

  enum verification_status: { verified: 0 }
  enum processing_status: { received: 0, processed: 1, ignored: 2 }

  belongs_to :workspace, class_name: 'ChatRing::Workspace', inverse_of: :webhook_deliveries
  belongs_to :assistant_agent_bot_connection,
             class_name: 'ChatRing::AssistantAgentBotConnection',
             inverse_of: :webhook_deliveries

  validates :delivery_id, :event_type, :payload_hash, :received_at, presence: true
  validates :delivery_id, length: { maximum: 255 }
  validates :event_type, length: { maximum: 100 }
  validates :payload_account_id, :payload_inbox_id, numericality: { only_integer: true, greater_than: 0 }
  validates :payload_hash, format: { with: /\A[0-9a-f]{64}\z/ }
  validate :ownership_matches

  attr_readonly :workspace_id,
                :assistant_agent_bot_connection_id,
                :delivery_id,
                :event_type,
                :payload_account_id,
                :payload_inbox_id,
                :payload_conversation_id,
                :payload_message_id,
                :payload_hash,
                :received_at

  private

  def ownership_matches
    return if workspace.blank? || assistant_agent_bot_connection.blank?
    return if assistant_agent_bot_connection.workspace_id == workspace_id

    errors.add(:assistant_agent_bot_connection, 'must belong to the selected Workspace')
  end
end
