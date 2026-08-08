class ChatRing::Brain::FallbackPolicy
  def self.decision(assistant_version, reason_code)
    handoff = assistant_version.handoff_policy.to_h["on_#{reason_code}"] == 'handoff'
    ChatRing::Brain::Decision.new(
      {
        decision_type: handoff ? 'handoff' : 'abstain',
        response_text: '',
        reason_code: reason_code,
        evidence_ids: []
      },
      allowed_evidence_ids: [],
      evidence_status: 'insufficient_evidence'
    )
  end
end
