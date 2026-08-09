class ChatRing::AssistantProvisioning::InboxBindingDeactivator
  def initialize(binding:)
    @binding = binding
  end

  def call
    handed_off_conversations = []
    result = binding.workspace.chatwoot_account.with_lock do
      binding.inbox.with_lock do
        binding.lock!
        next binding if binding.inactive?

        handed_off_conversations.concat(
          ChatRing::AssistantProvisioning::InboxBindingDrainer.new(
            binding: binding,
            failure_code: 'binding_disabled'
          ).call_with_lock!
        )
        disconnect_native_agent_bot!
        binding.inactive!
        binding
      end
    end
    handed_off_conversations.each(&:dispatch_bot_handoff_event)
    result
  end

  private

  attr_reader :binding

  def disconnect_native_agent_bot!
    AgentBotInbox.find_by(
      inbox_id: binding.chatwoot_inbox_id,
      agent_bot_id: binding.assistant_agent_bot_connection.agent_bot_id
    )&.destroy!
  end
end
