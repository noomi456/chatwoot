class ChatRing::AssistantProvisioning::InboxBindingActivator
  def initialize(assistant:, inbox:)
    @assistant = assistant
    @inbox = inbox
  end

  def call
    connection = active_connection!
    handed_off_conversations = []
    binding = assistant.workspace.chatwoot_account.with_lock do
      inbox.with_lock do
        validate_inbox!
        activate_binding!(connection, handed_off_conversations)
      end
    end
    handed_off_conversations.each(&:dispatch_bot_handoff_event)
    binding
  end

  private

  attr_reader :assistant, :inbox

  def active_connection!
    connection = assistant.agent_bot_connection
    valid_assistant = assistant.current_version.present? && !assistant.archived?
    return connection if valid_assistant && connection&.active? && connection.valid?

    assistant.errors.add(:base, 'Assistant requires a published version and active AgentBot connection')
    raise ActiveRecord::RecordInvalid, assistant
  end

  def activate_binding!(connection, handed_off_conversations)
    current = active_binding
    return activate_existing!(current, connection) if current_matches?(current, connection)

    conflicts = ChatRing::AssistantProvisioning::InboxConflictDetector.new(
      inbox: inbox,
      expected_agent_bot_id: connection.agent_bot_id
    ).call.reject { |conflict| replaceable_agent_bot_conflict?(conflict, current) }
    raise ChatRing::AssistantProvisioning::AgentBotConnector::ConflictError, conflicts if conflicts.any?

    handed_off_conversations.concat(drain_binding!(current)) if current
    connect_agent_bot!(connection, current)
    verify_agent_bot_connection!(connection)
    binding = create_binding!(connection)
    assistant.update!(status: :active)
    binding
  end

  def current_matches?(current, connection)
    current&.assistant_id == assistant.id && current.assistant_agent_bot_connection_id == connection.id
  end

  def validate_inbox!
    return if inbox.web_widget?

    inbox.errors.add(:base, 'ChatRing Assistants currently support Web Widget Inboxes only')
    raise ActiveRecord::RecordInvalid, inbox
  end

  def drain_binding!(binding)
    ChatRing::AssistantProvisioning::InboxBindingDrainer.new(
      binding: binding,
      failure_code: 'binding_rebound'
    ).call_with_lock!
  end

  def activate_existing!(current, connection)
    connect_agent_bot!(connection, current)
    assistant.update!(status: :active)
    current
  end

  def replaceable_agent_bot_conflict?(conflict, current)
    return false unless conflict.kind == :agent_bot && current.present?

    AgentBotInbox.find_by(id: conflict.record_id)&.agent_bot_id == current.assistant_agent_bot_connection.agent_bot_id
  end

  def connect_agent_bot!(connection, current)
    ChatRing::AssistantProvisioning::AgentBotConnector.new(
      workspace: assistant.workspace,
      inbox: inbox,
      agent_bot: connection.agent_bot,
      replace_agent_bot_id: current&.assistant_agent_bot_connection&.agent_bot_id
    ).call_with_lock!
  end

  def verify_agent_bot_connection!(connection)
    linked_bot = AgentBotInbox.find_by(inbox_id: inbox.id)
    return if linked_bot&.active? && linked_bot.agent_bot_id == connection.agent_bot_id

    raise ActiveRecord::RecordNotSaved, 'Chatwoot AgentBot connection changed during Assistant binding'
  end

  def active_binding
    ChatRing::InboxAssistantBinding.active.find_by(workspace: assistant.workspace, chatwoot_inbox_id: inbox.id)
  end

  def create_binding!(connection)
    ChatRing::InboxAssistantBinding.create!(
      workspace: assistant.workspace,
      inbox: inbox,
      assistant: assistant,
      assistant_agent_bot_connection: connection,
      status: :active,
      binding_version: ChatRing::InboxAssistantBinding.where(
        workspace: assistant.workspace,
        chatwoot_inbox_id: inbox.id
      ).maximum(:binding_version).to_i + 1
    )
  end
end
