class ChatRing::Brain::Decision
  class Invalid < StandardError; end

  TYPES = %w[reply clarification playbook request_appointment handoff abstain].freeze
  MAX_RESPONSE_LENGTH = 4000
  MAX_PLAYBOOK_RESPONSE_LENGTH = 900

  attr_reader :decision_type, :response_text, :reason_code, :evidence_ids, :tool_request, :playbook_control

  def self.from_payload(payload, allowed_evidence_ids:, evidence_status:, playbook_context: nil)
    new(
      payload,
      allowed_evidence_ids: allowed_evidence_ids,
      evidence_status: evidence_status,
      playbook_context: playbook_context
    )
  end

  def initialize(payload, allowed_evidence_ids:, evidence_status:, playbook_context: nil)
    attributes = payload.to_h.stringify_keys
    @decision_type = attributes['decision_type'].to_s
    @response_text = attributes['response_text'].to_s.strip
    @reason_code = attributes['reason_code'].to_s.presence || 'unspecified'
    @evidence_ids = Array(attributes['evidence_ids']).map(&:to_s).uniq
    @tool_request = build_tool_request(attributes['tool_request'])
    @playbook_control = build_playbook_control(attributes['playbook_control'])
    @playbook_context = playbook_context
    validate!(Array(allowed_evidence_ids).map(&:to_s), evidence_status)
  end

  def to_h
    result = {
      'decision_type' => decision_type,
      'response_text' => response_text,
      'reason_code' => reason_code,
      'evidence_ids' => evidence_ids
    }
    result['tool_request'] = tool_request.to_h if tool_request
    result['playbook_control'] = playbook_control.to_h if playbook_control
    result
  end

  private

  def validate!(allowed_evidence_ids, evidence_status)
    raise Invalid, 'Unknown Brain decision type' unless TYPES.include?(decision_type)
    raise Invalid, 'Brain response exceeds the maximum length' if response_text.length > MAX_RESPONSE_LENGTH

    validate_response_text!
    validate_evidence!(allowed_evidence_ids, evidence_status)
    validate_tool_request!
    validate_playbook_control!
  end

  def validate_response_text!
    return validate_reply_response! if %w[reply clarification].include?(decision_type)
    return validate_playbook_response! if decision_type == 'playbook'

    return if response_text.blank?

    raise Invalid, 'Non-reply decisions cannot contain response text'
  end

  def validate_evidence!(allowed_evidence_ids, evidence_status)
    raise Invalid, 'Brain cited evidence outside the supplied set' unless evidence_ids.all? { |id| allowed_evidence_ids.include?(id) }
    return validate_reply_evidence!(evidence_status) if decision_type == 'reply'
    return unless grounded_playbook_side_answer?

    raise Invalid, 'Grounded Playbook side answers require accepted evidence' unless evidence_status == 'accepted'
    raise Invalid, 'Grounded Playbook side answers require at least one evidence citation' if evidence_ids.empty?
  end

  def validate_reply_response!
    raise Invalid, 'Reply decisions require response text' if response_text.blank?
  end

  def validate_playbook_response!
    if playbook_control&.side_question?
      raise Invalid, 'Playbook side-question decisions require response text' if response_text.blank?
      raise Invalid, 'Playbook side-question response exceeds the maximum length' if response_text.length > MAX_PLAYBOOK_RESPONSE_LENGTH
    elsif response_text.present?
      raise Invalid, 'Playbook answer-only decisions cannot contain response text'
    end
  end

  def validate_reply_evidence!(evidence_status)
    raise Invalid, 'Grounded replies require accepted evidence' unless evidence_status == 'accepted'
    raise Invalid, 'Grounded replies require at least one evidence citation' if evidence_ids.empty?
  end

  def grounded_playbook_side_answer?
    decision_type == 'playbook' && playbook_control&.side_question?
  end

  def validate_tool_request!
    if decision_type == 'request_appointment'
      unless tool_request&.definition&.identifier == 'request_appointment@1'
        raise Invalid, 'Appointment decisions require the registered appointment Tool'
      end
    elsif tool_request
      raise Invalid, 'Non-Tool decisions cannot contain a Tool request'
    end
  end

  def validate_playbook_control!
    return validate_playbook_decision! if decision_type == 'playbook'

    raise Invalid, 'Non-Playbook decisions cannot contain Playbook control' if playbook_control
    return unless @playbook_context.present? && decision_type.in?(%w[reply clarification])

    raise Invalid, 'Active Playbook replies must use typed Playbook control'
  end

  def validate_playbook_decision!
    raise Invalid, 'Playbook decisions require an active Playbook' if @playbook_context.blank?
    raise Invalid, 'Playbook decisions require typed control' unless playbook_control
    raise Invalid, 'Playbook decisions cannot request a Tool' if tool_request
    return if playbook_control.side_question? || evidence_ids.empty?

    raise Invalid, 'Non-grounded Playbook actions cannot cite evidence'
  end

  def build_tool_request(payload)
    return if payload.blank?

    ChatRing::Tools::Request.from_payload(payload)
  rescue ChatRing::Tools::Request::Invalid => e
    raise Invalid, e.message
  end

  def build_playbook_control(payload)
    return if payload.blank?

    ChatRing::Playbooks::DecisionControl.from_payload(payload)
  rescue ChatRing::Playbooks::DecisionControl::Invalid => e
    raise Invalid, e.message
  end
end
