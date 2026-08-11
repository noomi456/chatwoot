class ChatRing::AssistantProvisioning::InboxBindingDrainer
  def initialize(binding:, failure_code:)
    @binding = binding
    @failure_code = failure_code
  end

  def call_with_lock!
    binding.draining! unless binding.draining?
    cancel_nonterminal_turns!
    handed_off_conversations = handoff_pending_conversations!
    verify_no_owned_conversations!
    handed_off_conversations
  end

  private

  attr_reader :binding, :failure_code

  def cancel_nonterminal_turns!
    binding.ai_turns.nonterminal.lock.order(:id).each do |turn|
      committed_outcome = turn.outbound_commit
      if committed_outcome&.status_committed?
        reconcile_committed_turn!(turn, committed_outcome)
      else
        cancel_turn!(turn)
      end
    end
  end

  def reconcile_committed_turn!(turn, outcome)
    turn.tool_execution&.mark_committed!(timestamp: outcome.committed_at || Time.current) if outcome.outcome_type_tool?
    turn.update!(status: outcome.outcome_type_handoff? ? :handed_off : :committed, failure_code: nil)
  end

  def cancel_turn!(turn)
    turn.tool_execution&.mark_rejected!(failure_code)
    turn.update!(status: :cancelled, failure_code: failure_code, completed_at: Time.current)
  end

  def handoff_pending_conversations!
    owned_pending_conversations.map do |conversation|
      conversation.bot_handoff!(dispatch_event: false)
      conversation
    end
  end

  def owned_pending_conversations
    Conversation.where(
      inbox_id: binding.chatwoot_inbox_id,
      assignee_agent_bot_id: binding.assistant_agent_bot_connection.agent_bot_id,
      status: :pending
    ).order(:id).lock
  end

  def verify_no_owned_conversations!
    return unless Conversation.exists?(
      inbox_id: binding.chatwoot_inbox_id,
      assignee_agent_bot_id: binding.assistant_agent_bot_connection.agent_bot_id
    )

    raise ActiveRecord::RecordNotSaved, 'managed AgentBot still owns Conversations after native handoff'
  end
end
