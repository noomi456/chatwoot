require 'digest'

class ChatRing::Knowledge::RetrievalQueryResolver
  MAX_QUERY_CHARACTERS = ChatRing::Knowledge::DocsGptProvider::MAX_QUERY_LENGTH
  MAX_CURRENT_QUERY_CHARACTERS = 1_000
  MAX_CONTEXT_CHARACTERS = 700
  MAX_CONTEXT_MESSAGE_CHARACTERS = 350
  REFERENCE_PATTERN = /\b(?:it|its|that|this|they|them|their|those|these|one|ones|former|latter|he|him|his|she|her|hers)\b/i
  REFERENTIAL_PHRASE_PATTERN = /\b(?:the other one|the same one)\b/i
  FOLLOW_UP_PATTERN = /\A(?:tell me more|what else|anything else|why|how so)[?.!]*\z/i
  FORCE_RESPONSE_CONTEXT_PATTERN = /\b(?:he|him|his|she|her|hers)\b/i
  RESPONSE_FOLLOW_UP_PATTERN = /\A(?:what else|anything else|why|how so)[?.!]*\z/i
  ALTERNATIVE_REFERENCE_PATTERN = /\b(?:one|ones|former|latter|the other one|the same one)\b/i
  ALTERNATIVE_ANTECEDENT_PATTERN = /\b(?:and|or|between|compare|comparison|versus|vs\.?)\b/i
  HISTORY_REQUEST_PATTERN = /
    \b(?:
      (?:what|which|who|when|where|how)\s+(?:did|have)\s+(?:i|we|you|the\s+(?:agent|human))\b.{0,48}
      \b(?:ask|say|mention|discuss|talk|tell|recommend)|
      (?:what|which|who|when|where|how)\s+(?:was|were)\s+(?:i|we|you|the\s+(?:agent|human))\b.{0,48}
      \b(?:asking|saying|mentioning|discussing|talking|telling|recommending)|
      (?:what|which|who|when|where|how)\s+(?:i|we|you|the\s+(?:agent|human))\b.{0,48}
      \b(?:asked|said|mentioned|discussed|talked|told|recommended)|
      (?:conversation|chat)\s+history|last\s+(?:message|question|topic)|
      (?:remind\s+me|recap|summarize).{0,48}(?:conversation|chat|discussion)
    )\b
  /ix
  GENERIC_ANTECEDENT_WORDS = %w[
    a about an are available best can case could did do does for how i is know me more my need option options our please recommend
    recommended same should suggest suggested tell that the think this to was were what which who why would you your
  ].to_set.freeze
  REFERENCE_RESPONSE_SPEAKERS = %w[managed_ai human_agent].freeze

  Result = Data.define(
    :raw_query,
    :contextual_query,
    :retrieval_queries,
    :history_message_ids,
    :contextualized,
    :conversation_history_request,
    :strategy
  ) do
    def retrieval_query
      retrieval_queries.first
    end

    def audit_metadata
      {
        'strategy' => strategy,
        'contextualized' => contextualized,
        'conversation_history_request' => conversation_history_request,
        'history_message_ids' => history_message_ids,
        'query_count' => retrieval_queries.length,
        'query_digests' => retrieval_queries.map { |query| Digest::SHA256.hexdigest(query) }
      }
    end
  end

  def initialize(raw_query:, history:)
    @raw_query = normalize(raw_query).first(MAX_CURRENT_QUERY_CHARACTERS)
    @history = Array(history)
  end

  def call
    context = reference_dependent? ? relevant_context : []
    contextual_query = build_contextual_query(context) if context.present?
    queries = [raw_query, contextual_query].compact.uniq.map { |query| query.first(MAX_QUERY_CHARACTERS) }.freeze

    Result.new(
      raw_query: raw_query,
      contextual_query: contextual_query,
      retrieval_queries: queries,
      history_message_ids: context.pluck('message_id').freeze,
      contextualized: contextual_query.present?,
      conversation_history_request: raw_query.match?(HISTORY_REQUEST_PATTERN),
      strategy: contextual_query.present? ? 'dual_query_minimum_antecedent' : 'current_turn_only'
    )
  end

  private

  attr_reader :raw_query, :history

  def reference_dependent?
    raw_query.match?(REFERENCE_PATTERN) || raw_query.match?(REFERENTIAL_PHRASE_PATTERN) || raw_query.match?(FOLLOW_UP_PATTERN)
  end

  def relevant_context
    candidates = history.filter_map { |item| normalized_history_item(item) }
    customer_index = candidates.rindex { |item| item.fetch('speaker') == 'customer' }
    return [] unless customer_index

    customer = candidates.fetch(customer_index)
    return [customer] unless response_context_required?(customer)

    response = relevant_response(candidates, customer_index)
    response ? [customer, response] : []
  end

  def relevant_response(candidates, customer_index)
    candidates[(customer_index + 1)..]&.reverse&.find do |item|
      REFERENCE_RESPONSE_SPEAKERS.include?(item.fetch('speaker'))
    end
  end

  def response_context_required?(customer)
    return true if raw_query.match?(FORCE_RESPONSE_CONTEXT_PATTERN) || raw_query.match?(RESPONSE_FOLLOW_UP_PATTERN)

    !customer_antecedent_sufficient?(customer.fetch('content'))
  end

  def customer_antecedent_sufficient?(content)
    return content.match?(ALTERNATIVE_ANTECEDENT_PATTERN) if raw_query.match?(ALTERNATIVE_REFERENCE_PATTERN)

    content.downcase.scan(/[a-z0-9][a-z0-9'-]*/).any? { |word| GENERIC_ANTECEDENT_WORDS.exclude?(word) }
  end

  def normalized_history_item(item)
    speaker = item.to_h['speaker'].to_s
    return if speaker == 'native_template'

    content = normalize(item.to_h['content']).first(MAX_CONTEXT_MESSAGE_CHARACTERS)
    message_id = item.to_h['message_id'].to_i
    return if content.blank? || !message_id.positive?

    { 'message_id' => message_id, 'speaker' => speaker, 'content' => content }
  end

  def build_contextual_query(context)
    context_lines = context.map { |item| item.fetch('content').first(MAX_CONTEXT_MESSAGE_CHARACTERS) }
                           .join("\n").first(MAX_CONTEXT_CHARACTERS)

    "#{context_lines}\n#{raw_query}"
  end

  def normalize(value)
    value.to_s.scrub.gsub(/\s+/, ' ').strip
  end
end
