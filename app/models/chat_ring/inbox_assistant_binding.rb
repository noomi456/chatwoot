class ChatRing::InboxAssistantBinding < ApplicationRecord
  self.table_name = 'chat_ring_inbox_assistant_bindings'

  enum status: { inactive: 0, active: 1, draining: 2 }

  belongs_to :workspace, class_name: 'ChatRing::Workspace', inverse_of: :inbox_assistant_bindings
  belongs_to :inbox, class_name: 'Inbox', foreign_key: :chatwoot_inbox_id, inverse_of: false
  belongs_to :assistant, class_name: 'ChatRing::Assistant', inverse_of: :inbox_bindings
  belongs_to :assistant_agent_bot_connection,
             class_name: 'ChatRing::AssistantAgentBotConnection',
             inverse_of: :inbox_bindings
  has_many :ai_turns,
           class_name: 'ChatRing::AiTurn',
           inverse_of: :inbox_assistant_binding,
           dependent: :restrict_with_exception

  validates :binding_version, numericality: { only_integer: true, greater_than: 0 },
                              uniqueness: { scope: [:workspace_id, :chatwoot_inbox_id] }
  validates :chatwoot_inbox_id, uniqueness: { scope: :workspace_id, conditions: -> { active } }, if: :active?
  validate :inbox_ownership_matches
  validate :assistant_ownership_matches
  validate :connection_ownership_matches
  validate :active_binding_is_connected

  private

  def inbox_ownership_matches
    return if workspace.blank? || inbox.blank?

    errors.add(:inbox, 'must belong to the Workspace Chatwoot Account') unless inbox.account_id == workspace.chatwoot_account_id
  end

  def assistant_ownership_matches
    return if workspace.blank? || assistant.blank?

    errors.add(:assistant, 'must belong to the selected Workspace') unless assistant.workspace_id == workspace_id
  end

  def connection_ownership_matches
    return if workspace.blank? || assistant.blank? || assistant_agent_bot_connection.blank?
    return if assistant_agent_bot_connection.workspace_id == workspace_id && assistant_agent_bot_connection.assistant_id == assistant_id

    errors.add(:assistant_agent_bot_connection, 'must belong to the selected Workspace and Assistant')
  end

  def active_binding_is_connected
    return unless active? && assistant_agent_bot_connection.present?

    connection = assistant_agent_bot_connection
    agent_bot_inbox = AgentBotInbox.find_by(inbox_id: chatwoot_inbox_id)
    return if connection.active? && agent_bot_inbox&.active? && agent_bot_inbox.agent_bot_id == connection.agent_bot_id

    errors.add(:base, 'active binding requires the connected active AgentBot on the Inbox')
  end
end
