require 'digest'

class ChatRing::Knowledge::EvidenceSetMerger
  RETRIEVAL_STRATEGY = 'dual_query_max_score'.freeze

  def self.call(evidence_sets, limit: ChatRing::Knowledge::DocsGptProvider::DEFAULT_EVIDENCE_LIMIT)
    new(evidence_sets, limit: limit).call
  end

  def initialize(evidence_sets, limit:)
    @evidence_sets = Array(evidence_sets)
    @limit = Integer(limit)
  end

  def call
    raise ChatRing::Knowledge::Retriever::Error, 'Evidence fusion requires at least one result' if evidence_sets.empty?
    return evidence_sets.first if evidence_sets.one?

    validate_compatible_results!
    items = merged_items
    status = result_status(items)
    build_evidence_set(status, status == 'accepted' ? items : [])
  end

  private

  attr_reader :evidence_sets, :limit

  def validate_compatible_results!
    raise ChatRing::Knowledge::Retriever::Error, 'Evidence fusion limit is invalid' unless limit.between?(1, 20)

    %i[knowledge_index_id provider provider_release].each do |attribute|
      values = evidence_sets.map { |set| set.public_send(attribute) }.uniq
      raise ChatRing::Knowledge::Retriever::Error, "Evidence fusion #{attribute} mismatch" unless values.length == 1
    end
    validate_retrieval_contract!
  end

  def validate_retrieval_contract!
    strategies = evidence_sets.map(&:retrieval_strategy).uniq
    configurations = evidence_sets.map { |set| comparable_configuration(set.retrieval_configuration) }.uniq
    score_kinds = evidence_sets.flat_map(&:items).map(&:score_kind).uniq
    item_strategies = evidence_sets.flat_map(&:items).map(&:retrieval_strategy).uniq
    unless strategies.one? && configurations.one? && score_kinds.length <= 1 && (item_strategies - strategies).empty?
      raise ChatRing::Knowledge::Retriever::Error, 'Evidence fusion retrieval contract mismatch'
    end
  end

  def comparable_configuration(configuration)
    configuration.to_h.slice(
      'endpoint', 'limit', 'candidate_selection', 'score_threshold', 'binding_digest'
    )
  end

  def provider_error?
    evidence_sets.any? { |set| set.status == 'provider_error' }
  end

  def result_status(items)
    return 'provider_error' if provider_error?
    return 'accepted' if items.any?

    'insufficient_evidence'
  end

  def merged_items
    evidence_sets.flat_map(&:items)
                 .group_by(&:id)
                 .values
                 .map { |matches| matches.max_by { |item| [item.score, -item.rank] } }
                 .sort_by { |item| [-item.score, item.rank, item.id] }
                 .first(limit)
                 .each_with_index
                 .map { |item, index| fused_item(item, index + 1) }
                 .freeze
  end

  def fused_item(item, rank)
    ChatRing::Knowledge::Evidence.new(**item.to_h, rank: rank, retrieval_strategy: RETRIEVAL_STRATEGY)
  end

  def build_evidence_set(status, items)
    first = evidence_sets.first
    ChatRing::Knowledge::EvidenceSet.new(
      knowledge_index_id: first.knowledge_index_id,
      provider: first.provider,
      provider_release: first.provider_release,
      query: evidence_sets.first.query,
      status: status,
      error_code: evidence_sets.find { |set| set.status == 'provider_error' }&.error_code,
      latency_ms: evidence_sets.sum { |set| set.latency_ms.to_i },
      retrieval_strategy: RETRIEVAL_STRATEGY,
      retrieval_configuration: retrieval_configuration,
      items: items.freeze
    )
  end

  def retrieval_configuration
    {
      'fusion' => 'max_score',
      'score_kind' => evidence_sets.flat_map(&:items).first&.score_kind,
      'query_count' => evidence_sets.length,
      'queries' => evidence_sets.map do |set|
        {
          'query_digest' => Digest::SHA256.hexdigest(set.query),
          'status' => set.status,
          'retrieval_strategy' => set.retrieval_strategy
        }
      end
    }.freeze
  end
end
