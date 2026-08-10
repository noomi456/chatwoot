module ChatRing::AiTurnManagementSerialization
  private

  def serialize_turn(turn, include_details: false)
    result = turn_summary(turn)
    return result unless include_details

    result.merge(
      attempts: turn.attempts.order(:attempt_number).map { |attempt| serialize_attempt(attempt) },
      outbound_commit: serialize_outbound_commit(turn.outbound_commit)
    )
  end

  def turn_summary(turn)
    {
      id: turn.id,
      assistant_id: turn.assistant_id,
      assistant_version_id: turn.assistant_version_id,
      inbox_id: turn.conversation.inbox_id,
      conversation_id: turn.chatwoot_conversation_id,
      trigger_message_id: turn.trigger_message_id,
      status: turn.status,
      decision_type: turn.decision_type,
      failure_code: turn.failure_code,
      runtime_mode: turn.runtime_mode,
      attempt_count: turn.attempts.size,
      evidence_count: turn.evidence.size,
      started_at: turn.started_at,
      completed_at: turn.completed_at,
      created_at: turn.created_at,
      updated_at: turn.updated_at
    }
  end

  def serialize_attempt(attempt)
    {
      id: attempt.id,
      attempt_number: attempt.attempt_number,
      provider: attempt.provider,
      model: attempt.model,
      status: attempt.status,
      input_tokens: attempt.input_tokens,
      output_tokens: attempt.output_tokens,
      failure_code: attempt.failure_code,
      started_at: attempt.started_at,
      completed_at: attempt.completed_at
    }
  end

  def serialize_outbound_commit(commit)
    return if commit.blank?

    {
      id: commit.id,
      outcome_type: commit.outcome_type,
      status: commit.status,
      message_id: commit.chatwoot_message_id,
      failure_code: commit.failure_code,
      created_at: commit.created_at,
      updated_at: commit.updated_at
    }
  end
end
