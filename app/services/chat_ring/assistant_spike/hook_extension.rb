module ChatRing::AssistantSpike::HookExtension
  def perform
    super
    return unless ChatRing::AssistantSpike.eligible_message?(message)

    ChatRing::AssistantSpike::ResponseJob
      .set(wait: ChatRing::AssistantSpike.delay_seconds.seconds)
      .perform_later(message.id)
  end
end
