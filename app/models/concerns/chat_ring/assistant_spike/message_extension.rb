module ChatRing::AssistantSpike::MessageExtension
  private

  def captain_pending_conversation?
    super || (conversation.pending? && ChatRing::AssistantSpike.internal_bot_for(conversation.inbox).present?)
  end
end
