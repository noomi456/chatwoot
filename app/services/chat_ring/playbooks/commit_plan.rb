class ChatRing::Playbooks::CommitPlan # rubocop:disable Metrics/ClassLength
  class Invalid < StandardError
    attr_reader :code

    def initialize(code)
      @code = code
      super(code)
    end
  end

  UNAVAILABLE_SIDE_ANSWER = "I don't have enough verified information to answer that.".freeze
  MAX_MESSAGE_LENGTH = 4000
  BUILDERS = {
    'ask_current_step' => :build_initial_question!,
    'submit_answer' => :build_answer_without_side_question!,
    'answer_side_question' => :build_side_question!,
    'submit_answer_and_answer_side_question' => :build_answer_with_side_question!,
    'resume_pending_question' => :build_resume_pending_question!
  }.freeze

  attr_reader :content, :content_type, :content_attributes

  def self.build(turn:, execution:)
    new(turn: turn, execution: execution).tap(&:build!)
  end

  def initialize(turn:, execution:)
    @turn = turn
    @execution = execution
    @control = turn.decision_payload.to_h.fetch('playbook_control', {}).deep_stringify_keys
  end

  def apply!(message)
    execution.update!(
      execution_attributes.merge(
        last_outcome_message: message,
        transition_history: execution.transition_history + [transition_record(message)]
      )
    )
  end

  def build!
    validate_snapshot!
    send(BUILDERS.fetch(control.fetch('action')))
    raise Invalid, 'playbook_message_too_long' if content.to_s.length > MAX_MESSAGE_LENGTH
  rescue KeyError
    raise Invalid, control['action'].present? ? 'playbook_commit_action_unsupported' : 'playbook_commit_control_invalid'
  end

  private

  attr_reader :turn, :execution, :control
  attr_accessor :execution_attributes, :transition_action, :from_step_id, :to_step_id
  attr_writer :content, :content_type, :content_attributes

  def validate_snapshot!
    raise Invalid, 'playbook_commit_control_stale' unless execution.id == turn.inbox_playbook_execution_id
    raise Invalid, 'playbook_commit_control_stale' unless execution.lock_version == turn.playbook_execution_lock_version
    raise Invalid, 'playbook_commit_control_stale' unless execution.current_step_id == turn.playbook_step_id
    raise Invalid, 'playbook_trigger_changed' unless execution.last_trigger_message_id == turn.trigger_message_id
  end

  def build_initial_question!
    raise Invalid, 'playbook_execution_not_active' unless execution.status_active?
    raise Invalid, 'playbook_step_unsupported' unless question_step?(current_step)

    self.content = ChatRing::Playbooks::QuestionRenderer.call(current_step)
    configure_presentation(current_step)
    self.execution_attributes = { status: :waiting_for_customer }
    self.transition_action = 'ask_current_step'
    self.from_step_id = execution.current_step_id
    self.to_step_id = execution.current_step_id
  end

  def build_side_question!
    validate_waiting_question!
    self.content = compose(side_answer, rendered_current_question)
    configure_presentation(current_step)
    self.execution_attributes = { status: :waiting_for_customer }
    self.transition_action = 'answer_side_question'
    self.from_step_id = execution.current_step_id
    self.to_step_id = execution.current_step_id
  end

  def build_resume_pending_question!
    validate_waiting_question!
    self.content = compose(UNAVAILABLE_SIDE_ANSWER, ChatRing::Playbooks::QuestionRenderer.call(current_step))
    configure_presentation(current_step)
    self.execution_attributes = { status: :waiting_for_customer }
    self.transition_action = 'resume_pending_question'
    self.from_step_id = execution.current_step_id
    self.to_step_id = execution.current_step_id
  end

  def build_answer!(include_side_answer:)
    validate_waiting_question!
    value = coerced_answer
    navigation = navigate_from(next_step_id(value))
    self.content = answer_content(navigation, include_side_answer)
    configure_presentation(navigation.fetch(:step))
    self.execution_attributes = answer_execution_attributes(value, navigation)
    self.transition_action = include_side_answer ? 'submit_answer_and_answer_side_question' : 'submit_answer'
    self.from_step_id = execution.current_step_id
    self.to_step_id = navigation.fetch(:step).fetch('id')
  end

  def build_answer_without_side_question!
    build_answer!(include_side_answer: false)
  end

  def build_answer_with_side_question!
    build_answer!(include_side_answer: true)
  end

  def coerced_answer
    ChatRing::Playbooks::AnswerCoercer.call(
      control.fetch('answer_value'),
      field: current_field,
      step: current_step
    )
  end

  def answer_content(navigation, include_side_answer)
    next_content = navigation.fetch(:content)
    return next_content unless include_side_answer

    compose(side_answer, next_content)
  end

  def side_answer
    answer = turn.decision_payload.fetch('response_text').to_s.strip
    remove_echoed_pending_question(answer)
  end

  def remove_echoed_pending_question(answer)
    paragraphs = answer.split(/\n{2,}/)
    return answer unless echoed_pending_question?(paragraphs.last)

    paragraphs[0...-1].join("\n\n").strip
  end

  def echoed_pending_question?(paragraph)
    paragraph.to_s.rstrip.end_with?('?') &&
      normalized_question(paragraph) == normalized_question(rendered_current_question)
  end

  def normalized_question(value)
    value.to_s.unicode_normalize(:nfkc).downcase
         .gsub(/[^\p{Alnum}]+/u, ' ')
         .strip
         .sub(/\A(?:what|which|who|whom|whose|when|where|why|how)\s+/, '')
  end

  def rendered_current_question
    @rendered_current_question ||= ChatRing::Playbooks::QuestionRenderer.call(current_step)
  end

  def answer_execution_attributes(value, navigation)
    attributes = {
      status: navigation.fetch(:status),
      current_step_id: navigation.fetch(:step).fetch('id'),
      collected_fields: execution.collected_fields.merge(current_step.fetch('field_key') => value),
      field_sources: execution.field_sources.merge(current_step.fetch('field_key') => field_source)
    }
    attributes[:completed_at] = Time.current unless controlling_status?(navigation.fetch(:status))
    attributes
  end

  def controlling_status?(status)
    ChatRing::InboxPlaybookExecution::CONTROLLING_STATUSES.include?(status.to_s)
  end

  def validate_waiting_question!
    raise Invalid, 'playbook_execution_not_waiting' unless execution.status_waiting_for_customer?
    raise Invalid, 'playbook_step_unsupported' unless question_step?(current_step)
  end

  def current_step
    @current_step ||= execution.current_step.to_h.deep_stringify_keys
  end

  def current_field
    key = current_step.fetch('field_key')
    field = Array(version.definition['collected_fields']).find { |item| item['key'] == key }
    raise Invalid, 'playbook_field_missing' unless field

    field
  end

  def next_step_id(value)
    return current_step.fetch('next_step_id') if current_step['kind'] == 'ask_text'

    choice = Array(current_step['choices']).find { |item| item['value'].to_s == value.to_s }
    raise Invalid, 'playbook_choice_missing' unless choice

    choice.fetch('next_step_id')
  end

  def navigate_from(step_id)
    step = version_step(step_id)
    return navigate_tool_step(step) if step['kind'] == 'tool'

    ChatRing::Playbooks::StepNavigator.call(version: version, step_id: step_id)
  rescue ChatRing::Playbooks::StepNavigator::Invalid => e
    raise Invalid, e.message
  rescue ChatRing::Tools::OutcomePreparer::Rejected => e
    raise Invalid, e.code
  end

  def navigate_tool_step(step)
    tool = step.fetch('tool')
    raise Invalid, 'playbook_tool_unsupported' unless tool.values_at('key', 'version') == ['request_appointment', 1]

    authorization = ChatRing::Tools::RequestAppointmentAuthorization.call(
      turn,
      enforce_playbook_allowlist: true,
      presentation_context: 'playbook_step',
      playbook_step_id: step.fetch('id')
    )
    tool_execution = ChatRing::Tools::RequestAppointmentExecutionBuilder.call(
      turn: turn,
      outbound_commit: turn.outbound_commit,
      authorization: authorization,
      arguments: {},
      authorization_result: 'authorized_playbook_step'
    )
    next_result = ChatRing::Playbooks::StepNavigator.call(
      version: version,
      step_id: step.fetch('next_step_id')
    )
    next_result.merge(content: compose(tool_execution.rendered_content, next_result.fetch(:content)))
  end

  def version_step(step_id)
    step = Array(version.definition['steps']).find { |item| item['id'] == step_id }
    raise Invalid, 'playbook_next_step_missing' unless step

    step.deep_stringify_keys
  end

  def question_step?(step)
    %w[ask_text ask_choice].include?(step['kind'])
  end

  def version
    execution.inbox_playbook_version
  end

  def field_source
    {
      'message_id' => turn.trigger_message_id,
      'ai_turn_id' => turn.id,
      'playbook_version_id' => execution.inbox_playbook_version_id,
      'step_id' => execution.current_step_id
    }
  end

  def compose(*parts)
    parts.map { |part| part.to_s.strip }.reject(&:blank?).join("\n\n")
  end

  def configure_presentation(step)
    self.content_type = 'text'
    self.content_attributes = {}
    return unless step['kind'] == 'ask_choice'

    self.content_attributes = {
      'chatring_playbook_options' => Array(step['choices']).map do |choice|
        choice.slice('label', 'value')
      end
    }
  end

  def transition_record(message)
    {
      'action' => transition_action,
      'from_step_id' => from_step_id,
      'to_step_id' => to_step_id,
      'trigger_message_id' => turn.trigger_message_id,
      'outcome_message_id' => message.id,
      'committed_at' => Time.current.iso8601(6)
    }
  end
end
