class ChatRing::AssistantProvisioning::InboxBindingDrainer
  def initialize(binding:, failure_code:)
    @binding = binding
    @failure_code = failure_code
  end

  def call_with_lock!
    binding.draining! unless binding.draining?
    handed_off_conversations = drain_conversations!
    verify_no_owned_conversations!
    handed_off_conversations
  end

  private

  attr_reader :binding, :failure_code

  def drain_conversations!
    conversation_ids.filter_map do |conversation_id|
      drain_conversation!(Conversation.lock.find(conversation_id))
    end
  end

  def conversation_ids
    turn_ids = binding.ai_turns.nonterminal.distinct.pluck(:chatwoot_conversation_id)
    execution_scope = ChatRing::InboxPlaybookExecution.controlling
    execution_ids = execution_scope.joins(:conversation)
                                   .where(conversations: { inbox_id: binding.chatwoot_inbox_id })
                                   .distinct
                                   .pluck(:chatwoot_conversation_id)
    (turn_ids + execution_ids + owned_pending_conversation_ids).uniq.sort
  end

  def drain_conversation!(conversation)
    cancel_nonterminal_turns!(conversation)
    execution = lock_controlling_execution(conversation)
    native_handoff = owned_pending_conversation?(conversation)
    conversation.bot_handoff!(dispatch_event: false) if native_handoff
    finalize_execution!(execution, conversation, native_handoff)
    conversation if native_handoff
  end

  def cancel_nonterminal_turns!(conversation)
    binding.ai_turns.nonterminal.where(chatwoot_conversation_id: conversation.id).lock.order(:id).each do |turn|
      execution = lock_turn_execution(turn)
      committed_outcome = turn.outbound_commit
      if committed_outcome&.status_committed?
        reconcile_committed_turn!(turn, committed_outcome)
      else
        cancel_turn!(turn, execution, conversation)
      end
    end
  end

  def reconcile_committed_turn!(turn, outcome)
    if outcome.outcome_type_tool? || outcome.outcome_type_human_route?
      turn.tool_execution&.mark_committed!(timestamp: outcome.committed_at || Time.current)
    end
    turn.update!(status: outcome.native_handoff_committed? ? :handed_off : :committed, failure_code: nil)
  end

  def cancel_turn!(turn, execution, conversation)
    turn.tool_execution&.mark_rejected!(failure_code)
    ChatRing::Playbooks::ExecutionFinalizer.apply_locked!(
      turn: turn,
      execution: execution,
      conversation: conversation,
      failure_code: failure_code
    )
    turn.update!(status: :cancelled, failure_code: failure_code, completed_at: Time.current)
  end

  def lock_turn_execution(turn)
    return unless turn.inbox_playbook_execution_id

    ChatRing::InboxPlaybookExecution.lock.find(turn.inbox_playbook_execution_id)
  end

  def lock_controlling_execution(conversation)
    ChatRing::InboxPlaybookExecution.controlling.lock.find_by(chatwoot_conversation_id: conversation.id)
  end

  def finalize_execution!(execution, conversation, native_handoff)
    return unless execution

    handed_off = native_handoff || conversation.assignee_id.present?
    ChatRing::Playbooks::ExecutionFinalizer.apply_execution_locked!(
      execution: execution,
      status: handed_off ? :handed_off : :superseded,
      action: handed_off ? 'native_binding_handoff' : 'native_binding_superseded',
      failure_code: failure_code
    )
  end

  def owned_pending_conversation_ids
    Conversation.where(
      inbox_id: binding.chatwoot_inbox_id,
      assignee_agent_bot_id: binding.assistant_agent_bot_connection.agent_bot_id,
      status: :pending
    ).order(:id).pluck(:id)
  end

  def owned_pending_conversation?(conversation)
    conversation.pending? &&
      conversation.assignee_agent_bot_id == binding.assistant_agent_bot_connection.agent_bot_id
  end

  def verify_no_owned_conversations!
    return unless Conversation.exists?(
      inbox_id: binding.chatwoot_inbox_id,
      assignee_agent_bot_id: binding.assistant_agent_bot_connection.agent_bot_id
    )

    raise ActiveRecord::RecordNotSaved, 'managed AgentBot still owns Conversations after native handoff'
  end
end
