class ChatRing::Brain::Eligibility
  Result = Data.define(:eligible, :reason)

  def self.check(turn)
    new(turn).check
  end

  def initialize(turn)
    @turn = turn
  end

  def check
    reason = configuration_failure || ownership_failure || freshness_failure
    Result.new(eligible: reason.nil?, reason: reason)
  end

  private

  attr_reader :turn

  def configuration_failure
    return 'workspace_inactive' unless turn.workspace.status == 'active'
    return 'binding_inactive' unless turn.inbox_assistant_binding.active?
    return 'binding_version_changed' unless turn.inbox_assistant_binding.binding_version == turn.binding_version
    return 'assistant_inactive' unless turn.assistant.active?
    return 'assistant_version_changed' unless turn.assistant.current_version_id == turn.assistant_version_id
  end

  def ownership_failure
    conversation = turn.conversation
    return 'unsupported_channel' unless conversation.inbox.channel_type == 'Channel::WebWidget'
    return 'conversation_not_pending' unless conversation.pending?
    return 'unexpected_agent_bot' unless conversation.assignee_agent_bot_id == turn.expected_agent_bot_id
    return 'inbox_connection_inactive' unless AgentBotInbox.active.exists?(
      inbox_id: conversation.inbox_id,
      agent_bot_id: turn.expected_agent_bot_id
    )
  end

  def freshness_failure
    messages = turn.conversation.messages
    newest = messages
             .where(message_type: :incoming, private: false, sender_type: 'Contact')
             .reorder(id: :desc)
             .first
    return 'newer_customer_message' unless newest&.id == turn.trigger_message_id

    newer_human_reply = messages.where('id > ?', turn.trigger_message_id).any?(&:public_human_reply?)
    'newer_human_reply' if newer_human_reply
  end
end
