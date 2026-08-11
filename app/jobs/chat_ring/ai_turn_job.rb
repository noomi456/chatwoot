class ChatRing::AiTurnJob < ApplicationJob
  queue_as :high

  retry_on ChatRing::Brain::Runner::RetryableError,
           wait: :polynomially_longer,
           attempts: ChatRing::AiTurn::MAX_PROVIDER_ATTEMPTS do |job, error|
    ChatRing::Brain::FailureFinalizer.call(job.arguments.first, error.code)
  end
  def perform(turn_id)
    turn = ChatRing::AiTurn.find_by(id: turn_id)
    return unless turn
    return cancel_gate_closed_turn(turn) unless ChatRing::AssistantSpike::PUBLIC_AI_RELEASE_READY

    ChatRing::Brain::Runner.new(turn).call
    ChatRing::OutboundCommitDispatcher.call(turn.id)
  end

  private

  def cancel_gate_closed_turn(turn)
    turn.with_lock do
      turn.reload
      turn.fail_running_attempts!('public_response_gate_closed')
      next unless ChatRing::AiTurn::NONTERMINAL_STATUSES.include?(turn.status)

      committed_outcome = turn.outbound_commit
      next if reconcile_committed_outcome(turn, committed_outcome)

      reject_pending_outcome(committed_outcome)

      turn.update!(
        status: :cancelled,
        failure_code: 'public_response_gate_closed',
        completed_at: Time.current
      )
    end
  end

  def reconcile_committed_outcome(turn, outcome)
    return false unless outcome&.status_committed?

    reconcile_tool_execution(turn, outcome)
    turn.update!(
      status: outcome.outcome_type_handoff? ? :handed_off : :committed,
      failure_code: nil,
      completed_at: turn.completed_at || outcome.committed_at || Time.current
    )
    true
  end

  def reconcile_tool_execution(turn, outcome)
    return unless outcome.outcome_type_tool?

    turn.tool_execution&.mark_committed!(timestamp: outcome.committed_at || Time.current)
  end

  def reject_pending_outcome(outcome)
    return unless outcome&.status_pending?

    outcome.update!(status: :rejected, failure_code: 'public_response_gate_closed', attempted_at: Time.current)
    outcome.tool_execution&.mark_rejected!('public_response_gate_closed') if outcome.outcome_type_tool?
  end
end
