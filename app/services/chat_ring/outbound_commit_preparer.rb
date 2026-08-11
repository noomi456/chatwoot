require 'digest'

class ChatRing::OutboundCommitPreparer
  EFFECTFUL_DECISIONS = {
    'reply' => :reply,
    'clarification' => :reply,
    'playbook' => :reply,
    'request_appointment' => :tool,
    'handoff' => :handoff
  }.freeze

  def self.call(turn, decision_type)
    outcome_type = EFFECTFUL_DECISIONS[decision_type.to_s]
    return unless outcome_type

    idempotency_key = Digest::SHA256.hexdigest("chatring:#{outcome_type}:#{turn.workspace_id}:#{turn.id}")
    commit = create_or_find(turn, idempotency_key, outcome_type)
    return commit if commit.idempotency_key == idempotency_key && commit.outcome_type == outcome_type.to_s

    commit.errors.add(:base, 'does not match the AI turn decision')
    raise ActiveRecord::RecordInvalid, commit
  end

  def self.create_or_find(turn, idempotency_key, outcome_type)
    ChatRing::OutboundCommit.create!(
      ai_turn: turn,
      idempotency_key: idempotency_key,
      outcome_type: outcome_type
    )
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
    existing = ChatRing::OutboundCommit.find_by(ai_turn: turn)
    raise e unless existing

    existing
  end
  private_class_method :create_or_find
end
