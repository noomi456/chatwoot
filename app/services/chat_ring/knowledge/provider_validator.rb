class ChatRing::Knowledge::ProviderValidator
  class Error < StandardError; end

  def self.validate!(version) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
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

    references = chunks.filter_map { |chunk| chunk.dig('metadata', 'source').to_s.presence }.uniq
    documents.each do |document|
      raise Error, "DocsGPT no longer contains document #{document.id}" unless references.include?(document.provider_source_reference)
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

  def self.provider(version, source_id)
    ChatRing::Knowledge::DocsGptProvider.new(
      base_url: ENV.fetch('DOCSGPT_BASE_URL'),
      provider_release: version.provider_release,
      provider_source_id: source_id,
      account_id: version.account_id,
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
