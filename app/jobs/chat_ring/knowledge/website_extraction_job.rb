class ChatRing::Knowledge::WebsiteExtractionJob < ApplicationJob
  queue_as :default

  def perform(source_id, selected_urls, force_fresh, extraction_mode = 'batch', extraction_token = nil)
    source = ChatRing::KnowledgeWebsiteSource.find(source_id)
    return if source.status == 'deleted'
    return unless extraction_token.present? && source.extraction_token == extraction_token
    return unless %w[extracting refreshing].include?(source.status)

    if extraction_mode == 'single'
      page = firecrawl.scrape(url: selected_urls.fetch(0), max_age: force_fresh ? 0 : nil)
      apply_results!(source, { 'data' => [page] }, extraction_token: extraction_token, provider_errors: {})
      return
    end

    raise ArgumentError, "Unknown website extraction mode: #{extraction_mode}" unless extraction_mode == 'batch'

    if source.firecrawl_crawl_id.blank?
      crawl_id = firecrawl.start_batch_scrape(urls: selected_urls, max_age: force_fresh ? 0 : nil)
      source.update!(firecrawl_crawl_id: crawl_id)
      self.class.set(wait: ChatRing::Knowledge::SyncService::POLL_INTERVAL)
                .perform_later(source_id, selected_urls, force_fresh, extraction_mode, extraction_token)
      return
    end

    payload = firecrawl.batch_status(source.firecrawl_crawl_id)
    status = payload['status'].to_s
    if %w[scraping pending].include?(status)
      self.class.set(wait: ChatRing::Knowledge::SyncService::POLL_INTERVAL)
                .perform_later(source_id, selected_urls, force_fresh, extraction_mode, extraction_token)
      return
    end
    raise ChatRing::Knowledge::FirecrawlClient::ResponseError, "Firecrawl extraction ended with status #{status}" unless status == 'completed'

    apply_results!(source, payload, extraction_token: extraction_token)
  rescue ChatRing::Knowledge::FirecrawlClient::RequestError,
         ChatRing::Knowledge::FirecrawlClient::ResponseError,
         ChatRing::Knowledge::SourcePolicy::Error => e
    self.class.send(:mark_failed, source, e, extraction_token) if source
  end

  def self.mark_failed(source, error, extraction_token)
    ChatRing::KnowledgeMaterial.transaction do
      source.knowledge_base.lock!
      source.lock!
      return unless source.extraction_token == extraction_token

      source.materials.active.where(status: %w[processing updating]).find_each do |material|
        material.update!(status: material.markdown.present? ? 'refresh_failed' : 'failed')
      end
      source.update!(
        status: source.materials.retrievable.exists? ? 'refresh_failed' : 'failed',
        failure_code: error.class.name,
        failure_message: error.message.to_s.truncate(1000),
        firecrawl_crawl_id: nil,
        extraction_token: nil
      )
    end
  end
  private_class_method :mark_failed

  private

  def apply_results!(source, payload, extraction_token:, provider_errors: nil) # rubocop:disable Metrics/MethodLength
    policy = ChatRing::Knowledge::SourcePolicy.new(root_url: source.root_url)
    pages, page_errors = policy.normalize_pages_with_errors(
      records: payload.fetch('data', []),
      manifest: source.mapped_manifest
    )
    provider_errors ||= firecrawl.batch_errors(source.firecrawl_crawl_id)

    ChatRing::KnowledgeMaterial.transaction do
      source.knowledge_base.lock!
      source.lock!
      return unless source.extraction_token == extraction_token

      pages.each { |page| upsert_page!(source, page) }
      successful_references = pages.pluck(:source_reference).to_set
      source.materials.active.where(status: %w[processing updating]).find_each do |material|
        next if successful_references.include?(material.source_reference)

        material.update!(status: material.markdown.present? ? 'refresh_failed' : 'failed')
      end
      source.update!(
        status: pages.any? ? 'available' : (source.materials.retrievable.exists? ? 'refresh_failed' : 'failed'),
        crawl_errors: {
          'pages' => page_errors,
          'provider' => Array(provider_errors['errors']).first(100),
          'robots_blocked' => Array(provider_errors['robotsBlocked']).first(100)
        },
        last_processed_at: Time.current,
        firecrawl_crawl_id: nil,
        extraction_token: nil,
        failure_code: pages.empty? ? 'no_pages_extracted' : nil,
        failure_message: pages.empty? ? 'Firecrawl returned no usable selected pages' : nil
      )
    end
    ChatRing::Knowledge::IndexBuilder.enqueue!(source.knowledge_base) if pages.any?
  end

  def upsert_page!(source, page)
    material = source.knowledge_base.materials.find_or_initialize_by(source_reference: page.fetch(:source_reference))
    return if material.persisted? && !material.active?
    replacing_live_content = material.markdown.present?

    material.assign_attributes(
      website_source: source,
      file_source: nil,
      source_kind: 'website',
      title: page[:title],
      public_url: page.fetch(:public_url),
      markdown: page.fetch(:markdown),
      content_hash: page.fetch(:content_hash),
      authority_class: page.fetch(:authority_class),
      metadata: page.fetch(:metadata),
      risk_flags: page.fetch(:risk_flags),
      extracted_at: Time.current,
      status: replacing_live_content ? 'updating' : 'processing',
      deleted_at: nil
    )
    material.save!
  end

  def firecrawl
    @firecrawl ||= ChatRing::Knowledge::FirecrawlClient.new(api_key: ENV.fetch('FIRECRAWL_API_KEY'))
  end
end
