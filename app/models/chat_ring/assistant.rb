class ChatRing::Assistant < ApplicationRecord
  self.table_name = 'chat_ring_assistants'

  enum status: { draft: 0, active: 1, inactive: 2, archived: 3 }

  belongs_to :workspace, class_name: 'ChatRing::Workspace', inverse_of: :assistants
  belongs_to :current_version, class_name: 'ChatRing::AssistantVersion', optional: true
  has_many :versions,
           class_name: 'ChatRing::AssistantVersion',
           inverse_of: :assistant,
           dependent: :destroy
  has_one :agent_bot_connection,
          class_name: 'ChatRing::AssistantAgentBotConnection',
          inverse_of: :assistant,
          dependent: :destroy
  has_many :inbox_bindings,
           class_name: 'ChatRing::InboxAssistantBinding',
           inverse_of: :assistant,
           dependent: :destroy
  has_many :ai_turns,
           class_name: 'ChatRing::AiTurn',
           inverse_of: :assistant,
           dependent: :restrict_with_exception

  validates :name, presence: true, uniqueness: { scope: :workspace_id }
  validate :current_version_belongs_to_assistant
  validate :active_assistant_has_current_version

  private

  def current_version_belongs_to_assistant
    return if current_version.blank? || current_version.assistant_id == id

    errors.add(:current_version, 'must belong to the Assistant')
  end

  def active_assistant_has_current_version
    return unless active? && current_version.blank?

    errors.add(:current_version, 'is required for an active Assistant')
  end
end
