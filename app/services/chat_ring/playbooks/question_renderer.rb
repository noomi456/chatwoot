class ChatRing::Playbooks::QuestionRenderer
  class UnsupportedStep < StandardError; end

  def self.call(step)
    new(step).call
  end

  def initialize(step)
    @step = step.to_h.deep_stringify_keys
  end

  def call
    prompt = step.fetch('prompt').to_s.strip
    raise UnsupportedStep, 'Playbook question is missing' if prompt.blank?

    return prompt if step.fetch('kind') == 'ask_text'
    raise UnsupportedStep, 'Playbook step is not a question' unless step.fetch('kind') == 'ask_choice'

    choices = Array(step['choices'])
    raise UnsupportedStep, 'Playbook choices are missing' if choices.empty?

    ([prompt] + choices.each_with_index.map { |choice, index| "#{index + 1}. #{choice.fetch('label')}" }).join("\n")
  end

  private

  attr_reader :step
end
