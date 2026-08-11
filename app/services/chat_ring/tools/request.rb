require 'json_schemer'

class ChatRing::Tools::Request
  class Invalid < StandardError; end

  ATTRIBUTES = %w[key version arguments].freeze

  attr_reader :definition, :arguments

  def self.from_payload(payload)
    new(payload)
  end

  def initialize(payload)
    attributes = payload.to_h.deep_stringify_keys
    raise Invalid, 'Tool request contains unknown fields' unless (attributes.keys - ATTRIBUTES).empty?

    @definition = ChatRing::Tools::Registry.fetch(attributes.fetch('key'), attributes.fetch('version'))
    @arguments = attributes.fetch('arguments', {}).to_h.deep_stringify_keys.compact.freeze
    validate_arguments!
    freeze
  rescue KeyError, ArgumentError, TypeError => e
    raise Invalid, e.message
  end

  def to_h
    {
      'key' => definition.key,
      'version' => definition.version,
      'arguments' => arguments
    }
  end

  private

  def validate_arguments!
    return if JSONSchemer.schema(definition.input_schema).valid?(arguments)

    raise Invalid, 'Tool request arguments do not match the registered schema'
  end
end
