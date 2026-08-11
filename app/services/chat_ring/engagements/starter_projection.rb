class ChatRing::Engagements::StarterProjection
  def self.call(inbox)
    engagement = ChatRing::InboxEngagement.find_by(chatwoot_inbox_id: inbox.id)
    return [] unless engagement

    engagement.active_starters.map { |starter| starter.slice('label', 'prompt') }
  end
end
