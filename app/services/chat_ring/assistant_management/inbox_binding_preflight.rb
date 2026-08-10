class ChatRing::AssistantManagement::InboxBindingPreflight
  Result = Data.define(:ready, :conflicts, :current_binding, :impact)

  def initialize(assistant:, inbox:)
    @assistant = assistant
    @inbox = inbox
  end

  def call
    conflicts = prerequisite_conflicts
    if connection_available?
      conflicts.concat(detected_conflicts.map do |item|
        {
          kind: item.kind.to_s,
          record_id: item.record_id,
          blocking: !replaceable_agent_bot_conflict?(item)
        }
      end)
    end
    conflicts << conflict(:managed_agent_bot_owned_non_pending_conversations) if impact[:non_pending_conversations].positive?
    Result.new(
      ready: conflicts.none? { |item| item[:blocking] },
      conflicts: conflicts,
      current_binding: current_binding,
      impact: impact
    )
  end

  private

  attr_reader :assistant, :inbox

  def prerequisite_conflicts
    conflicts = []
    conflicts << conflict(:unsupported_channel) unless inbox.web_widget?
    conflicts << conflict(:archived_assistant) if assistant.archived?
    conflicts << conflict(:workspace_inactive) unless assistant.workspace.status == 'active'
    conflicts << conflict(:unpublished_assistant) if assistant.current_version.blank?
    conflicts << conflict(:managed_agent_bot_unhealthy) unless connection_available?
    conflicts
  end

  def connection_available?
    connection = assistant.agent_bot_connection
    connection&.active? && connection.valid?
  end

  def detected_conflicts
    ChatRing::AssistantProvisioning::InboxConflictDetector.new(
      inbox: inbox,
      expected_agent_bot_id: assistant.agent_bot_connection.agent_bot_id
    ).call
  end

  def impact
    @impact ||= begin
      owned_count = switching_binding? ? owned_conversations.count : 0
      pending_count = switching_binding? ? owned_conversations.where(status: :pending).count : 0
      {
        pending_conversations: pending_count,
        non_pending_conversations: owned_count - pending_count,
        nonterminal_turns: switching_binding? ? current_binding.ai_turns.nonterminal.count : 0
      }
    end
  end

  def switching_binding?
    current_binding.present? && current_binding.assistant_id != assistant.id
  end

  def owned_conversations
    Conversation.where(
      inbox_id: inbox.id,
      assignee_agent_bot_id: current_binding.assistant_agent_bot_connection.agent_bot_id
    )
  end

  def current_binding
    @current_binding ||= ChatRing::InboxAssistantBinding.active.find_by(
      workspace: assistant.workspace,
      chatwoot_inbox_id: inbox.id
    )
  end

  def replaceable_agent_bot_conflict?(item)
    return false unless item.kind == :agent_bot && current_binding.present?

    AgentBotInbox.find_by(id: item.record_id)&.agent_bot_id == current_binding.assistant_agent_bot_connection.agent_bot_id
  end

  def conflict(kind)
    { kind: kind.to_s, record_id: nil, blocking: true }
  end
end
