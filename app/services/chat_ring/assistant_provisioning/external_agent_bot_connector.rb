class ChatRing::AssistantProvisioning::ExternalAgentBotConnector
  def initialize(inbox:, agent_bot:)
    @inbox = inbox
    @agent_bot = agent_bot
  end

  def call
    inbox.with_lock do
      ensure_no_chatring_binding!
      if agent_bot.present?
        connection = AgentBotInbox.find_or_initialize_by(inbox: inbox)
        connection.update!(agent_bot: agent_bot)
        connection
      else
        AgentBotInbox.find_by(inbox: inbox)&.destroy!
      end
    end
  end

  private

  attr_reader :inbox, :agent_bot

  def ensure_no_chatring_binding!
    return unless ChatRing::InboxAssistantBinding.active.exists?(chatwoot_inbox_id: inbox.id)

    inbox.errors.add(:base, 'ChatRing Assistant owns this Inbox automation')
    raise ActiveRecord::RecordInvalid, inbox
  end
end
