class ChatRing::Playbooks::DecisionControl
  class Invalid < StandardError; end

  ACTIONS = %w[
    submit_answer answer_side_question submit_answer_and_answer_side_question resume_pending_question
  ].freeze
  MAX_ANSWER_LENGTH = 1000

  attr_reader :action, :answer_value

  def self.from_payload(payload)
    new(payload).tap(&:validate!)
  end

  def initialize(payload)
    attributes = payload.to_h.deep_stringify_keys
    @action = attributes['action'].to_s
    @answer_value = attributes['answer_value'].to_s.strip.presence
    @unknown_keys = attributes.keys - %w[action answer_value]
  end

  def answer?
    %w[submit_answer submit_answer_and_answer_side_question].include?(action)
  end

  def side_question?
    %w[answer_side_question submit_answer_and_answer_side_question].include?(action)
  end

  def resume?
    action == 'resume_pending_question'
  end

  def to_h
    { 'action' => action, 'answer_value' => answer_value }.compact
  end

  def validate!
    validate_shape!
    validate_action!
    validate_answer!
  end

  def validate_shape!
    raise Invalid, 'Playbook control contains unknown fields' if @unknown_keys.present?
  end

  def validate_action!
    raise Invalid, 'Unknown Playbook action' unless ACTIONS.include?(action)
  end

  def validate_answer!
    raise Invalid, 'Playbook answer is required' if answer? && answer_value.blank?
    raise Invalid, 'Side-question-only decisions cannot submit an answer' if !answer? && answer_value.present?
    raise Invalid, 'Playbook answer exceeds the maximum length' if answer_value.to_s.length > MAX_ANSWER_LENGTH
  end
end
