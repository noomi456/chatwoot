class ChatRing::Playbooks::CommitEffect
  class Invalid < StandardError; end

  def self.applicable?(turn)
    turn.decision_payload.to_h.dig('playbook_control', 'action').present?
  end

  def initialize(turn:, execution:)
    @turn = turn
    @execution = execution
  end

  def failure_code
    plan
    nil
  rescue ChatRing::Playbooks::CommitPlan::Invalid => e
    e.code
  end

  def message_attributes
    return {} if failure_code

    {
      content: plan.content,
      content_type: plan.content_type || 'text',
      content_attributes: plan.content_attributes || {}
    }
  end

  def apply!(message)
    raise Invalid, failure_code if failure_code

    plan.apply!(message)
  end

  private

  attr_reader :turn, :execution

  def plan
    @plan ||= ChatRing::Playbooks::CommitPlan.build(turn: turn, execution: execution)
  end
end
