class ChatRing::Knowledge::Retriever
  class Error < StandardError; end
  ACTIVE_INDEX = Object.new.freeze

  def self.active_index_id(inbox:)
    knowledge_base_for(inbox.account).active_knowledge_index_id
  end

  def self.retrieve(inbox:, query:, limit: ChatRing::Knowledge::DocsGptProvider::DEFAULT_EVIDENCE_LIMIT,
                    knowledge_scope: nil, knowledge_index_id: ACTIVE_INDEX)
    raise Error, 'Inbox must belong to an account' if inbox.account.blank?

    knowledge_base = knowledge_base_for(inbox.account)
    index = provider_index(knowledge_base, knowledge_index_id)
    return empty_set(query, limit) if index.blank? || knowledge_base.materials.retrievable.none?

    evidence_set = provider(index).retrieve(
      query: query,
      knowledge_index_id: index.id.to_s,
      source_manifest: source_manifest(index, knowledge_scope: knowledge_scope),
      limit: limit
    )
    filter_live_evidence(evidence_set, index, knowledge_scope)
  end

  def self.knowledge_base_for(account)
    ChatRing::KnowledgeBase.for_account!(account)
  end
  private_class_method :knowledge_base_for

  def self.active_provider_index(knowledge_base)
    index = knowledge_base.active_knowledge_index
    return if index.blank?
    raise Error, 'Active knowledge index is not ready for retrieval' unless index.status == 'active'

    index
  end
  private_class_method :active_provider_index

  def self.provider_index(knowledge_base, knowledge_index_id)
    return active_provider_index(knowledge_base) if knowledge_index_id.equal?(ACTIVE_INDEX)
    return if knowledge_index_id.blank?

    index = knowledge_base.knowledge_indexes.find_by(id: knowledge_index_id)
    raise Error, 'Pinned knowledge index does not belong to the Inbox Account' if index.blank?
    raise Error, 'Pinned knowledge index is unavailable for retrieval' unless %w[active retired].include?(index.status)

    index
  end
  private_class_method :provider_index

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def self.source_manifest(index, knowledge_scope: nil)
    index.documents.includes(:knowledge_material).index_by(&:provider_source_reference).transform_values do |document|
      material = document.knowledge_material
      {
        'active' => material.active? && document.metadata['material_key'] == material.material_key &&
          scope_allows?(material, knowledge_scope),
        'content_hash' => document.content_hash,
        'source_kind' => document.source_kind,
        'source_reference' => document.source_reference,
        'source_title' => document.title,
        'public_url' => document.public_url,
        'locator' => document.public_url || document.title,
        'page_locator' => document.metadata['page_locator'],
        'authority_class' => document.metadata['authority_class'].presence || material.authority_class,
        'risk_flags' => Array(document.metadata['risk_flags'] || material.risk_flags),
        'headings' => document.metadata['headings'] || [],
        'cta_candidates' => document.metadata['cta_candidates'] || []
      }
    end
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  def self.scope_allows?(material, scope)
    return true if scope.blank?
    raise Error, 'Knowledge scope belongs to another Workspace' unless scope.workspace_id == material.knowledge_base.workspace_id

    rule = scope.material_rules.find_by(knowledge_material_id: material.id)
    return rule.access == 'allow' if rule

    scope.business_wide?
  end
  private_class_method :scope_allows?

  def self.filter_live_evidence(evidence_set, index, knowledge_scope) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    return evidence_set unless evidence_set.status == 'accepted'

    documents = index.documents.includes(:knowledge_material).index_by(&:source_reference)
    items = evidence_set.items.select do |evidence|
      document = documents[evidence.source_reference]
      next false if document.blank?

      material = document.knowledge_material.reload
      material.active? && document.metadata['material_key'] == material.material_key &&
        scope_allows?(material, knowledge_scope)
    end
    status = items.empty? ? 'insufficient_evidence' : 'accepted'
    ChatRing::Knowledge::EvidenceSet.new(
      knowledge_index_id: evidence_set.knowledge_index_id,
      provider: evidence_set.provider,
      provider_release: evidence_set.provider_release,
      query: evidence_set.query,
      status: status,
      error_code: evidence_set.error_code,
      latency_ms: evidence_set.latency_ms,
      retrieval_strategy: evidence_set.retrieval_strategy,
      retrieval_configuration: evidence_set.retrieval_configuration,
      items: items.freeze
    )
  end
  private_class_method :filter_live_evidence

  def self.provider(index)
    source_ids = index.documents.pluck(:provider_source_id).compact_blank.uniq
    raise Error, 'Active knowledge index must reference exactly one DocsGPT source' unless source_ids.one?

    ChatRing::Knowledge::DocsGptProvider.new(
      base_url: ENV.fetch('DOCSGPT_BASE_URL'),
      provider_release: index.provider_release,
      provider_source_id: source_ids.first,
      account_id: index.account_id,
      binding_digest: index.provider_binding_digest,
      internal_key: ENV.fetch('DOCSGPT_INTERNAL_KEY'),
      service_secret: ENV.fetch('DOCSGPT_SERVICE_SECRET'),
      score_threshold: index.config_snapshot.dig('retrieval', 'score_threshold') || ENV.fetch('DOCSGPT_SCORE_THRESHOLD')
    )
  end
  private_class_method :provider

  def self.empty_set(query, limit)
    ChatRing::Knowledge::EvidenceSet.new(
      knowledge_index_id: nil,
      provider: ChatRing::Knowledge::DocsGptProvider::PROVIDER,
      provider_release: ENV.fetch('DOCSGPT_RELEASE', '616e6fe9c435bbc6bb472636db6b3ee2b9bcaf66'),
      query: query.to_s,
      status: 'insufficient_evidence',
      error_code: nil,
      latency_ms: 0,
      retrieval_strategy: ChatRing::Knowledge::DocsGptProvider::RETRIEVAL_STRATEGY,
      retrieval_configuration: { 'limit' => Integer(limit) },
      items: [].freeze
    )
  end
  private_class_method :empty_set
end
