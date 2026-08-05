module ChatRing::AssistantSpike
  BOT_CONFIG_KEY = 'chatring_assistant_spike'.freeze
  SOURCE_ID_PREFIX = 'chatring-assistant-spike'.freeze

  module_function

  def enabled?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch('CHATRING_ASSISTANT_SPIKE_ENABLED', 'false'))
  end

  def delay_seconds
    ENV.fetch('CHATRING_ASSISTANT_SPIKE_DELAY_SECONDS', '0').to_i.clamp(0, 10)
  end

  def internal_bot_for(inbox)
    return unless enabled?
    return if inbox.hooks.where(app_id: 'dialogflow', status: 'enabled').exists?

    bot_inbox = inbox.agent_bot_inbox
    return unless bot_inbox&.active?

    bot = bot_inbox.agent_bot
    return if bot.outgoing_url.present?
    return unless bot.bot_config.to_h[BOT_CONFIG_KEY] == true

    bot
  end

  def eligible_message?(message)
    message.incoming? &&
      !message.private? &&
      message.content.present? &&
      message.conversation.pending? &&
      internal_bot_for(message.inbox).present?
  end

  def response_source_id(message)
    "#{SOURCE_ID_PREFIX}:#{message.account_id}:#{message.id}"
  end
end
