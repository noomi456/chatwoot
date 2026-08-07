require 'digest'
require 'securerandom'

# rubocop:disable Metrics/ClassLength
class ChatRing::Knowledge::SyncService
  POLL_INTERVAL = 10.seconds
  PROCESSING_LEASE_TTL = 10.minutes
  TERMINAL_TASK_FAILURES = %w[FAILURE REVOKED].freeze
  ACTIVE_TASK_STATUSES = %w[PENDING STARTED PROGRESS RETRY].freeze

  class Error < StandardError; end
  class IncompleteCrawlError < Error; end
  class ProviderIngestionError < Error; end

  def self.start!(account:, inbox:, root_url:, publish_on_ready: false)
    raise ArgumentError, 'inbox must belong to account' unless inbox.account_id == account.id
    raise ArgumentError, 'publish_on_ready is disabled; evaluate the ready version before publication' if publish_on_ready

    version = ChatRing::KnowledgeVersion.create!(
      account: account,
      inbox: inbox,
      root_url: ChatRing::Knowledge::FirecrawlClient.canonical_url(root_url),
      provider: 'docs_gpt',
      provider_release: ENV.fetch('DOCSGPT_RELEASE', '616e6fe9c435bbc6bb472636db6b3ee2b9bcaf66'),
      config_snapshot: configuration_snapshot
    )
    ChatRing::Knowledge::SyncJob.perform_later(version.id)
    version
  end

  def self.rebuild_from!(source_version) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    # rubocop:disable Metrics/BlockLength
    version = ChatRing::KnowledgeVersion.transaction do
      source_version.lock!
      unless %w[ready published retired].include?(source_version.status) && source_version.documents.exists?
        raise ArgumentError, 'Rebuild source must be a complete ready, published, or retired knowledge version'
      end

      verify_manifest_digest!(source_version)

      rebuilt = ChatRing::KnowledgeVersion.create!(
        account: source_version.account,
        inbox: source_version.inbox,
        status: 'ingesting',
        root_url: source_version.root_url,
        provider: 'docs_gpt',
        provider_release: ENV.fetch('DOCSGPT_RELEASE', source_version.provider_release),
        config_snapshot: configuration_snapshot.merge(
          'build_mode' => 'stored_snapshot_rebuild',
          'source_knowledge_version_id' => source_version.id
        ),
        mapped_manifest: source_version.mapped_manifest,
        manifest_digest: Digest::SHA256.hexdigest(source_version.mapped_manifest.to_json),
        crawl_errors: source_version.crawl_errors
      )
      source_version.documents.order(:id).to_a.each do |document|
        verify_document_hash!(document)
        structure = ChatRing::Knowledge::MarkdownStructure.new(
          markdown: document.markdown,
          source_url: document.source_url
        ).call
        rebuilt.documents.create!(
          source_url: document.source_url,
          title: document.title,
          markdown: document.markdown,
          content_hash: document.content_hash,
          provider_file_name: document.provider_file_name,
          metadata: document.metadata.merge(structure),
          provider_status: 'pending'
        )
      end
      rebuilt
    end
    # rubocop:enable Metrics/BlockLength
    ChatRing::Knowledge::SyncJob.perform_later(version.id)
    version
  end

  def self.configuration_snapshot
    {
      'firecrawl_flow' => 'map_then_batch_scrape',
      'firecrawl_map_limit' => Integer(ENV.fetch('FIRECRAWL_MAP_LIMIT', 5000)),
      'source_policy_version' => ChatRing::Knowledge::SourcePolicy::VERSION,
      'docs_gpt_source_config' => ChatRing::Knowledge::DocsGptClient::SOURCE_CONFIG.deep_stringify_keys,
      'embedding_model' => 'huggingface_sentence-transformers/all-mpnet-base-v2',
      'retrieval' => {
        'strategy' => ChatRing::Knowledge::DocsGptProvider::RETRIEVAL_STRATEGY,
        'score_threshold' => Float(ENV.fetch('DOCSGPT_SCORE_THRESHOLD'))
      }
    }
  end
  private_class_method :configuration_snapshot

  def self.verify_document_hash!(document)
    return if Digest::SHA256.hexdigest(document.markdown) == document.content_hash

    raise IncompleteCrawlError, "Stored document #{document.id} does not match its content hash"
  end
  private_class_method :verify_document_hash!

  def self.verify_manifest_digest!(version)
    expected = Digest::SHA256.hexdigest(version.mapped_manifest.to_json)
    return if expected == version.manifest_digest

    raise IncompleteCrawlError, "Stored knowledge version #{version.id} does not match its manifest digest"
  end
  private_class_method :verify_manifest_digest!

  def initialize(version, firecrawl: nil, docs_gpt: nil)
    @version = version
    @firecrawl = firecrawl || build_firecrawl_client
    @docs_gpt = docs_gpt || build_docs_gpt_client
  end

  def tick # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength
    return :retry unless claim_processing_lease

    begin
      case @version.reload.status
      when 'pending' then start_batch_scrape
      when 'crawling' then process_batch_scrape
      when 'ingesting' then process_ingestion
      when 'ready', 'published', 'retired', 'failed' then :complete
      else raise Error, "Unknown knowledge version status #{@version.status.inspect}"
      end
    ensure
      release_processing_lease
    end
  rescue ChatRing::Knowledge::FirecrawlClient::RequestError, ChatRing::Knowledge::DocsGptClient::RequestError
    raise
  rescue StandardError => e
    unless @version.reload.status == 'failed'
      @version.reload.fail!(code: e.class.name, message: e.message)
      ChatRing::Knowledge::ProviderCleanupScheduler.schedule_eligible!(account: @version.account, inbox: @version.inbox)
    end
    raise
  end

  private

  def claim_processing_lease
    @processing_lease_token = SecureRandom.uuid
    now = Time.current
    affected = ChatRing::KnowledgeVersion.where(id: @version.id)
                                         .where('processing_lease_expires_at IS NULL OR processing_lease_expires_at < ?', now)
                                         .update_all( # rubocop:disable Rails/SkipsModelValidations
                                           processing_lease_token: @processing_lease_token,
                                           processing_lease_expires_at: now + PROCESSING_LEASE_TTL,
                                           updated_at: now
                                         )
    affected == 1
  end

  def release_processing_lease
    return if @processing_lease_token.blank?

    leased_version = ChatRing::KnowledgeVersion.where(id: @version.id, processing_lease_token: @processing_lease_token)
    leased_version.update_all( # rubocop:disable Rails/SkipsModelValidations
      processing_lease_token: nil,
      processing_lease_expires_at: nil,
      updated_at: Time.current
    )
  end

  def start_batch_scrape
    if @version.firecrawl_start_started_at.present? && @version.firecrawl_crawl_id.blank?
      raise IncompleteCrawlError, 'Firecrawl batch start has an indeterminate prior result; create a new staged version'
    end

    mapped = @firecrawl.map(url: @version.root_url, limit: @version.config_snapshot.fetch('firecrawl_map_limit'))
    mapped_manifest = source_policy.prepare_manifest(mapped)
    raise IncompleteCrawlError, 'Firecrawl map returned no URLs' if mapped_manifest.empty?

    accepted_urls = mapped_manifest.filter_map { |entry| entry['url'] if entry['included'] }
    raise IncompleteCrawlError, 'Firecrawl map returned no accepted knowledge URLs' if accepted_urls.empty?

    @version.update!(
      firecrawl_start_started_at: Time.current,
      mapped_manifest: mapped_manifest,
      manifest_digest: Digest::SHA256.hexdigest(mapped_manifest.to_json)
    )
    batch_id = @firecrawl.start_batch_scrape(urls: accepted_urls)
    @version.update!(
      status: 'crawling',
      firecrawl_crawl_id: batch_id
    )
    :retry
  end

  def process_batch_scrape # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    payload = @firecrawl.batch_status(@version.firecrawl_crawl_id)
    status = payload['status'].to_s
    return :retry if %w[scraping pending].include?(status)
    raise IncompleteCrawlError, "Firecrawl batch scrape ended with status #{status}" unless status == 'completed'

    error_payload = @firecrawl.batch_errors(@version.firecrawl_crawl_id)
    documents = source_policy.normalize_pages(records: payload.fetch('data', []), manifest: @version.mapped_manifest)
    accepted_urls = documents.pluck(:source_url).to_set
    publication_manifest = @version.mapped_manifest.map do |entry|
      next entry unless entry['included'] && accepted_urls.exclude?(entry['url'])

      entry.merge('included' => false, 'exclusion_reason' => 'duplicate_content')
    end

    @version.transaction do
      @version.documents.delete_all
      documents.each { |entry| @version.documents.create!(entry) }
      @version.update!(
        status: 'ingesting',
        mapped_manifest: publication_manifest,
        manifest_digest: Digest::SHA256.hexdigest(publication_manifest.to_json),
        crawl_errors: sanitized_crawl_errors(error_payload, [])
      )
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
      @version.documents.find_each { |document| document.update!(provider_status: 'failed') }
      raise ProviderIngestionError, "DocsGPT ingestion failed for knowledge version #{@version.id}"
    end
    raise ProviderIngestionError, "DocsGPT returned unknown task status #{task_status.inspect}" unless task_status == 'SUCCESS'

    finalize_version(documents) if documents.any? { |document| document.provider_status != 'ready' }

    @version.update!(
      status: 'ready',
      provider_agent_id: nil,
      provider_agent_api_key: nil,
      provider_agent_creation_started_at: nil,
      evaluation_status: 'pending',
      evaluation_report: {},
      evaluated_at: nil,
      ready_at: Time.current
    )
    :complete
  end

  def start_version_upload(documents)
    result = @docs_gpt.upload_version(@version)
    documents.each do |document|
      document.update!(
        provider_task_id: result.fetch(:task_id),
        provider_source_id: result.fetch(:source_id),
        provider_status: 'processing'
      )
    end
  end

  def finalize_version(documents)
    chunks = @docs_gpt.chunks(documents.first.provider_source_id)
    matches_by_document = ChatRing::Knowledge::ProviderChunkValidator.validate!(
      documents: documents,
      chunks: chunks,
      error_class: ProviderIngestionError
    )

    matches_by_document.each do |document, reference|
      document.update!(provider_status: 'ready', provider_source_reference: reference)
    end
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
    ChatRing::Knowledge::DocsGptClient.new(
      base_url: ENV.fetch('DOCSGPT_BASE_URL'),
      jwt_secret: ENV.fetch('DOCSGPT_JWT_SECRET'),
      internal_key: ENV.fetch('DOCSGPT_INTERNAL_KEY'),
      service_secret: ENV.fetch('DOCSGPT_SERVICE_SECRET')
    )
  end

  def source_policy
    @source_policy ||= ChatRing::Knowledge::SourcePolicy.new(root_url: @version.root_url)
  end
end
# rubocop:enable Metrics/ClassLength
