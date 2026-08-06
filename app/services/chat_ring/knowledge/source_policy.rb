require 'digest'
require 'uri'

class ChatRing::Knowledge::SourcePolicy
  MAX_CORPUS_BYTES = 50.megabytes
  MIN_MEANINGFUL_CHARACTERS = 80
  EXCLUDED_PATHS = %r{\A/(?:
    auth|login|sign[-_]?in|sign[-_]?up|register|sitemap|
    privacy(?:-policy)?|cookie(?:-policy|s)?|terms(?:-of-(?:service|use))?|legal|
    blog|news|changelog|careers?|jobs?|press
  )(?:/|\z)}ix
  SOFT_404 = /\b(?:page not found|404 not found|this page (?:does not|doesn't) exist)\b/i
  COOKIE_BANNER = /We use cookies to run the site, improve performance, and remember your choices\. You can change settings any time\./i
  DEMO_LINE = /\b(?:
    Sarah Connor|David Chen|Acme(?: Corp)?|Welcome back,? Alex|
    Unique Visitors|Engagement Rate|Leads Generated|Top Countries|Conversation Sentiment|
    High-intent buyer detected|Pricing intent|Calendar ready|CRM owner|AE assigned
  )\b/ix
  UNAPPROVED_COMPLIANCE_LINE = /\b(?:SOC\s*2|HIPAA|ISO\s*27001|end[- ]to[- ]end encrypt|data residency)\b/i
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

    normalized_entries = entries.map do |entry|
      normalized = entry.to_h.deep_stringify_keys
      url = ChatRing::Knowledge::FirecrawlClient.canonical_url(normalized.fetch('url'))
      enforce_origin!(url)
      path = URI.parse(url).path
      normalized.merge(
        'url' => url,
        'included' => !EXCLUDED_PATHS.match?(path),
        'exclusion_reason' => EXCLUDED_PATHS.match?(path) ? 'non_knowledge_route' : nil,
        'authority_class' => authority_class(path)
      ).compact
    end.uniq { |entry| entry.fetch('url') }.sort_by { |entry| entry.fetch('url') }

    exclude_redundant_help(normalized_entries)
  end

  def normalize_pages(records:, manifest:)
    raise PageQualityError, 'Firecrawl scrape data must be an array' unless records.is_a?(Array)

    allowed = manifest.select { |entry| entry['included'] }.index_by { |entry| entry.fetch('url') }
    pages = records.map { |record| normalize_page(record, allowed) }
    ensure_complete!(pages, allowed)
    deduplicated = deduplicate(pages)
    total_bytes = deduplicated.sum { |page| page.fetch(:markdown).bytesize }
    raise PageQualityError, "Accepted corpus exceeds #{MAX_CORPUS_BYTES} bytes" if total_bytes > MAX_CORPUS_BYTES

    deduplicated
  end

  private

  def normalize_page(record, allowed) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    raise PageQualityError, 'Firecrawl page must be an object' unless record.is_a?(Hash)

    metadata = record['metadata'].is_a?(Hash) ? record['metadata'] : {}
    source = metadata['sourceURL'] || metadata['url'] || record['url']
    raise PageQualityError, 'Firecrawl page is missing source URL' if source.blank?

    source_url = ChatRing::Knowledge::FirecrawlClient.canonical_url(source)
    enforce_origin!(source_url)
    manifest_entry = allowed[source_url]
    raise PageQualityError, "Firecrawl returned unrequested URL #{source_url}" if manifest_entry.blank?

    status = integer_status(metadata['statusCode'])
    raise PageQualityError, "Firecrawl page #{source_url} returned HTTP #{status}" unless status.between?(200, 299)

    content_type = metadata['contentType'].to_s
    if content_type.present? && !content_type.match?(%r{(?:text/html|text/markdown|application/xhtml\+xml)}i)
      raise PageQualityError, "Firecrawl page #{source_url} has unsupported content type #{content_type}"
    end
    language = metadata['language'].to_s.downcase
    raise PageQualityError, "Firecrawl page #{source_url} has unsupported language #{language}" if language.present? && language != 'en'

    markdown = clean_markdown(record['markdown'])
    title = metadata['title'].to_s.strip
    if markdown.length < MIN_MEANINGFUL_CHARACTERS || SOFT_404.match?(title) || SOFT_404.match?(markdown.first(500))
      raise PageQualityError, "Firecrawl page #{source_url} failed the meaningful-content gate"
    end
    raise PageQualityError, "Firecrawl page #{source_url} contains prompt-injection text" if PROMPT_INJECTION.match?(markdown)

    {
      source_url: source_url,
      title: title.presence,
      markdown: markdown,
      content_hash: Digest::SHA256.hexdigest(markdown),
      provider_file_name: "#{Digest::SHA256.hexdigest(source_url).first(24)}.md",
      metadata: metadata.slice('title', 'description', 'language', 'statusCode', 'sourceURL', 'contentType').merge(
        'authority_class' => manifest_entry.fetch('authority_class')
      )
    }
  end

  def clean_markdown(value)
    value.to_s.lines.reject do |line|
      COOKIE_BANNER.match?(line) || DEMO_LINE.match?(line) || UNAPPROVED_COMPLIANCE_LINE.match?(line)
    end.join.strip
  end

  def ensure_complete!(pages, allowed)
    duplicates = pages.group_by { |page| page.fetch(:source_url) }.select { |_url, rows| rows.length != 1 }
    raise PageQualityError, "Firecrawl returned duplicate accepted URLs: #{duplicates.keys.join(', ')}" if duplicates.any?

    missing = allowed.keys - pages.pluck(:source_url)
    raise PageQualityError, "Firecrawl omitted #{missing.length} accepted URL(s)" if missing.any?
  end

  def deduplicate(pages)
    pages.group_by { |page| page.fetch(:content_hash) }.values.map do |duplicates|
      duplicates.min_by { |page| duplicate_priority(page.fetch(:source_url)) }
    end.sort_by { |page| page.fetch(:source_url) }
  end

  def duplicate_priority(url)
    path = URI.parse(url).path
    return 0 if path.start_with?('/docs')
    return 2 if path.start_with?('/help')

    1
  end

  def exclude_redundant_help(entries)
    return entries unless entries.any? { |entry| URI.parse(entry.fetch('url')).path.start_with?('/docs') }

    entries.map do |entry|
      path = URI.parse(entry.fetch('url')).path
      next entry unless entry['included'] && path.match?(%r{\A/help(?:/|\z)}i)

      entry.merge('included' => false, 'exclusion_reason' => 'redundant_help_route')
    end
  end

  def authority_class(path)
    return 'product_documentation' if path.match?(%r{/(?:docs|help)(?:/|\z)}i)
    return 'structured_commercial' if path.match?(%r{/(?:pricing|plans)(?:/|\z)}i)
    return 'marketing' if path.match?(%r{/(?:blog|features?|security)(?:/|\z)}i)

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
