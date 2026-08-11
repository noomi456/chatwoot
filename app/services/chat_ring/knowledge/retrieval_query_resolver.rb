class ChatRing::Knowledge::RetrievalQueryResolver
  MAX_QUERY_CHARACTERS = ChatRing::Knowledge::DocsGptProvider::MAX_QUERY_LENGTH
  MAX_CURRENT_QUERY_CHARACTERS = 900
  MAX_CONTEXT_CHARACTERS = 800
  MAX_CONTEXT_MESSAGE_CHARACTERS = 500
  REFERENCE_PATTERN = /\b(?:it|its|that|this|they|them|their|those|these|one|ones|former|latter|same|other)\b/i
  FOLLOW_UP_PATTERN = /\A(?:tell me more|what else|anything else|why|how so)[?.!]*\z/i

  Result = Data.define(
    :raw_query,
    :standalone_query,
    :retrieval_query,
    :history_message_ids,
    :contextualized,
    :strategy
  ) do
    def audit_metadata
      {
        'strategy' => strategy,
        'contextualized' => contextualized,
        'history_message_ids' => history_message_ids
      }
    end
  end

  def initialize(raw_query:, history:, identity_anchor: nil)
    @raw_query = normalize(raw_query).first(MAX_QUERY_CHARACTERS)
    @history = Array(history)
    @identity_anchor = normalize(identity_anchor).first(200)
  end

  def call
    context = relevant_context
    contextualized = context.present? && reference_dependent?
    standalone_query = contextualized ? contextual_query(context) : raw_query
    retrieval_query = [identity_prefix(standalone_query), standalone_query].compact.join("\n").first(MAX_QUERY_CHARACTERS)

    Result.new(
      raw_query: raw_query,
      standalone_query: standalone_query,
      retrieval_query: retrieval_query,
      history_message_ids: contextualized ? context.pluck('message_id').freeze : [].freeze,
      contextualized: contextualized,
      strategy: contextualized ? 'bounded_native_history' : 'standalone_with_identity_anchor'
    )
  end

  private

  attr_reader :raw_query, :history, :identity_anchor

  def reference_dependent?
    raw_query.match?(REFERENCE_PATTERN) || raw_query.match?(FOLLOW_UP_PATTERN)
  end

  def relevant_context
    candidates = history.filter_map { |item| normalized_history_item(item) }
    customer_index = candidates.rindex { |item| item.fetch('speaker') == 'customer' }
    return candidates.last(2) unless customer_index

    customer = candidates.fetch(customer_index)
    response = candidates[(customer_index + 1)..]&.reverse&.find { |item| item.fetch('speaker') != 'customer' }
    [customer, response].compact
  end

  def normalized_history_item(item)
    speaker = item.to_h['speaker'].to_s
    return if speaker == 'native_template'

    content = normalize(item.to_h['content']).first(MAX_CONTEXT_MESSAGE_CHARACTERS)
    message_id = item.to_h['message_id'].to_i
    return if content.blank? || !message_id.positive?

    { 'message_id' => message_id, 'speaker' => speaker, 'content' => content }
  end

  def contextual_query(context)
    context_lines = context.map do |item|
      "#{speaker_label(item.fetch('speaker'))}: #{item.fetch('content')}"
    end.join("\n").first(MAX_CONTEXT_CHARACTERS)

    "Current question: #{raw_query.first(MAX_CURRENT_QUERY_CHARACTERS)}\nRelevant prior public conversation:\n#{context_lines}"
  end

  def identity_prefix(query)
    return if identity_anchor.blank? || query.downcase.include?(identity_anchor.downcase)

    identity_anchor
  end

  def speaker_label(speaker)
    speaker == 'customer' ? 'Customer' : 'Previous response'
  end

  def normalize(value)
    value.to_s.scrub.gsub(/\s+/, ' ').strip
  end
end
