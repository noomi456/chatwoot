class ChatRing::AssistantAgentBotConnection < ApplicationRecord
  self.table_name = 'chat_ring_assistant_agent_bot_connections'

  enum status: { provisioning: 0, active: 1, unhealthy: 2, inactive: 3 }
  before_validation :ensure_webhook_key, on: :create

  belongs_to :workspace, class_name: 'ChatRing::Workspace', inverse_of: :assistant_agent_bot_connections
  belongs_to :assistant, class_name: 'ChatRing::Assistant', inverse_of: :agent_bot_connection
  belongs_to :agent_bot
  has_many :inbox_bindings,
           class_name: 'ChatRing::InboxAssistantBinding',
           inverse_of: :assistant_agent_bot_connection,
           dependent: :destroy
  has_many :webhook_deliveries,
           class_name: 'ChatRing::WebhookDelivery',
           inverse_of: :assistant_agent_bot_connection,
           dependent: :destroy

  validates :assistant_id, uniqueness: true
  validates :agent_bot_id, uniqueness: true
  validates :webhook_key, presence: true, uniqueness: true
  validate :ownership_matches
  validate :managed_agent_bot_required
  validate :active_connection_has_secret_references

  def webhook_url
    base_url = (ENV.fetch('FRONTEND_URL', nil).presence || 'http://localhost:3000').delete_suffix('/')
    "#{base_url}/webhooks/chatring/agent-bots/#{webhook_key}"
  end

  private

  def ensure_webhook_key
    self.webhook_key ||= SecureRandom.uuid
  end

  def ownership_matches
    return if workspace.blank? || assistant.blank? || agent_bot.blank?

    errors.add(:assistant, 'must belong to the selected Workspace') unless assistant.workspace_id == workspace_id
    return if agent_bot.account_id.present? && agent_bot.account_id == workspace.chatwoot_account_id

    errors.add(:agent_bot, 'must be account-owned by the Workspace Chatwoot Account')
  end

  def managed_agent_bot_required
    return if agent_bot.blank? || agent_bot.chatring_assistant?

    errors.add(:agent_bot, 'must be a managed ChatRing Assistant identity')
  end

  def active_connection_has_secret_references
    return unless active?

    errors.add(:access_token_secret_ref, 'is required') if access_token_secret_ref.blank?
    errors.add(:webhook_secret_ref, 'is required') if webhook_secret_ref.blank?
  end
end
