require 'bigdecimal'

class ChatRing::Playbooks::AnswerCoercer
  class Invalid < StandardError; end

  BOOLEAN_VALUES = {
    'true' => true,
    'yes' => true,
    'false' => false,
    'no' => false
  }.freeze
  FIELD_COERCERS = {
    'string' => :string_value,
    'email' => :email_value,
    'phone' => :phone_value,
    'number' => :number_value,
    'boolean' => :boolean_value
  }.freeze
  MAX_INTEGER_DIGITS = 18
  MAX_FRACTIONAL_DIGITS = 6
  DECIMAL_FORMAT = /\A-?(?:0|[1-9]\d{0,#{MAX_INTEGER_DIGITS - 1}})(?:\.\d{1,#{MAX_FRACTIONAL_DIGITS}})?\z/

  def self.call(value, field:, step:)
    new(value, field: field, step: step).call
  end

  def initialize(value, field:, step:)
    @value = value.to_s.strip
    @field = field.to_h.deep_stringify_keys
    @step = step.to_h.deep_stringify_keys
  end

  def call
    raise Invalid, 'Playbook answer is required' if value.blank?

    return choice_value if step['kind'] == 'ask_choice'

    coercer = FIELD_COERCERS[field.fetch('type')]
    raise Invalid, 'Playbook field type is unsupported by this step' unless coercer

    send(coercer)
  end

  private

  attr_reader :value, :field, :step

  def choice_value
    choice = Array(step['choices']).find { |item| item['value'].to_s == value }
    raise Invalid, 'Playbook answer must match a published choice value' unless choice

    choice.fetch('value')
  end

  def string_value
    value
  end

  def email_value
    normalized = value.downcase
    raise Invalid, 'Playbook answer is not a valid email address' unless normalized.match?(URI::MailTo::EMAIL_REGEXP)

    normalized
  end

  def phone_value
    valid = value.length.between?(3, 32) && value.match?(/\A[0-9+().\- x]+\z/i) && value.scan(/\d/).length >= 3
    raise Invalid, 'Playbook answer is not a valid phone number' unless valid

    value
  end

  def number_value
    raise Invalid, 'Playbook answer is not a bounded decimal number' unless value.match?(DECIMAL_FORMAT)

    decimal = BigDecimal(value)
    raise Invalid, 'Playbook answer is not a finite number' unless decimal.finite?

    decimal.to_s('F')
  rescue ArgumentError
    raise Invalid, 'Playbook answer is not a valid number'
  end

  def boolean_value
    BOOLEAN_VALUES.fetch(value.downcase)
  rescue KeyError
    raise Invalid, 'Playbook answer must be yes or no'
  end
end
