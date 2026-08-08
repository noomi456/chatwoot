class ChatRing::Knowledge::WebsiteSourceService
  class Error < StandardError; end

  def self.add_website!(account:, root_url:, actor: nil, firecrawl: nil)
    source = map!(account: account, root_url: root_url, actor: actor, firecrawl: firecrawl)
    extract_mapped!(source)
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  def self.map!(account:, root_url:, actor: nil, firecrawl: nil)
    knowledge_base = ChatRing::KnowledgeBase.for_account!(account)
    canonical_root = ChatRing::Knowledge::FirecrawlClient.canonical_url(root_url, preserve_query: false)
    source = nil
    ChatRing::KnowledgeWebsiteSource.transaction do
      knowledge_base.lock!
      source = knowledge_base.website_sources.find_or_initialize_by(source_type: 'website', root_url: canonical_root)
      source.lock! if source.persisted?
      if source.persisted? && %w[mapping mapped extracting refreshing].include?(source.status)
        raise Error, 'Another extraction is already running for this website'
      end

      source.assign_attributes(status: 'mapping', deleted_at: nil, failure_code: nil, failure_message: nil)
      source.created_by ||= actor
      source.save!
    end

    client = firecrawl || build_firecrawl
    mapped = client.map(url: canonical_root, limit: Integer(ENV.fetch('FIRECRAWL_MAP_LIMIT', 5000)))
    manifest = ChatRing::Knowledge::SourcePolicy.new(root_url: canonical_root).prepare_manifest(mapped)
    deleted_urls = knowledge_base.materials.where.not(deleted_at: nil).where(source_kind: 'website').pluck(:source_reference).to_set
    manifest = manifest.map do |entry|
      next entry unless deleted_urls.include?(entry.fetch('url'))

      entry.merge('included' => false, 'exclusion_reason' => 'previously_deleted')
    end
    source.update!(status: 'mapped', mapped_manifest: manifest, crawl_errors: [])
    source
  rescue ChatRing::Knowledge::FirecrawlClient::Error, ChatRing::Knowledge::SourcePolicy::Error => e
    source&.update!(status: 'failed', failure_code: e.class.name, failure_message: e.message.to_s.truncate(1000))
    raise
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  def self.extract_mapped!(source)
    extraction_token = SecureRandom.uuid
    manifest = nil
    ChatRing::KnowledgeMaterial.transaction do # rubocop:disable Metrics/BlockLength
      source.knowledge_base.lock!
      source.lock!
      raise Error, 'Only a mapped website can be extracted' unless source.source_type == 'website' && source.status == 'mapped'
      raise Error, 'Deleted website source cannot be extracted' if source.status == 'deleted'

      manifest = source.mapped_manifest
      raise Error, 'Firecrawl Map returned no usable webpages' unless manifest.any? { |entry| entry['included'] }

      source.update!(
        status: 'extracting',
        extraction_token: extraction_token,
        extraction_started_at: Time.current,
        firecrawl_request_started_at: nil,
        firecrawl_crawl_id: nil,
        crawl_errors: [],
        failure_code: nil,
        failure_message: nil
      )
      manifest.select { |entry| entry['included'] }.each do |entry|
        material = source.knowledge_base.materials.find_or_initialize_by(source_reference: entry.fetch('url'))
        material.material_key = SecureRandom.uuid if material.persisted? && !material.active?
        material.assign_attributes(
          website_source: source,
          file_source: nil,
          source_kind: 'website',
          title: entry['title'].presence || entry.fetch('url'),
          public_url: entry.fetch('url'),
          status: material.markdown.present? ? 'updating' : 'processing',
          authority_class: material.authority_class.presence || 'product_documentation',
          metadata: material.metadata || {},
          deleted_at: nil
        )
        material.save!
      end
    end
    urls_to_extract = manifest.select { |entry| entry['included'] }.pluck('url')
    enqueue_extraction!(source, urls_to_extract, false, 'batch', extraction_token)
    source
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  # A single webpage is an explicit input. It is scraped directly and never
  # sent through Firecrawl Map.
  def self.add_webpage!(account:, url:, actor: nil) # rubocop:disable Metrics/MethodLength
    knowledge_base = ChatRing::KnowledgeBase.for_account!(account)
    canonical_url = ChatRing::Knowledge::FirecrawlClient.canonical_url(url, preserve_query: true)
    existing_material = knowledge_base.materials.active.find_by(source_reference: canonical_url)
    return rerun!(existing_material) if existing_material

    extraction_token = SecureRandom.uuid
    source = nil
    ChatRing::KnowledgeMaterial.transaction do
      knowledge_base.lock!
      source = knowledge_base.website_sources.find_or_initialize_by(source_type: 'webpage', root_url: canonical_url)
      source.created_by ||= actor
      source.save! if source.new_record?
      source.lock!
      raise Error, 'Another extraction is already running for this webpage' if %w[extracting refreshing].include?(source.status)

      source.assign_attributes(
        status: 'extracting',
        extraction_token: extraction_token,
        mapped_manifest: [
          { 'url' => canonical_url, 'included' => true, 'authority_class' => 'product_documentation' }
        ],
        crawl_errors: [],
        deleted_at: nil,
        firecrawl_crawl_id: nil,
        failure_code: nil,
        failure_message: nil,
        extraction_started_at: Time.current,
        firecrawl_request_started_at: nil
      )
      source.save!
      prepare_material!(source, canonical_url)
    end
    enqueue_extraction!(source, [canonical_url], false, 'single', extraction_token)
    source
  end

  def self.rerun!(material) # rubocop:disable Metrics/MethodLength
    raise Error, 'Only webpages can be re-run through webpage extraction' unless material.source_kind == 'website'
    raise Error, 'Deleted material cannot be re-run; add the page again instead' unless material.active?

    source = material.website_source
    extraction_token = SecureRandom.uuid
    ChatRing::KnowledgeMaterial.transaction do
      source.knowledge_base.lock!
      source.lock!
      raise Error, 'Another extraction is already running for this website' if %w[extracting refreshing].include?(source.status)

      source.update!(
        status: 'refreshing',
        extraction_token: extraction_token,
        extraction_started_at: Time.current,
        firecrawl_request_started_at: nil,
        firecrawl_crawl_id: nil,
        crawl_errors: [],
        failure_code: nil,
        failure_message: nil
      )
      material.update!(status: material.markdown.present? ? 'updating' : 'processing')
    end
    enqueue_extraction!(source, [material.source_reference], true, 'single', extraction_token)
    source
  end

  def self.prepare_material!(source, url)
    material = source.knowledge_base.materials.find_or_initialize_by(source_reference: url)
    material.material_key = SecureRandom.uuid if material.persisted? && !material.active?
    material.assign_attributes(
      website_source: source,
      file_source: nil,
      source_kind: 'website',
      title: material.title.presence || url,
      public_url: url,
      status: material.markdown.present? ? 'updating' : 'processing',
      authority_class: material.authority_class.presence || 'product_documentation',
      metadata: material.metadata || {},
      deleted_at: nil
    )
    material.save!
  end
  private_class_method :prepare_material!

  def self.build_firecrawl
    ChatRing::Knowledge::FirecrawlClient.new(api_key: ENV.fetch('FIRECRAWL_API_KEY'))
  end
  private_class_method :build_firecrawl

  def self.enqueue_extraction!(source, urls, force_fresh, mode, extraction_token)
    job = ChatRing::Knowledge::WebsiteExtractionJob.perform_later(source.id, urls, force_fresh, mode, extraction_token)
    raise Error, 'Website extraction could not be queued' unless job.successfully_enqueued?
  rescue StandardError => e
    ChatRing::KnowledgeMaterial.transaction do
      source.knowledge_base.lock!
      source.lock!
      source.materials.active.where(status: %w[processing updating]).find_each do |material|
        material.update!(status: material.markdown.present? ? 'refresh_failed' : 'failed')
      end
      source.update!(status: source.materials.retrievable.exists? ? 'refresh_failed' : 'failed',
                     extraction_token: nil, extraction_started_at: nil,
                     failure_code: e.class.name, failure_message: 'Website extraction could not be queued')
    end
    raise
  end
  private_class_method :enqueue_extraction!
end
