class ChatRing::Knowledge::WebsiteSourceService
  class Error < StandardError; end

  def self.map!(account:, root_url:, actor: nil, firecrawl: nil)
    knowledge_base = ChatRing::KnowledgeBase.for_account!(account)
    canonical_root = ChatRing::Knowledge::FirecrawlClient.canonical_url(root_url)
    source = knowledge_base.website_sources.find_or_initialize_by(source_type: 'website', root_url: canonical_root)
    if source.persisted? && %w[extracting refreshing].include?(source.status)
      raise Error, 'Another extraction is already running for this website'
    end
    source.assign_attributes(status: 'mapping', deleted_at: nil, failure_code: nil, failure_message: nil)
    source.created_by ||= actor
    source.save!

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
  rescue ChatRing::Knowledge::FirecrawlClient::Error => e
    source&.update!(status: 'failed', failure_code: e.class.name, failure_message: e.message.to_s.truncate(1000))
    raise
  end

  def self.extract!(source:, selected_urls:)
    extraction_token = SecureRandom.uuid
    ChatRing::KnowledgeMaterial.transaction do
      source.knowledge_base.lock!
      source.lock!
      raise Error, 'Only a mapped website can extract selected pages' unless source.source_type == 'website'
      raise Error, 'Deleted website source cannot be extracted' if source.status == 'deleted'

      selected = selected_manifest(source, selected_urls)
      source.update!(
        status: 'extracting',
        extraction_token: extraction_token,
        firecrawl_crawl_id: nil,
        mapped_manifest: selected,
        crawl_errors: [],
        failure_code: nil,
        failure_message: nil
      )
      selected.select { |entry| entry['included'] }.each do |entry|
        material = source.knowledge_base.materials.find_or_initialize_by(source_reference: entry.fetch('url'))
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
    selected_urls = selected.select { |entry| entry['included'] }.pluck('url')
    ChatRing::Knowledge::WebsiteExtractionJob.perform_later(source.id, selected_urls, false, 'batch', extraction_token)
    source
  end

  # A single webpage is an explicit input. It is scraped directly and never
  # sent through Firecrawl Map.
  def self.add_webpage!(account:, url:, actor: nil)
    knowledge_base = ChatRing::KnowledgeBase.for_account!(account)
    canonical_url = ChatRing::Knowledge::FirecrawlClient.canonical_url(url)
    source = knowledge_base.website_sources.find_or_initialize_by(source_type: 'webpage', root_url: canonical_url)
    source.created_by ||= actor
    source.save! if source.new_record?

    extraction_token = SecureRandom.uuid
    ChatRing::KnowledgeMaterial.transaction do
      knowledge_base.lock!
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
        failure_message: nil
      )
      source.save!
      prepare_material!(source, canonical_url)
    end
    ChatRing::Knowledge::WebsiteExtractionJob.perform_later(source.id, [canonical_url], false, 'single', extraction_token)
    source
  end

  def self.rerun!(material)
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
        firecrawl_crawl_id: nil,
        crawl_errors: [],
        failure_code: nil,
        failure_message: nil
      )
      material.update!(status: material.markdown.present? ? 'updating' : 'processing')
    end
    ChatRing::Knowledge::WebsiteExtractionJob.perform_later(
      source.id, [material.source_reference], true, 'single', extraction_token
    )
    source
  end

  def self.prepare_material!(source, url)
    material = source.knowledge_base.materials.find_or_initialize_by(source_reference: url)
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

  def self.selected_manifest(source, selected_urls)
    selected = Array(selected_urls).map { |url| ChatRing::Knowledge::FirecrawlClient.canonical_url(url) }.uniq.to_set
    available = source.mapped_manifest.select { |entry| entry['included'] }.pluck('url').to_set
    invalid = selected - available
    raise Error, "Selected pages were not offered by the website map: #{invalid.to_a.join(', ')}" if invalid.any?
    raise Error, 'Select at least one mapped webpage' if selected.empty?

    source.mapped_manifest.map do |entry|
      next entry if entry['exclusion_reason'] == 'non_knowledge_route'

      entry.merge(
        'included' => selected.include?(entry['url']),
        'exclusion_reason' => selected.include?(entry['url']) ? nil : 'not_selected'
      ).compact
    end
  end
  private_class_method :selected_manifest

  def self.build_firecrawl
    ChatRing::Knowledge::FirecrawlClient.new(api_key: ENV.fetch('FIRECRAWL_API_KEY'))
  end
  private_class_method :build_firecrawl
end
