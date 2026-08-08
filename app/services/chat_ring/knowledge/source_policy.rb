require 'digest'
require 'uri'

class ChatRing::Knowledge::SourcePolicy
  VERSION = 4
  MAX_CORPUS_BYTES = 50.megabytes
  MIN_MEANINGFUL_CHARACTERS = 80

  # These routes are excluded before paid extraction because they are
  # operational or boilerplate, not business knowledge. Content categories
  # such as blogs, careers, security, and non-English pages remain selectable.
  EXCLUDED_PATHS = %r{\A/(?:
    auth|login|log-in|sign[-_]?in|sign[-_]?up|register|admin|account|cart|checkout|search|unsubscribe|
    sitemaps?(?:\.xml)?|robots\.txt|404|privacy(?:-policy)?|cookie(?:-policy|s)?|
    terms(?:-of-(?:service|use))?|legal
  )(?:/|\z)}ix
  NESTED_POLICY_PATHS = %r{/(?:legal|polic(?:y|ies))/(?:privacy(?:-policy)?|cookie(?:-policy|s)?|terms(?:-of-(?:service|use))?)(?:/|\z)}i
  USELESS_PAGE_TITLE = /\A\s*(?:privacy policy|cookie policy|terms (?:of service|of use)|sign in|log in|sign up|register|sitemap)\b/i
  SOFT_404 = /\b(?:page not found|404 not found|this page (?:does not|doesn't) exist)\b/i
  PROMPT_INJECTION = /\b(?:ignore (?:all |any )?(?:previous|prior) instructions|
    reveal (?:the )?system prompt|you are now (?:a|an)|developer message:)\b/ix

  class Error < StandardError; end
  class OriginError < Error; end
  class PageQualityError < Error; end

  def initialize(root_url:)
    @root_url = ChatRing::Knowledge::FirecrawlClient.canonical_url(root_url)
    @origin = origin(URI.parse(@root_url))
  end

  def prepare_manifest(entries)
    raise Error, 'Firecrawl map must return an array' unless entries.is_a?(Array)

    entries.map do |entry|
      normalized = entry.to_h.deep_stringify_keys
      url = ChatRing::Knowledge::FirecrawlClient.canonical_url(normalized.fetch('url'))
      enforce_origin!(url)
      excluded = excluded_before_scrape?(URI.parse(url).path, normalized)
      normalized.merge(
        'url' => url,
        'included' => !excluded,
        'exclusion_reason' => excluded ? 'non_knowledge_route' : nil,
        'authority_class' => authority_class(URI.parse(url).path)
      ).compact
    end.uniq { |entry| entry.fetch('url') }.sort_by { |entry| entry.fetch('url') }
  end

  # A failed page does not discard successful pages. The caller displays each
  # failure and indexes only the pages Firecrawl actually returned safely.
  def normalize_pages_with_errors(records:, manifest:)
    raise PageQualityError, 'Firecrawl scrape data must be an array' unless records.is_a?(Array)

    allowed = manifest.select { |entry| entry['included'] }.index_by { |entry| entry.fetch('url') }
    pages = []
    errors = []
    records.each do |record|
      pages << normalize_page(record, allowed)
    rescue PageQualityError, OriginError => e
      errors << { 'url' => page_url(record), 'error' => e.message }.compact
    end
    returned_urls = pages.pluck(:source_reference)
    (allowed.keys - returned_urls).each do |url|
      errors << { 'url' => url, 'error' => 'Firecrawl did not return this selected page' }
    end
    total_bytes = pages.sum { |page| page.fetch(:markdown).bytesize }
    raise PageQualityError, "Accepted corpus exceeds #{MAX_CORPUS_BYTES} bytes" if total_bytes > MAX_CORPUS_BYTES

    [pages.sort_by { |page| page.fetch(:source_reference) }, errors]
  end

  def normalize_pages(records:, manifest:)
    pages, errors = normalize_pages_with_errors(records: records, manifest: manifest)
    raise PageQualityError, errors.map { |error| error['error'] }.join('; ') if errors.any?

    pages
  end

  private

  def normalize_page(record, allowed) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    raise PageQualityError, 'Firecrawl page must be an object' unless record.is_a?(Hash)

    metadata = record['metadata'].is_a?(Hash) ? record['metadata'] : {}
    source_url = ChatRing::Knowledge::FirecrawlClient.canonical_url(
      metadata['sourceURL'] || metadata['url'] || record['url']
    )
    enforce_origin!(source_url)
    manifest_entry = allowed[source_url]
    raise PageQualityError, "Firecrawl returned an unselected URL #{source_url}" if manifest_entry.blank?

    status = integer_status(metadata['statusCode'])
    raise PageQualityError, "Firecrawl page #{source_url} returned HTTP #{status}" unless status.between?(200, 299)

    markdown = record['markdown'].to_s.strip
    title = metadata['title'].to_s.strip
    if markdown.length < MIN_MEANINGFUL_CHARACTERS || SOFT_404.match?(title) || SOFT_404.match?(markdown.first(500))
      raise PageQualityError, "Firecrawl page #{source_url} did not contain usable knowledge"
    end

    structure = ChatRing::Knowledge::MarkdownStructure.new(markdown: markdown, source_url: source_url).call
    {
      source_kind: 'website',
      source_reference: source_url,
      public_url: source_url,
      title: title.presence,
      markdown: markdown,
      content_hash: Digest::SHA256.hexdigest(markdown),
      authority_class: manifest_entry.fetch('authority_class'),
      risk_flags: PROMPT_INJECTION.match?(markdown) ? ['possible_prompt_injection'] : [],
      metadata: metadata.slice('title', 'description', 'language', 'statusCode', 'sourceURL', 'contentType').merge(
        'headings' => structure.fetch('headings'),
        'cta_candidates' => structure.fetch('cta_candidates')
      )
    }
  rescue ChatRing::Knowledge::FirecrawlClient::ConfigurationError => e
    raise PageQualityError, e.message
  end

  def page_url(record)
    metadata = record.is_a?(Hash) && record['metadata'].is_a?(Hash) ? record['metadata'] : {}
    metadata['sourceURL'] || metadata['url'] || (record.is_a?(Hash) ? record['url'] : nil)
  end

  def excluded_before_scrape?(path, entry)
    EXCLUDED_PATHS.match?(path) || NESTED_POLICY_PATHS.match?(path) || USELESS_PAGE_TITLE.match?(entry['title'].to_s)
  end

  def authority_class(path)
    return 'product_documentation' if path.match?(%r{/(?:docs|help)(?:/|\z)}i)
    return 'structured_commercial' if path.match?(%r{/(?:pricing|plans)(?:/|\z)}i)

    'marketing'
  end

  def enforce_origin!(value)
    candidate = URI.parse(value)
    return if origin(candidate) == @origin

    raise OriginError, "Mapped URL is outside the configured origin: #{value}"
  end

  def origin(uri)
    [uri.scheme.downcase, uri.host.downcase, uri.port]
  end

  def integer_status(value)
    Integer(value)
  rescue ArgumentError, TypeError
    raise PageQualityError, 'Firecrawl page is missing a numeric statusCode'
  end
end
