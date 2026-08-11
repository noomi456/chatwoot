class ChatRing::Brain::Decision
  class Invalid < StandardError; end

  TYPES = %w[reply clarification context_reply playbook request_appointment handoff abstain].freeze
  MAX_RESPONSE_LENGTH = 4000
  MAX_PLAYBOOK_RESPONSE_LENGTH = 900
  MAX_SUGGESTED_QUESTIONS = 2
  MAX_SUGGESTED_QUESTION_LENGTH = 160
  MAX_RESPONSE_OPTIONS = 6
  HISTORY_REPLY_ERROR = 'Conversation replies require an explicit history request with prior public history'.freeze

  attr_reader :decision_type, :response_text, :reason_code, :evidence_ids, :suggested_questions, :response_options,
              :microsite_section_types, :tool_request, :playbook_control

  def self.from_payload(payload, allowed_evidence_ids:, evidence_status:, playbook_context: nil,
                        conversation_history_reply_allowed: false)
    new(
      payload,
      allowed_evidence_ids: allowed_evidence_ids,
      evidence_status: evidence_status,
      playbook_context: playbook_context,
      conversation_history_reply_allowed: conversation_history_reply_allowed
    )
  end

  def initialize(payload, allowed_evidence_ids:, evidence_status:, playbook_context: nil, # rubocop:disable Metrics/AbcSize
                 conversation_history_reply_allowed: false)
    attributes = payload.to_h.stringify_keys
    @decision_type = attributes['decision_type'].to_s
    @response_text = attributes['response_text'].to_s.strip
    @reason_code = attributes['reason_code'].to_s.presence || 'unspecified'
    @evidence_ids = Array(attributes['evidence_ids']).map(&:to_s).uniq
    @suggested_questions = Array(attributes['suggested_questions']).map { |item| item.to_s.strip }.reject(&:blank?).uniq
    @response_options = normalize_response_options(attributes['response_options'])
    @microsite_section_types = normalize_microsite_types(attributes['microsite_section_types'])
    @tool_request = build_tool_request(attributes['tool_request'])
    @playbook_control = build_playbook_control(attributes['playbook_control'])
    @playbook_context = playbook_context
    @conversation_history_reply_allowed = conversation_history_reply_allowed
    validate!(Array(allowed_evidence_ids).map(&:to_s), evidence_status)
  end

  def to_h
    result = {
      'decision_type' => decision_type,
      'response_text' => response_text,
      'reason_code' => reason_code,
      'evidence_ids' => evidence_ids,
      'suggested_questions' => suggested_questions,
      'response_options' => response_options,
      'microsite_section_types' => microsite_section_types
    }
    result['tool_request'] = tool_request.to_h if tool_request
    result['playbook_control'] = playbook_control.to_h if playbook_control
    result
  end

  private

  def normalize_microsite_types(values)
    ChatRing::Microsites::SectionContract.normalize_types(values)
  rescue ChatRing::Microsites::SectionContract::Invalid => e
    raise Invalid, e.message
  end

  def normalize_response_options(values)
    Array(values).map { |item| item.to_s.strip }.reject(&:blank?).uniq.freeze
  end

  def validate!(allowed_evidence_ids, evidence_status)
    raise Invalid, 'Unknown Brain decision type' unless TYPES.include?(decision_type)
    raise Invalid, 'Brain response exceeds the maximum length' if response_text.length > MAX_RESPONSE_LENGTH

    validate_response_text!
    validate_evidence!(allowed_evidence_ids, evidence_status)
    validate_suggested_questions!(evidence_status)
    validate_response_options!
    validate_microsite_request!(evidence_status)
    validate_tool_request!
    validate_playbook_control!
  end

  def validate_suggested_questions!(evidence_status) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    if suggested_questions.length > MAX_SUGGESTED_QUESTIONS ||
       suggested_questions.any? { |question| question.length > MAX_SUGGESTED_QUESTION_LENGTH }
      raise Invalid, 'Suggested questions exceed the bounded contract'
    end
    raise Invalid, 'Suggested questions are allowed only with grounded replies' if suggested_questions.present? && decision_type != 'reply'
    raise Invalid, 'Suggested questions require accepted evidence' if suggested_questions.present? && evidence_status != 'accepted'
    raise Invalid, 'Active Playbooks cannot emit suggested questions' if suggested_questions.present? && @playbook_context.present?
  end

  def validate_response_options! # rubocop:disable Metrics/CyclomaticComplexity
    return if response_options.empty?

    if response_options.length > MAX_RESPONSE_OPTIONS || response_options.any? { |option| option.length > 160 }
      raise Invalid, 'Response options exceed the bounded contract'
    end
    raise Invalid, 'Response options require a reply or clarification' unless decision_type.in?(%w[reply clarification])
    raise Invalid, 'Response options cannot be mixed with suggested questions' if suggested_questions.present?
    raise Invalid, 'Active Playbooks use their published options' if @playbook_context.present?
  end

  def validate_microsite_request!(evidence_status)
    return if microsite_section_types.empty?

    raise Invalid, 'Microsite request exceeds the bounded contract' if microsite_section_types.length > 3
    raise Invalid, 'Microsites are allowed only with grounded replies' unless decision_type == 'reply'
    raise Invalid, 'Microsites require accepted evidence' unless evidence_status == 'accepted' && evidence_ids.present?
    raise Invalid, 'Active Playbooks cannot emit a free-form microsite' if @playbook_context.present?
  end

  def validate_response_text!
    return validate_reply_response! if %w[reply clarification context_reply].include?(decision_type)
    return validate_playbook_response! if decision_type == 'playbook'

    return if response_text.blank?

    raise Invalid, 'Non-reply decisions cannot contain response text'
  end

  def validate_evidence!(allowed_evidence_ids, evidence_status)
    raise Invalid, 'Brain cited evidence outside the supplied set' unless evidence_ids.all? { |id| allowed_evidence_ids.include?(id) }
    return validate_reply_evidence!(evidence_status) if decision_type == 'reply'
    return validate_context_reply! if decision_type == 'context_reply'
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

  def validate_context_reply!
    raise Invalid, HISTORY_REPLY_ERROR unless @conversation_history_reply_allowed

    raise Invalid, 'Conversation replies cannot cite Business Knowledge evidence' if evidence_ids.present?
    raise Invalid, 'Conversation replies require the conversation_history reason code' unless reason_code == 'conversation_history'
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
    return unless @playbook_context.present? && decision_type.in?(%w[reply clarification context_reply])

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
