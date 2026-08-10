require 'digest'

class ChatRing::Brain::Invocation
  attr_reader :trusted_context, :model_context, :audit_metadata, :query, :deadline_at

  def initialize(trusted_context:, model_context:, audit_metadata:, query:, deadline_at:)
    @trusted_context = deep_freeze(trusted_context)
    @model_context = deep_freeze(model_context)
    @audit_metadata = deep_freeze(audit_metadata)
    @query = query.to_s.dup.freeze
    @deadline_at = deadline_at
    freeze
  end

  def digest
    Digest::SHA256.hexdigest(
      JSON.generate(
        'trusted_context' => trusted_context,
        'model_context' => model_context,
        'deadline_at' => deadline_at&.iso8601
      )
    )
  end

  private

  def deep_freeze(value)
    case value
    when Hash
      value.to_h.transform_values { |item| deep_freeze(item) }.freeze
    when Array
      value.map { |item| deep_freeze(item) }.freeze
    when String
      value.dup.freeze
    else
      value.freeze
    end
  end
end
