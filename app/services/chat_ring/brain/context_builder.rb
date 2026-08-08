class ChatRing::Brain::ContextBuilder
  MAX_HISTORY_MESSAGES = 20
  MAX_HISTORY_CHARACTERS = 16_000
  MAX_MESSAGE_CHARACTERS = 4000

  def initialize(turn)
    @turn = turn
  end

  def build
    {
      'assistant' => assistant_context,
      'conversation' => conversation_context,
      'contact' => contact_context,
      'trigger_message' => message_context(turn.trigger_message)
    }
  end

  private

  attr_reader :turn

  def assistant_context
    version = turn.assistant_version
    {
      'assistant_id' => turn.assistant_id,
      'assistant_version_id' => version.id,
      'identity' => version.identity,
      'goals' => version.goals,
      'instructions' => version.instructions,
      'response_guidelines' => version.response_guidelines,
      'guardrails' => version.guardrails,
      'audience_policy' => version.audience_policy,
      'handoff_policy' => version.handoff_policy,
      'conversation_policy' => version.conversation_policy
    }
  end

  def conversation_context
    {
      'conversation_id' => turn.chatwoot_conversation_id,
      'inbox_id' => turn.conversation.inbox_id,
      'channel_type' => turn.conversation.inbox.channel_type,
      'history' => bounded_history
    }
  end

  def contact_context
    contact = turn.conversation.contact
    return {} if contact.blank?

    {
      'chatwoot_contact_id' => contact.id,
      'name' => contact.name,
      'email' => contact.email,
      'phone_number' => contact.phone_number,
      'identifier' => contact.identifier
    }.compact
  end

  def bounded_history
    messages = turn.conversation.messages
                   .where(message_type: [:incoming, :outgoing], private: false)
                   .where('id < ?', turn.trigger_message_id)
                   .reorder(id: :desc)
                   .limit(MAX_HISTORY_MESSAGES * 2)

    selected = []
    character_count = 0
    messages.each do |message|
      item = message_context(message)
      next if item['content'].blank?
      break if character_count + item['content'].length > MAX_HISTORY_CHARACTERS

      selected.prepend(item)
      character_count += item['content'].length
      break if selected.length >= MAX_HISTORY_MESSAGES
    end
    selected
  end

  def message_context(message)
    {
      'message_id' => message.id,
      'role' => message.incoming? ? 'user' : 'assistant',
      'content' => message.content_for_llm.to_s.scrub.strip.first(MAX_MESSAGE_CHARACTERS),
      'created_at' => message.created_at&.iso8601
    }
  end
end
