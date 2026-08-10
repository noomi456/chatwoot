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
    turn.with_lock do
      turn.reload
      next if terminal?

      eligibility = ChatRing::Brain::Eligibility.check(turn)
      unless eligibility.eligible
        mark_ineligible(eligibility.reason)
        next
      end

      prepare_fallback
      dispatch_outcome = true
    end
    dispatch_outcome
  end

  def terminal?
    turn.status_ready_to_commit? || turn.status_committed? || turn.status_ineligible? || turn.status_superseded?
  end

  def mark_ineligible(reason)
    turn.update!(status: :ineligible, decision_type: reason, failure_code: failure_code, completed_at: Time.current)
  end

  def prepare_fallback
    decision = ChatRing::Brain::FallbackPolicy.decision(turn.assistant_version, 'provider_failure')
    turn.update!(
      status: :ready_to_commit,
      decision_type: decision.decision_type,
      decision_payload: decision.to_h,
      failure_code: failure_code,
      completed_at: Time.current
    )
  end
end
