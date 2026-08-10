class ChatRing::ConversationWriteBoundary
  def initialize(conversation:)
    @conversation = conversation
  end

  def call(&)
    return perform_native_write(&) unless conversation.inbox.web_widget?

    ActiveRecord::Base.transaction do
      Inbox.lock.find(conversation.inbox_id)
      @locked_conversation = Conversation.lock.find(conversation.id) if managed_bindings.exists?

      message = perform_native_write(&)
      complete_native_human_takeover(message) if @locked_conversation && managed_bindings.exists?
      message
    ensure
      @locked_conversation = nil
    end
  end

  private

  attr_reader :conversation

  def perform_native_write
    yield
  end

  def managed_bindings
    workspace = ChatRing::Workspace.find_by(chatwoot_account_id: authoritative_conversation.account_id)
    return ChatRing::InboxAssistantBinding.none unless workspace

    ChatRing::InboxAssistantBinding.where(
      workspace_id: workspace.id,
      chatwoot_inbox_id: authoritative_conversation.inbox_id,
      status: %i[active draining]
    )
  end

  def complete_native_human_takeover(message)
    return unless message.public_human_reply? && message.sender.is_a?(User)

    owner_binding = managed_bindings.joins(:assistant_agent_bot_connection).find_by(
      chat_ring_assistant_agent_bot_connections: { agent_bot_id: authoritative_conversation.assignee_agent_bot_id }
    )
    return unless owner_binding

    Conversations::AssignmentService.new(
      conversation: authoritative_conversation,
      assignee_id: message.sender_id
    ).perform
    message.association(:conversation).reset
  end

  def authoritative_conversation
    @locked_conversation || conversation
  end
end
