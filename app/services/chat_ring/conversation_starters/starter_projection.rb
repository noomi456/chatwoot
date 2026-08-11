class ChatRing::ConversationStarters::StarterProjection
  def self.call(inbox)
    configuration = ChatRing::InboxConversationStarter.find_by(chatwoot_inbox_id: inbox.id)
    return [] unless configuration

    configuration.active_starters
                 .first(ChatRing::InboxConversationStarter::DISPLAY_LIMIT)
                 .map { |starter| starter.slice('label', 'prompt') }
  end
end
