require 'digest'

class ChatRing::Knowledge::SyncService
  POLL_INTERVAL = 10.seconds
  TERMINAL_TASK_FAILURES = %w[FAILURE REVOKED].freeze
  ACTIVE_TASK_STATUSES = %w[PENDING STARTED PROGRESS RETRY].freeze

  class Error < StandardError; end
  class IncompleteCrawlError < Error; end
  class ProviderIngestionError < Error; end

  def self.start!(account:, inbox:, root_url:, publish_on_ready: false)
    raise ArgumentError, 'inbox must belong to account' unless inbox.account_id == account.id

    version = ChatRing::KnowledgeVersion.create!(
      account: account,
      inbox: inbox,
      root_url: ChatRing::Knowledge::FirecrawlClient.canonical_url(root_url),
      provider: 'docs_gpt',
      provider_release: ENV.fetch('DOCSGPT_RELEASE', '616e6fe9c435bbc6bb472636db6b3ee2b9bcaf66'),
      config_snapshot: {
        'firecrawl_flow' => 'map_then_crawl',
        'docs_gpt_source_config' => ChatRing::Knowledge::DocsGptClient::SOURCE_CONFIG.deep_stringify_keys,
        'publish_on_ready' => ActiveModel::Type::Boolean.new.cast(publish_on_ready)
      }
    )
    ChatRing::Knowledge::SyncJob.perform_later(version.id)
    version
  end

  def initialize(version, firecrawl: nil, docs_gpt: nil)
    @version = version
    @firecrawl = firecrawl || build_firecrawl_client
    @docs_gpt = docs_gpt || build_docs_gpt_client
  end

  def tick
    case @version.reload.status
    when 'pending' then start_crawl
    when 'crawling' then process_crawl
    when 'ingesting' then process_ingestion
    when 'ready', 'published', 'retired', 'failed' then :complete
    else raise Error, "Unknown knowledge version status #{@version.status.inspect}"
    end
  rescue ChatRing::Knowledge::FirecrawlClient::RequestError, ChatRing::Knowledge::DocsGptClient::RequestError
    raise
  rescue StandardError => e
    @version.reload.fail!(code: e.class.name, message: e.message) unless @version.reload.status == 'failed'
    raise
  end

  private

  def start_crawl
    if @version.firecrawl_start_started_at.present? && @version.firecrawl_crawl_id.blank?
      raise IncompleteCrawlError, 'Firecrawl crawl start has an indeterminate prior result; create a new staged version'
    end

    mapped_manifest = @firecrawl.map(url: @version.root_url)
    raise IncompleteCrawlError, 'Firecrawl map returned no URLs' if mapped_manifest.empty?

    @version.update!(
      firecrawl_start_started_at: Time.current,
      mapped_manifest: mapped_manifest,
      manifest_digest: Digest::SHA256.hexdigest(mapped_manifest.to_json)
    )
    crawl_id = @firecrawl.start_crawl(url: @version.root_url, limit: mapped_manifest.length)
    @version.update!(
      status: 'crawling',
      firecrawl_crawl_id: crawl_id
    )
    :retry
  end

  def process_crawl # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    payload = @firecrawl.crawl_status(@version.firecrawl_crawl_id)
    status = payload['status'].to_s
    return :retry if %w[scraping pending].include?(status)
    raise IncompleteCrawlError, "Firecrawl crawl ended with status #{status}" unless status == 'completed'

    error_payload = @firecrawl.crawl_errors(@version.firecrawl_crawl_id)
    documents = normalized_documents(payload.fetch('data', []))
    mapped_urls = @version.mapped_manifest.to_set { |entry| entry.fetch('url') }
    crawled_urls = documents.to_set { |entry| entry.fetch(:source_url) }
    missing_urls = mapped_urls - crawled_urls
    if missing_urls.any?
      @version.update!(crawl_errors: sanitized_crawl_errors(error_payload, missing_urls))
      raise IncompleteCrawlError, "Firecrawl crawl omitted #{missing_urls.length} mapped URL(s)"
    end

    @version.transaction do
      @version.documents.delete_all
      documents.select { |entry| mapped_urls.include?(entry.fetch(:source_url)) }.each do |entry|
        @version.documents.create!(entry)
      end
      @version.update!(status: 'ingesting', crawl_errors: sanitized_crawl_errors(error_payload, []))
    end
    :retry
  end

  def process_ingestion # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
    documents = @version.documents.order(:id).to_a
    raise ProviderIngestionError, 'Knowledge version contains no documents' if documents.empty?

    start_version_upload(documents) if documents.all? { |document| document.provider_task_id.blank? }
    if documents.any? { |document| document.reload.provider_task_id.blank? }
      raise ProviderIngestionError, 'DocsGPT version upload is only partially recorded'
    end

    task_status = @docs_gpt.task_status(documents.first.provider_task_id)['status'].to_s.upcase
    return :retry if ACTIVE_TASK_STATUSES.include?(task_status)

    if TERMINAL_TASK_FAILURES.include?(task_status)
      @version.documents.update_all(provider_status: 'failed')
      raise ProviderIngestionError, "DocsGPT ingestion failed for knowledge version #{@version.id}"
    end
    raise ProviderIngestionError, "DocsGPT returned unknown task status #{task_status.inspect}" unless task_status == 'SUCCESS'

    finalize_version(documents) if documents.any? { |document| document.provider_status != 'ready' }

    if @version.provider_agent_creation_started_at.present? && @version.provider_agent_id.blank?
      raise ProviderIngestionError, 'DocsGPT agent creation has an indeterminate prior result; manual reconciliation is required'
    end

    @version.update!(provider_agent_creation_started_at: Time.current)
    agent = @docs_gpt.create_agent(@version)
    @version.update!(
      status: 'ready',
      provider_agent_id: agent.fetch(:id),
      provider_agent_api_key: agent.fetch(:key),
      ready_at: Time.current
    )
    ChatRing::Knowledge::PublicationService.publish!(@version) if @version.config_snapshot['publish_on_ready']
    :complete
  end

  def start_version_upload(documents)
    result = @docs_gpt.upload_version(@version)
    @version.documents.where(id: documents.map(&:id)).update_all(
      provider_task_id: result.fetch(:task_id),
      provider_source_id: result.fetch(:source_id),
      provider_status: 'processing',
      updated_at: Time.current
    )
  end

  def finalize_version(documents)
    chunks = @docs_gpt.chunks(documents.first.provider_source_id)
    raise ProviderIngestionError, "DocsGPT produced no chunks for knowledge version #{@version.id}" if chunks.empty?

    references = chunks.filter_map { |chunk| chunk.dig('metadata', 'source').to_s.presence }.uniq
    documents.each do |document|
      matches = references.select { |reference| File.basename(reference) == document.provider_file_name }
      raise ProviderIngestionError, "DocsGPT chunks do not identify document #{document.id}" unless matches.one?

      document.update!(provider_status: 'ready', provider_source_reference: matches.first)
    end
  end

  def normalized_documents(records)
    raise IncompleteCrawlError, 'Firecrawl crawl data must be an array' unless records.is_a?(Array)

    documents = records.filter_map { |record| normalized_document(record) }
    documents.uniq { |entry| entry.fetch(:source_url) }
  end

  def normalized_document(record)
    return unless record.is_a?(Hash)

    markdown = record['markdown'].to_s.strip
    metadata = record['metadata'].is_a?(Hash) ? record['metadata'] : {}
    source = metadata['sourceURL'] || metadata['url'] || record['url']
    return if markdown.blank? || source.blank?

    canonical_url = ChatRing::Knowledge::FirecrawlClient.canonical_url(source)
    {
      source_url: canonical_url,
      title: metadata['title'].to_s.presence,
      markdown: markdown,
      content_hash: Digest::SHA256.hexdigest(markdown),
      provider_file_name: "#{Digest::SHA256.hexdigest(canonical_url).first(24)}.md",
      metadata: metadata.slice('title', 'description', 'language', 'statusCode', 'sourceURL')
    }
  end

  def sanitized_crawl_errors(payload, missing_urls)
    {
      'errors' => Array(payload['errors']).first(100),
      'robots_blocked' => Array(payload['robotsBlocked']).first(100),
      'missing_urls' => Array(missing_urls).first(100)
    }
  end

  def build_firecrawl_client
    ChatRing::Knowledge::FirecrawlClient.new(api_key: ENV.fetch('FIRECRAWL_API_KEY'))
  end

  def build_docs_gpt_client
    ChatRing::Knowledge::DocsGptClient.new(base_url: ENV.fetch('DOCSGPT_BASE_URL'))
  end
end
