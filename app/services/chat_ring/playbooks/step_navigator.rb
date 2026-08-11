class ChatRing::Playbooks::StepNavigator
  class Invalid < StandardError; end

  def self.call(version:, step_id:)
    new(version: version).call(step_id)
  end

  def initialize(version:)
    @version = version
  end

  def call(step_id)
    messages = []
    step = step_by_id(step_id)
    while step['kind'] == 'inform'
      messages << step.fetch('message')
      step = step_by_id(step.fetch('next_step_id'))
    end
    render_outcome(step, messages)
  end

  private

  attr_reader :version

  def render_outcome(step, messages)
    case step['kind']
    when 'ask_text', 'ask_choice'
      messages << ChatRing::Playbooks::QuestionRenderer.call(step)
      result(step, :waiting_for_customer, messages)
    when 'terminal'
      messages << terminal_message(step)
      result(step, terminal_status(step), messages)
    else
      raise Invalid, 'playbook_step_unsupported'
    end
  end

  def result(step, status, messages)
    { step: step, status: status, content: messages.join("\n\n") }
  end

  def terminal_message(step)
    step.fetch('message')
  rescue KeyError
    raise Invalid, 'playbook_terminal_outcome_unsupported'
  end

  def terminal_status(step)
    step.fetch('outcome') == 'complete' ? :completed : :stopped
  end

  def step_by_id(id)
    step = Array(version.definition['steps']).find { |item| item['id'] == id }
    raise Invalid, 'playbook_next_step_missing' unless step

    step.deep_stringify_keys
  end
end
