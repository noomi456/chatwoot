class ChatRing::InternalTurnScheduler
  def initialize(message:, native_handling_snapshot:)
    @message = message
    @native_handling_snapshot = native_handling_snapshot
  end

  def call
    return unless ChatRing::AssistantSpike::PUBLIC_AI_RELEASE_READY
    return if ChatRing::AssistantSpike::EXTERNAL_RUNTIME_ENABLED
    return unless customer_widget_message?

    relationship = active_relationship
    return unless relationship

    create_turn(relationship).first
  end

  private

  Relationship = Data.define(:workspace, :binding, :assistant, :assistant_version, :agent_bot)

  attr_reader :message, :native_handling_snapshot

  def customer_widget_message?
    message.incoming? &&
      !message.private? &&
      message.sender_type == 'Contact' &&
      message.conversation.inbox.channel_type == 'Channel::WebWidget'
  end

  def active_relationship
    conversation = message.conversation.reload
    workspace = conversation.account.chat_ring_workspace
    binding = ChatRing::InboxAssistantBinding.active.find_by(
      workspace: workspace,
      chatwoot_inbox_id: conversation.inbox_id
    )
    return if binding.blank?

    connection = binding.assistant_agent_bot_connection
    relationship = build_relationship(workspace, binding, connection)
    return unless relationship_valid?(relationship, connection, conversation)

    relationship
  end

  def build_relationship(workspace, binding, connection)
    Relationship.new(
      workspace: workspace,
      binding: binding,
      assistant: binding.assistant,
      assistant_version: binding.assistant.current_version,
      agent_bot: connection.agent_bot
    )
  end

  def relationship_valid?(relationship, connection, conversation)
    configuration_valid?(relationship, connection) && ownership_valid?(relationship.agent_bot, conversation)
  end

  def configuration_valid?(relationship, connection)
    relationship.workspace.status == 'active' &&
      relationship.binding.active? &&
      relationship.assistant.active? &&
      relationship.assistant_version.present? &&
      connection.active?
  end

  def ownership_valid?(agent_bot, conversation)
    agent_bot.chatring_assistant? &&
      agent_bot.account_id == conversation.account_id &&
      conversation.pending? &&
      conversation.assignee_agent_bot_id == agent_bot.id &&
      AgentBotInbox.active.exists?(inbox_id: conversation.inbox_id, agent_bot_id: agent_bot.id)
  end

  def create_turn(relationship)
    existing = find_turn(relationship.workspace)
    return [existing, false] if existing

    [ChatRing::AiTurn.create!(turn_attributes(relationship)), true]
  rescue ActiveRecord::RecordNotUnique
    [find_turn(relationship.workspace), false]
  end

  def find_turn(workspace)
    ChatRing::AiTurn.find_by(
      workspace: workspace,
      conversation: message.conversation,
      trigger_message: message
    )
  end

  def turn_attributes(relationship)
    reason = native_terminal_reason
    {
      workspace: relationship.workspace,
      conversation: message.conversation,
      trigger_message: message,
      inbox_assistant_binding: relationship.binding,
      binding_version: relationship.binding.binding_version,
      assistant: relationship.assistant,
      assistant_version: relationship.assistant_version,
      expected_agent_bot: relationship.agent_bot,
      runtime_mode: :internal,
      status: reason ? :ineligible : :received,
      decision_type: reason,
      completed_at: reason ? Time.current : nil,
      native_handling_snapshot: native_handling_snapshot,
      deadline_at: Time.current + ChatRing::AiTurn::DEFAULT_DEADLINE
    }
  end

  def native_terminal_reason
    return 'automation_observation_failed' if automation_observation_failed?
    return 'automation_conflict' if automation_conflict?
    return 'native_out_of_office' if message.conversation.inbox.out_of_office?
    return 'native_email_collection' if email_collection_required?
  end

  def automation_conflict?
    ChatRing::AutomationConflictClassifier.new(
      account: message.conversation.account,
      inbox: message.conversation.inbox
    ).conflicting?
  end

  def automation_observation_failed?
    Array(native_handling_snapshot.dig('automation', 'effects')).any? do |effect|
      effect.dig('before', 'observation_error').present? || effect.dig('after', 'observation_error').present?
    end
  end

  def email_collection_required?
    inbox = message.conversation.inbox
    inbox.enable_email_collect? && inbox.web_widget? && message.conversation.contact.email.blank?
  end
end
