class ChatRing::Brain::Decision
  class Invalid < StandardError; end

  TYPES = %w[reply clarification request_appointment handoff abstain].freeze
  MAX_RESPONSE_LENGTH = 4000

  attr_reader :decision_type, :response_text, :reason_code, :evidence_ids, :tool_request

  def self.from_payload(payload, allowed_evidence_ids:, evidence_status:)
    new(payload, allowed_evidence_ids: allowed_evidence_ids, evidence_status: evidence_status)
  end

  def initialize(payload, allowed_evidence_ids:, evidence_status:)
    attributes = payload.to_h.stringify_keys
    @decision_type = attributes['decision_type'].to_s
    @response_text = attributes['response_text'].to_s.strip
    @reason_code = attributes['reason_code'].to_s.presence || 'unspecified'
    @evidence_ids = Array(attributes['evidence_ids']).map(&:to_s).uniq
    @tool_request = build_tool_request(attributes['tool_request'])
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
    result
  end

  private

  def validate!(allowed_evidence_ids, evidence_status)
    raise Invalid, 'Unknown Brain decision type' unless TYPES.include?(decision_type)
    raise Invalid, 'Brain response exceeds the maximum length' if response_text.length > MAX_RESPONSE_LENGTH

    validate_response_text!
    validate_evidence!(allowed_evidence_ids, evidence_status)
    validate_tool_request!
  end

  def validate_response_text!
    raise Invalid, 'Reply decisions require response text' if %w[reply clarification].include?(decision_type) && response_text.blank?

    return unless %w[reply clarification].exclude?(decision_type) && response_text.present?

    raise Invalid, 'Non-reply decisions cannot contain response text'
  end

  def validate_evidence!(allowed_evidence_ids, evidence_status)
    raise Invalid, 'Brain cited evidence outside the supplied set' unless evidence_ids.all? { |id| allowed_evidence_ids.include?(id) }
    raise Invalid, 'Grounded replies require accepted evidence' if decision_type == 'reply' && evidence_status != 'accepted'
    raise Invalid, 'Grounded replies require at least one evidence citation' if decision_type == 'reply' && evidence_ids.empty?
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

  def build_tool_request(payload)
    return if payload.blank?

    ChatRing::Tools::Request.from_payload(payload)
  rescue ChatRing::Tools::Request::Invalid => e
    raise Invalid, e.message
  end
end
