class ChatRing::Brain::FailureFinalizer
  def self.call(turn_id, failure_code)
    turn = ChatRing::AiTurn.find_by(id: turn_id)
    return if turn.blank?

    turn.with_lock do
      turn.reload
      next if turn.status_ready_to_commit? || turn.status_committed? || turn.status_ineligible? || turn.status_superseded?

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
end
