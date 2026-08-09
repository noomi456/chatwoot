class ChatRing::InternalTurnScheduler
  TURN_DEADLINE = 2.minutes

  def initialize(message:, template_ids_before:)
    @message = message
    @template_ids_before = Array(template_ids_before).map { |id| Integer(id) }
  end

  def call
    return if ChatRing::AssistantSpike::EXTERNAL_RUNTIME_ENABLED
    return unless customer_widget_message?

    relationship = active_relationship
    return unless relationship

    turn, created = create_turn(relationship)
    enqueue_turn(turn) if created && turn.status_received?
    turn
  end

  private

  Relationship = Data.define(:workspace, :binding, :assistant, :assistant_version, :agent_bot)

  attr_reader :message, :template_ids_before

  def customer_widget_message?
    message.incoming? &&
      !message.private? &&
      message.sender_type == 'Contact' &&
      message.inbox.channel_type == 'Channel::WebWidget'
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
      status: reason ? :ineligible : :received,
      decision_type: reason,
      completed_at: reason ? Time.current : nil,
      native_handling_snapshot: native_handling_snapshot,
      deadline_at: Time.current + TURN_DEADLINE
    }
  end

  def native_terminal_reason
    return 'native_out_of_office' if message.inbox.out_of_office?
    return 'native_email_collection' if email_collection_required?
  end

  def native_handling_snapshot
    templates = message.conversation.messages.template.reorder(:id).to_a
    current_ids = templates.map(&:id)
    delta = templates.reject { |template| template_ids_before.include?(template.id) }
    {
      trigger_message_id: message.id,
      template_ids_before: template_ids_before,
      template_ids_after: current_ids,
      template_delta_ids: current_ids - template_ids_before,
      greeting_message_ids: greeting_message_ids(delta),
      email_input_message_ids: templates.select(&:input_email?).map(&:id),
      out_of_office_message_ids: out_of_office_message_ids(delta),
      inbox_out_of_office: message.inbox.out_of_office?,
      email_collection_required: email_collection_required?
    }
  end

  def greeting_message_ids(templates)
    matching_template_ids(templates, message.inbox.greeting_message)
  end

  def out_of_office_message_ids(templates)
    matching_template_ids(templates, message.inbox.out_of_office_message)
  end

  def matching_template_ids(templates, content)
    return [] if content.blank?

    templates.select { |template| template.content == content }.map(&:id)
  end

  def email_collection_required?
    inbox = message.inbox
    inbox.enable_email_collect? && inbox.web_widget? && message.conversation.contact.email.blank?
  end

  def enqueue_turn(turn)
    job = ChatRing::AiTurnJob.perform_later(turn.id)
    return if job&.successfully_enqueued?

    turn.update!(failure_code: 'turn_enqueue_failed')
  end
end
