class ChatRing::Knowledge::Retriever
  class Error < StandardError; end

  def self.retrieve(inbox:, query:, limit: 5)
    publication = ChatRing::KnowledgePublication.includes(knowledge_version: :documents).find_by!(
      account_id: inbox.account_id,
      inbox_id: inbox.id
    )
    version = publication.knowledge_version
    raise Error, 'Published knowledge pointer does not reference a published version' unless version.status == 'published'

    manifest = version.documents.index_by(&:provider_source_reference).transform_values do |document|
      {
        'content_hash' => document.content_hash,
        'source_reference' => document.source_url,
        'source_title' => document.title,
        'locator' => document.source_url
      }
    end
    provider = ChatRing::Knowledge::DocsGptProvider.new(
      base_url: ENV.fetch('DOCSGPT_BASE_URL'),
      agent_api_key: version.provider_agent_api_key,
      provider_release: version.provider_release
    )
    provider.retrieve(
      query: query,
      knowledge_version_id: version.id.to_s,
      source_manifest: manifest,
      limit: limit
    )
  end
end
