class ChatRing::Knowledge::ProviderValidator
  class Error < StandardError; end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity, Style/IfUnlessModifier
  def self.validate!(version)
    documents = version.documents.order(:id).to_a
    raise Error, 'Knowledge version has no documents' if documents.empty?
    raise Error, 'Knowledge version has incomplete documents' unless documents.all? { |document| document.provider_status == 'ready' }

    source_ids = documents.pluck(:provider_source_id).compact_blank.uniq
    raise Error, 'Knowledge version must reference exactly one DocsGPT source' unless source_ids.one?

    client = ChatRing::Knowledge::DocsGptClient.new(
      base_url: ENV.fetch('DOCSGPT_BASE_URL'),
      jwt_secret: ENV.fetch('DOCSGPT_JWT_SECRET'),
      internal_key: ENV.fetch('DOCSGPT_INTERNAL_KEY'),
      service_secret: ENV.fetch('DOCSGPT_SERVICE_SECRET')
    )
    chunks = client.chunks(source_ids.first)
    raise Error, 'DocsGPT source has no chunks' if chunks.empty?

    chunk_references = chunks.map { |chunk| chunk.dig('metadata', 'source').to_s.presence }
    raise Error, 'DocsGPT contains chunks without a source reference' if chunk_references.any?(&:blank?)

    references = chunk_references.uniq
    expected_references = documents.map(&:provider_source_reference).compact_blank.uniq
    unless expected_references.length == documents.length
      raise Error, 'Knowledge version has incomplete provider source references'
    end

    missing_references = expected_references - references
    unexpected_references = references - expected_references
    if missing_references.any?
      raise Error, "DocsGPT is missing #{missing_references.length} published source reference(s)"
    end
    if unexpected_references.any?
      raise Error, "DocsGPT contains #{unexpected_references.length} source reference(s) outside the published manifest"
    end

    evidence_set = provider(version, source_ids.first).retrieve(
      query: probe_query(documents.first),
      knowledge_version_id: version.id.to_s,
      source_manifest: ChatRing::Knowledge::Retriever.source_manifest(version),
      limit: 1
    )
    raise Error, "DocsGPT retrieval probe failed with #{evidence_set.status}" unless evidence_set.status == 'accepted'

    true
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity, Style/IfUnlessModifier

  def self.provider(version, source_id)
    ChatRing::Knowledge::DocsGptProvider.new(
      base_url: ENV.fetch('DOCSGPT_BASE_URL'),
      provider_release: version.provider_release,
      provider_source_id: source_id,
      account_id: version.account_id,
      binding_digest: version.evaluation_binding_digest,
      internal_key: ENV.fetch('DOCSGPT_INTERNAL_KEY'),
      service_secret: ENV.fetch('DOCSGPT_SERVICE_SECRET'),
      score_threshold: version.config_snapshot.dig('retrieval', 'score_threshold') || ENV.fetch('DOCSGPT_SCORE_THRESHOLD')
    )
  end
  private_class_method :provider

  def self.probe_query(document)
    text = document.markdown.to_s.gsub(/[#*_`\[\]()]/, ' ').squish
    text.first(300)
  end
  private_class_method :probe_query
end
