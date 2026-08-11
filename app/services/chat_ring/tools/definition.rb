class ChatRing::Tools::Definition
  attr_reader :key, :version, :category, :description, :input_schema, :output_schema,
              :side_effect_class, :authorization_policy, :idempotency_policy, :renderer_families

  # rubocop:disable Metrics/ParameterLists
  def initialize(key:, version:, category:, description:, input_schema:, output_schema:, side_effect_class:,
                 authorization_policy:, idempotency_policy:, renderer_families:)
    @key = key.to_s.freeze
    @version = Integer(version)
    @category = category.to_s.freeze
    @description = description.to_s.freeze
    @input_schema = deep_freeze(input_schema)
    @output_schema = deep_freeze(output_schema)
    @side_effect_class = side_effect_class.to_s.freeze
    @authorization_policy = authorization_policy.to_s.freeze
    @idempotency_policy = idempotency_policy.to_s.freeze
    @renderer_families = renderer_families.map(&:to_s).freeze
    freeze
  end
  # rubocop:enable Metrics/ParameterLists

  def identifier
    "#{key}@#{version}"
  end

  def as_json(*)
    {
      key: key,
      version: version,
      category: category,
      description: description,
      input_schema: input_schema,
      output_schema: output_schema,
      side_effect_class: side_effect_class,
      authorization_policy: authorization_policy,
      idempotency_policy: idempotency_policy,
      renderer_families: renderer_families
    }
  end

  private

  def deep_freeze(value)
    case value
    when Hash
      value.deep_dup.transform_values { |item| deep_freeze(item) }.freeze
    when Array
      value.map { |item| deep_freeze(item) }.freeze
    when String
      value.dup.freeze
    else
      value.freeze
    end
  end
end
