require 'digest'

class ChatRing::Brain::Invocation
  attr_reader :kind, :trusted_context, :model_context, :audit_metadata, :query, :retrieval_queries, :deadline_at

  # rubocop:disable Metrics/ParameterLists
  def initialize(kind:, trusted_context:, model_context:, audit_metadata:, query:, deadline_at:, retrieval_queries: nil)
    @kind = kind.to_s.dup.freeze
    @trusted_context = deep_freeze(trusted_context)
    @model_context = deep_freeze(model_context)
    @audit_metadata = deep_freeze(audit_metadata)
    @query = query.to_s.dup.freeze
    @retrieval_queries = Array(retrieval_queries.presence || [@query]).map { |item| item.to_s.dup.freeze }.uniq.freeze
    @deadline_at = deadline_at
    freeze
  end
  # rubocop:enable Metrics/ParameterLists

  def digest
    Digest::SHA256.hexdigest(
      JSON.generate(
        'trusted_context' => trusted_context,
        'model_context' => model_context,
        'kind' => kind,
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
