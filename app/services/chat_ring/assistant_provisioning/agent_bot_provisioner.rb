class ChatRing::AssistantProvisioning::AgentBotProvisioner
  BOT_CONFIG_KEY = 'chatring_assistant_id'.freeze

  def initialize(assistant:)
    @assistant = assistant
  end

  def call
    assistant.with_lock do
      validate_assistant!
      if assistant.agent_bot_connection.present?
        verify_existing_connection!
      else
        AgentBot.transaction do
          agent_bot = create_agent_bot!
          create_connection!(agent_bot)
        end
      end
    end
  end

  private

  attr_reader :assistant

  def validate_assistant!
    return if assistant.current_version.present? && !assistant.archived?

    assistant.errors.add(:base, 'publish an Assistant version before provisioning its AgentBot')
    raise ActiveRecord::RecordInvalid, assistant
  end

  def create_agent_bot!
    assistant.workspace.chatwoot_account.agent_bots.create!(
      name: assistant.name,
      description: "Managed identity for ChatRing Assistant #{assistant.id}",
      outgoing_url: nil,
      bot_type: :chatring_assistant,
      bot_config: { BOT_CONFIG_KEY => assistant.id }
    )
  end

  def create_connection!(agent_bot)
    connection = assistant.create_agent_bot_connection!(
      workspace: assistant.workspace,
      agent_bot: agent_bot,
      status: :active,
      access_token_secret_ref: "access_tokens/#{agent_bot.access_token.id}",
      webhook_secret_ref: "agent_bots/#{agent_bot.id}/secret",
      last_verified_at: Time.current
    )
    agent_bot.update!(outgoing_url: connection.webhook_url)
    connection
  end

  def verify_existing_connection!
    connection = assistant.agent_bot_connection
    connection.validate!
    update_webhook_url!(connection)
    return connection if connection.active?

    connection.update!(status: :active, last_verified_at: Time.current)
    connection
  end

  def update_webhook_url!(connection)
    return if connection.agent_bot.outgoing_url == connection.webhook_url

    connection.agent_bot.update!(outgoing_url: connection.webhook_url)
  end
end
