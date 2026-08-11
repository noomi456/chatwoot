class ChatRing::Brain::FailureFinalizer
  def self.call(turn_id, failure_code)
    new(turn_id, failure_code).call
  end

  def initialize(turn_id, failure_code)
    @turn = ChatRing::AiTurn.find_by(id: turn_id)
    @failure_code = failure_code
  end

  def call
    return if turn.blank?

    ChatRing::OutboundCommitDispatcher.call(turn.id) if prepare_outcome
  end

  private

  attr_reader :turn, :failure_code

  def prepare_outcome
    dispatch_outcome = false
    finalization_reason = nil
    turn.with_lock do
      turn.reload
      turn.fail_running_attempts!(failure_code)
      next unless recoverable_execution_state?

      eligibility = ChatRing::Brain::Eligibility.check(turn, enforce_deadline: false)
      unless eligibility.eligible
        mark_ineligible(eligibility.reason)
        finalization_reason = eligibility.reason
        next
      end

      dispatch_outcome = prepare_fallback
    end
    ChatRing::Playbooks::ExecutionFinalizer.call(turn, finalization_reason) if finalization_reason
    dispatch_outcome
  end

  def recoverable_execution_state?
    turn.status_received? || turn.status_eligible? || turn.status_running? || turn.status_awaiting_tool?
  end

  def mark_ineligible(reason)
    turn.update!(status: :ineligible, decision_type: reason, failure_code: failure_code, completed_at: Time.current)
  end

  def prepare_fallback
    decision = ChatRing::Brain::FallbackPolicy.decision(turn.assistant_version, 'provider_failure')
    return finish_without_customer_effect unless decision.decision_type == 'handoff'

    ChatRing::OutboundCommitPreparer.call(turn, decision.decision_type)
    turn.update!(
      status: :ready_to_commit,
      decision_type: decision.decision_type,
      decision_payload: decision.to_h,
      failure_code: failure_code,
      completed_at: Time.current
    )
    true
  end

  def finish_without_customer_effect
    turn.update!(
      status: :failed,
      decision_type: 'abstain',
      failure_code: failure_code,
      completed_at: Time.current
    )
    false
  end
end
