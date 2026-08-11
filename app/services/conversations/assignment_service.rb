class Conversations::AssignmentService
  def initialize(conversation:, assignee_id:, assignee_type: nil)
    @conversation = conversation
    @assignee_id = assignee_id
    @assignee_type = assignee_type
  end

  def perform
    agent_bot_assignment? ? assign_agent_bot : assign_agent
  end

  private

  attr_reader :conversation, :assignee_id, :assignee_type

  def assign_agent
    with_assignment_lock do
      managed_assistant_unassignment = conversation.assignee_agent_bot&.chatring_assistant?
      prepare_for_human_takeover!
      conversation.assignee = assignee
      conversation.assignee_agent_bot = nil
      conversation.save!
      finalize_managed_playbook_unassignment! if managed_assistant_unassignment
    end
    assignee
  end

  def prepare_for_human_takeover!
    return unless assignee.present? && conversation.assignee_agent_bot_id.present? && conversation.pending?

    conversation.status = :open
    conversation.waiting_since = Time.current if conversation.waiting_since.blank?
  end

  def assign_agent_bot
    return unless agent_bot

    with_assignment_lock do
      validate_managed_agent_bot_assignment!
      conversation.assignee = nil
      conversation.assignee_agent_bot = agent_bot
      conversation.status = :pending
      conversation.save!
    end
    agent_bot
  end

  def assignee
    @assignee ||= conversation.account.users.find_by(id: assignee_id)
  end

  def agent_bot
    @agent_bot ||= AgentBot.accessible_to(conversation.account).find_by(id: assignee_id)
  end

  def agent_bot_assignment?
    assignee_type.to_s == 'AgentBot'
  end

  def with_assignment_lock(&)
    authoritative_conversation = Conversation.find(conversation.id)
    return conversation.with_lock(&) unless managed_chat_ring_assignment?(authoritative_conversation)

    Inbox.transaction do
      Inbox.lock.find(authoritative_conversation.inbox_id)
      @conversation = Conversation.lock.find(authoritative_conversation.id)
      yield
    end
  end

  def managed_chat_ring_assignment?(authoritative_conversation)
    return false unless authoritative_conversation.inbox.web_widget?
    return true if agent_bot_assignment? && agent_bot&.chatring_assistant?

    authoritative_conversation.assignee_agent_bot&.chatring_assistant?
  end

  def validate_managed_agent_bot_assignment!
    return unless agent_bot.chatring_assistant?
    return if managed_agent_bot_assignment_valid?

    conversation.errors.add(:assignee_agent_bot, 'must be the active managed Assistant connected to this Inbox')
    raise ActiveRecord::RecordInvalid, conversation
  end

  def managed_agent_bot_assignment_valid?
    binding = active_managed_binding
    connection = binding&.assistant_agent_bot_connection
    native_connection = AgentBotInbox.active.find_by(inbox_id: conversation.inbox_id)

    connection&.active? && connection.agent_bot_id == agent_bot.id && native_connection&.agent_bot_id == agent_bot.id
  end

  def active_managed_binding
    workspace = conversation.account.chat_ring_workspace
    workspace&.inbox_assistant_bindings&.active&.find_by(chatwoot_inbox_id: conversation.inbox_id)
  end

  def finalize_managed_playbook_unassignment!
    execution = ChatRing::InboxPlaybookExecution.controlling.lock.find_by(chatwoot_conversation_id: conversation.id)
    human_takeover = assignee.present?
    ChatRing::Playbooks::ExecutionFinalizer.apply_execution_locked!(
      execution: execution,
      status: human_takeover ? :handed_off : :superseded,
      action: human_takeover ? 'native_human_takeover' : 'native_bot_unassigned',
      failure_code: human_takeover ? 'human_assigned' : 'agent_bot_unassigned'
    )
  end
end
