class ChatRing::AssistantProvisioning::AssistantArchiver
  def initialize(assistant:)
    @assistant = assistant
  end

  def call
    handed_off_conversations = []
    assistant.workspace.chatwoot_account.with_lock do
      scope = transition_binding_scope
      Inbox.where(id: scope.pluck(:chatwoot_inbox_id)).order(:id).lock.load
      bindings = scope.lock.to_a

      bindings.each do |binding|
        binding.lock!
        handed_off_conversations.concat(drain_binding!(binding))
        disconnect_native_agent_bot!(binding)
        binding.inactive!
      end

      assistant.agent_bot_connection&.inactive!
      assistant.archived!
    end
    handed_off_conversations.each(&:dispatch_bot_handoff_event)
    assistant
  end

  private

  attr_reader :assistant

  def transition_binding_scope
    assistant.inbox_bindings.where(status: %i[active draining]).order(:chatwoot_inbox_id)
  end

  def drain_binding!(binding)
    ChatRing::AssistantProvisioning::InboxBindingDrainer.new(
      binding: binding,
      failure_code: 'assistant_archived'
    ).call_with_lock!
  end

  def disconnect_native_agent_bot!(binding)
    AgentBotInbox.find_by(
      inbox_id: binding.chatwoot_inbox_id,
      agent_bot_id: binding.assistant_agent_bot_connection.agent_bot_id
    )&.destroy!
  end
end
