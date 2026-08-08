class ChatRing::Knowledge::WebsiteExtractionJob < ApplicationJob # rubocop:disable Metrics/ClassLength
  queue_as :default

  EXTRACTION_DEADLINE = 30.minutes
  REQUEST_CLAIM_TIMEOUT = 2.minutes

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  def perform(source_id, requested_urls, force_fresh, extraction_mode = 'batch', extraction_token = nil)
    source = ChatRing::KnowledgeWebsiteSource.find_by(id: source_id)
    return if source.nil?

    action = claim_action(source, extraction_token, extraction_mode)
    return if action == :ignore

    if action == :wait
      enqueue_poll(source_id, requested_urls, force_fresh, extraction_mode, extraction_token)
      return
    end

    if extraction_mode == 'single'
      requested_url = requested_urls.fetch(0)
      page = firecrawl.scrape(url: requested_url, max_age: force_fresh ? 0 : nil)
      material = source.materials.find_by(source_reference: requested_url)
      manifest = [
        {
          'url' => requested_url,
          'included' => true,
          'authority_class' => material&.authority_class || 'product_documentation'
        }
      ]
      apply_results!(source, { 'data' => [page] }, extraction_token: extraction_token,
                                                   provider_errors: {}, manifest: manifest)
      return
    end

    raise ArgumentError, "Unknown website extraction mode: #{extraction_mode}" unless extraction_mode == 'batch'

    if action == :start
      crawl_id = firecrawl.start_batch_scrape(urls: requested_urls, max_age: force_fresh ? 0 : nil)
      crawl_stored = source.with_lock do
        next false unless source.extraction_token == extraction_token

        source.update!(firecrawl_crawl_id: crawl_id)
        true
      end
      return unless crawl_stored

      enqueue_poll(source_id, requested_urls, force_fresh, extraction_mode, extraction_token)
      return
    end

    payload = firecrawl.batch_status(source.firecrawl_crawl_id)
    status = payload['status'].to_s
    if %w[scraping pending].include?(status)
      enqueue_poll(source_id, requested_urls, force_fresh, extraction_mode, extraction_token)
      return
    end
    raise ChatRing::Knowledge::FirecrawlClient::ResponseError, "Firecrawl extraction ended with status #{status}" unless status == 'completed'

    apply_results!(source, payload, extraction_token: extraction_token)
  rescue ChatRing::Knowledge::FirecrawlClient::RequestError,
         ChatRing::Knowledge::FirecrawlClient::ResponseError,
         ChatRing::Knowledge::SourcePolicy::Error => e
    self.class.send(:mark_failed, source, e, extraction_token) if source
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  def self.mark_failed(source, error, extraction_token)
    ChatRing::KnowledgeMaterial.transaction do
      source.knowledge_base.lock!
      source.lock!
      next unless source.extraction_token == extraction_token

      source.materials.active.where(status: %w[processing updating]).find_each do |material|
        material.update!(status: material.markdown.present? ? 'refresh_failed' : 'failed')
      end
      source.update!(
        status: source.materials.retrievable.exists? ? 'refresh_failed' : 'failed',
        failure_code: error.class.name,
        failure_message: error.message.to_s.truncate(1000),
        firecrawl_crawl_id: nil,
        firecrawl_request_started_at: nil,
        extraction_started_at: nil,
        extraction_token: nil
      )
    end
  end
  private_class_method :mark_failed

  private

  # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def claim_action(source, extraction_token, extraction_mode)
    source.with_lock do
      next :ignore if source.status == 'deleted'
      next :ignore unless extraction_token.present? && source.extraction_token == extraction_token
      next :ignore unless %w[extracting refreshing].include?(source.status)
      if source.extraction_started_at.blank? || source.extraction_started_at < EXTRACTION_DEADLINE.ago
        raise ChatRing::Knowledge::FirecrawlClient::ResponseError, 'Firecrawl extraction exceeded its 30 minute deadline'
      end
      next :poll if source.firecrawl_crawl_id.present?

      if source.firecrawl_request_started_at.present?
        if source.firecrawl_request_started_at < REQUEST_CLAIM_TIMEOUT.ago
          raise ChatRing::Knowledge::FirecrawlClient::ResponseError,
                'The Firecrawl request outcome is unknown; use Re-run to request a fresh extraction'
        end
        next :wait
      end

      source.update!(firecrawl_request_started_at: Time.current)
      extraction_mode == 'single' ? :start_single : :start
    end
  end
  # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  def enqueue_poll(source_id, requested_urls, force_fresh, extraction_mode, extraction_token)
    job = self.class.set(wait: ChatRing::Knowledge::SyncService::POLL_INTERVAL)
              .perform_later(source_id, requested_urls, force_fresh, extraction_mode, extraction_token)
    return if job.successfully_enqueued?

    raise ChatRing::Knowledge::FirecrawlClient::RequestError, 'Website extraction polling could not be queued'
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  def apply_results!(source, payload, extraction_token:, provider_errors: nil, manifest: source.mapped_manifest)
    policy = ChatRing::Knowledge::SourcePolicy.new(root_url: source.root_url)
    pages, page_errors = policy.normalize_pages_with_errors(
      records: payload.fetch('data', []),
      manifest: manifest
    )
    provider_errors ||= best_effort_batch_errors(source.firecrawl_crawl_id)

    applied = false
    ChatRing::KnowledgeMaterial.transaction do
      source.knowledge_base.lock!
      source.lock!
      next unless source.extraction_token == extraction_token

      pages.each { |page| upsert_page!(source, page) }
      successful_references = pages.pluck(:source_reference).to_set
      source.materials.active.where(status: %w[processing updating]).find_each do |material|
        next if successful_references.include?(material.source_reference)

        material.update!(status: material.markdown.present? ? 'refresh_failed' : 'failed')
      end
      source.update!(
        status: if pages.any?
                  'available'
                else
                  (source.materials.retrievable.exists? ? 'refresh_failed' : 'failed')
                end,
        crawl_errors: {
          'pages' => page_errors,
          'provider' => Array(provider_errors['errors']).first(100),
          'robots_blocked' => Array(provider_errors['robotsBlocked']).first(100)
        },
        last_processed_at: Time.current,
        firecrawl_crawl_id: nil,
        firecrawl_request_started_at: nil,
        extraction_started_at: nil,
        extraction_token: nil,
        failure_code: pages.empty? ? 'no_pages_extracted' : nil,
        failure_message: pages.empty? ? 'Firecrawl returned no usable requested pages' : nil
      )
      applied = true
    end
    enqueue_index!(source, pages) if applied && pages.any?
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

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

  def enqueue_index!(source, pages)
    ChatRing::Knowledge::IndexBuilder.enqueue!(source.knowledge_base)
  rescue StandardError => e
    ChatRing::KnowledgeMaterial.transaction do
      source.knowledge_base.lock!
      source.lock!
      pages.each do |page|
        material = source.materials.find_by(source_reference: page.fetch(:source_reference))
        next if material.blank? || !material.active?

        material.update!(status: source.knowledge_base.material_available?(material) ? 'refresh_failed' : 'failed')
      end
      source.update!(status: source.materials.retrievable.exists? ? 'refresh_failed' : 'failed',
                     failure_code: e.class.name, failure_message: 'Knowledge indexing could not be queued')
    end
    raise
  end

  def firecrawl
    @firecrawl ||= ChatRing::Knowledge::FirecrawlClient.new(api_key: ENV.fetch('FIRECRAWL_API_KEY'))
  end

  def best_effort_batch_errors(crawl_id)
    return {} if crawl_id.blank?

    firecrawl.batch_errors(crawl_id)
  rescue ChatRing::Knowledge::FirecrawlClient::Error => e
    Rails.error.report(e, handled: true, context: { firecrawl_crawl_id: crawl_id })
    {}
  end
end
