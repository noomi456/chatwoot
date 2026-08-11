class ChatRing::Tools::Registry
  REQUEST_APPOINTMENT = ChatRing::Tools::Definition.new(
    key: 'request_appointment',
    version: 1,
    category: 'conversation_presentation',
    description: 'Offer an Inbox-approved appointment path without allowing the model to choose a URL.',
    input_schema: {
      'type' => 'object',
      'additionalProperties' => false,
      'properties' => {
        'requested_time_window' => { 'type' => 'string', 'maxLength' => 160 },
        'reason_code' => { 'type' => 'string', 'pattern' => '^[a-z0-9_]+$', 'maxLength' => 80 }
      }
    },
    output_schema: {
      'type' => 'object',
      'additionalProperties' => false,
      'required' => %w[presentation_mode approved_url],
      'properties' => {
        'presentation_mode' => { 'enum' => %w[approved_link calendar_embed] },
        'provider' => { 'enum' => %w[calendly calcom custom_link] },
        'approved_url' => { 'type' => 'string', 'format' => 'uri' },
        'link_label' => { 'type' => 'string', 'minLength' => 1, 'maxLength' => 80 }
      }
    },
    side_effect_class: 'customer_visible',
    authorization_policy: 'inbox_tool_policy',
    idempotency_policy: 'one_customer_visible_result_per_origin',
    renderer_families: %w[approved_link calendar_embed]
  )

  DEFINITIONS = [REQUEST_APPOINTMENT].index_by(&:identifier).freeze

  class << self
    def all
      DEFINITIONS.values
    end

    def fetch(key, version)
      DEFINITIONS.fetch("#{key}@#{Integer(version)}")
    rescue KeyError, ArgumentError
      raise KeyError, "Unknown ChatRing Tool #{key}@#{version}"
    end

    def exist?(key, version)
      DEFINITIONS.key?("#{key}@#{Integer(version)}")
    rescue ArgumentError, TypeError
      false
    end
  end
end
