class ChatRing::Knowledge::Retriever
  class Error < StandardError; end

  def self.published_version_id(inbox:)
    current_version(inbox).id
  end

  def self.retrieve(inbox:, query:, limit: ChatRing::Knowledge::DocsGptProvider::DEFAULT_EVIDENCE_LIMIT,
                    knowledge_version_id: nil)
    version = knowledge_version_id.present? ? pinned_version(inbox, knowledge_version_id) : current_version(inbox)
    provider(version).retrieve(
      query: query,
      knowledge_version_id: version.id.to_s,
      source_manifest: source_manifest(version),
      limit: limit
    )
  end

  def self.current_publication(inbox)
    ChatRing::KnowledgePublication.includes(knowledge_version: :documents).find_by!(
      account_id: inbox.account_id,
      inbox_id: inbox.id
    )
  end
  private_class_method :current_publication

  def self.current_version(inbox)
    version = current_publication(inbox).knowledge_version
    raise Error, 'Published knowledge pointer does not reference a published version' unless version.status == 'published'

    version
  end
  private_class_method :current_version

  def self.pinned_version(inbox, knowledge_version_id)
    version = ChatRing::KnowledgeVersion.includes(:documents).find_by!(
      id: knowledge_version_id,
      account_id: inbox.account_id,
      inbox_id: inbox.id
    )
    published_before = ChatRing::KnowledgePublicationEvent.exists?(
      account_id: inbox.account_id,
      inbox_id: inbox.id,
      to_knowledge_version_id: version.id
    )
    raise Error, 'Pinned knowledge version was never published for this inbox' unless published_before

    version
  end
  private_class_method :pinned_version

  def self.source_manifest(version)
    version.documents.index_by(&:provider_source_reference).transform_values do |document|
      {
        'content_hash' => document.content_hash,
        'source_reference' => document.source_url,
        'source_title' => document.title,
        'locator' => document.source_url,
        'authority_class' => document.metadata['authority_class'].presence || 'unclassified_legacy',
        'headings' => document.metadata['headings'] || [],
        'cta_candidates' => document.metadata['cta_candidates'] || []
      }
    end
  end

  def self.provider(version)
    source_ids = version.documents.pluck(:provider_source_id).compact_blank.uniq
    raise Error, 'Published knowledge version must reference exactly one DocsGPT source' unless source_ids.one?

    ChatRing::Knowledge::DocsGptProvider.new(
      base_url: ENV.fetch('DOCSGPT_BASE_URL'),
      provider_release: version.provider_release,
      provider_source_id: source_ids.first,
      account_id: version.account_id,
      binding_digest: version.evaluation_binding_digest,
      internal_key: ENV.fetch('DOCSGPT_INTERNAL_KEY'),
      service_secret: ENV.fetch('DOCSGPT_SERVICE_SECRET'),
      score_threshold: version.config_snapshot.dig('retrieval', 'score_threshold') || ENV.fetch('DOCSGPT_SCORE_THRESHOLD')
    )
  end

  private_class_method :provider
end
