class ChatRing::Playbooks::ExecutionFinalizer
  SUPERSEDING_FAILURES = %w[
    public_response_gate_closed legacy_runtime_mode runtime_mode_changed workspace_inactive
    binding_inactive binding_version_changed assistant_inactive assistant_version_changed
    unsupported_audience_policy unsupported_availability_policy unsupported_channel
    unexpected_agent_bot inbox_connection_inactive automation_conflict conversation_not_pending
  ].freeze

  def self.call(turn, failure_code)
    source_turn = turn
    Account.transaction do
      Account.lock.find(source_turn.conversation.account_id)
      Inbox.lock.find(source_turn.conversation.inbox_id)
      conversation = Conversation.lock.find(source_turn.chatwoot_conversation_id)
      locked_turn = ChatRing::AiTurn.lock.find(source_turn.id)
      execution = ChatRing::InboxPlaybookExecution.lock.find_by(id: locked_turn.inbox_playbook_execution_id)
      apply_locked!(turn: locked_turn, execution: execution, conversation: conversation, failure_code: failure_code)
    end
  rescue ActiveRecord::RecordNotFound
    false
  end

  def self.apply_locked!(turn:, execution:, conversation:, failure_code:, forced_outcome: nil)
    return false unless execution_matches_turn?(execution, turn)

    status, action = forced_outcome || outcome_for(failure_code, conversation)
    return false unless status && action

    apply_execution_locked!(
      execution: execution,
      status: status,
      action: action,
      failure_code: failure_code,
      trigger_message_id: turn.trigger_message_id
    )
  end

  def self.apply_execution_locked!(execution:, status:, action:, failure_code:, trigger_message_id: nil)
    return false unless execution&.status.in?(ChatRing::InboxPlaybookExecution::CONTROLLING_STATUSES)

    execution.update!(
      status: status,
      completed_at: Time.current,
      transition_history: execution.transition_history + [{
        'action' => action,
        'step_id' => execution.current_step_id,
        'trigger_message_id' => trigger_message_id || execution.last_trigger_message_id,
        'failure_code' => failure_code,
        'recorded_at' => Time.current.iso8601(6)
      }.compact]
    )
    true
  end

  def self.execution_matches_turn?(execution, turn)
    execution &&
      execution.lock_version == turn.playbook_execution_lock_version &&
      execution.current_step_id == turn.playbook_step_id &&
      execution.last_trigger_message_id == turn.trigger_message_id
  end

  def self.outcome_for(failure_code, conversation)
    return [:handed_off, 'native_human_takeover'] if native_human_takeover?(failure_code, conversation)
    return [:superseded, 'native_runtime_superseded'] if superseding_failure?(failure_code)

    [nil, nil]
  end

  def self.native_human_takeover?(failure_code, conversation)
    failure_code == 'newer_human_reply' || (failure_code == 'conversation_not_pending' && conversation.assignee_id.present?)
  end

  def self.superseding_failure?(failure_code)
    SUPERSEDING_FAILURES.include?(failure_code) || failure_code.to_s.start_with?('native_')
  end

  private_class_method :execution_matches_turn?, :outcome_for, :native_human_takeover?, :superseding_failure?
end
