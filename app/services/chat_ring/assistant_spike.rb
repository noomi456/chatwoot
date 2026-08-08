module ChatRing::AssistantSpike
  BOT_CONFIG_KEY = 'chatring_assistant_spike'.freeze
  SOURCE_ID_PREFIX = 'chatring-assistant-spike'.freeze
  # Architecture v2.1 Sections 15 and 21.7 are a hard release gate. This
  # compile-time false cannot be bypassed with a deployment environment flag.
  PUBLIC_AI_RELEASE_READY = false

  module_function

  def enabled?
    return false unless PUBLIC_AI_RELEASE_READY

    ActiveModel::Type::Boolean.new.cast(ENV.fetch('CHATRING_ASSISTANT_SPIKE_ENABLED', 'false'))
  end

  def delay_seconds
    ENV.fetch('CHATRING_ASSISTANT_SPIKE_DELAY_SECONDS', '0').to_i.clamp(0, 10)
  end

  def internal_bot_for(inbox)
    return unless enabled?
    return if inbox.hooks.exists?(app_id: 'dialogflow', status: 'enabled')

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
