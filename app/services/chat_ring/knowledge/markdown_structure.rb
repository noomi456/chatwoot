require 'uri'

class ChatRing::Knowledge::MarkdownStructure
  MAX_HEADINGS = 200
  MAX_CTA_CANDIDATES = 20
  MAX_LABEL_LENGTH = 120
  MAX_URL_LENGTH = 2048
  HEADING = /\A(\#{1,6})\s+(.+?)\s*\z/
  LINK = /(?<!!)\[(?<label>[^\]\n]{1,200})\]\((?<destination><[^>]+>|[^)\s]+)(?:\s+["'][^)]*["'])?\)/
  CTA_LABEL = /\b(?:book|demo|start|trial|talk|contact|schedule|get started|sign up|try|whats\s*app)\b/i
  CTA_DESTINATION = %r{(?:/signup(?:[/?#]|\z)|#book-demo\z|calendar\.google\.com/calendar/appointments|wa\.me/)}i

  class Error < StandardError; end

  def initialize(markdown:, source_url:)
    @markdown = markdown.to_s
    @source_uri = parse_source_uri(source_url)
  end

  def call # rubocop:disable Metrics/CyclomaticComplexity
    headings = []
    candidates = []
    heading_stack = []

    @markdown.each_line do |line|
      if (match = HEADING.match(line.strip))
        heading_stack = update_heading_stack(heading_stack, match)
        headings << heading_record(match, heading_stack) if headings.length < MAX_HEADINGS
      end
      next if candidates.length >= MAX_CTA_CANDIDATES

      extract_links(line, heading_stack).each do |candidate|
        candidates << candidate unless candidates.any? { |existing| same_candidate?(existing, candidate) }
        break if candidates.length >= MAX_CTA_CANDIDATES
      end
    end

    {
      'headings' => headings.freeze,
      'cta_candidates' => candidates.freeze
    }.freeze
  end

  private

  def parse_source_uri(value)
    uri = URI.parse(value.to_s)
    raise Error, 'source_url must use http or https' unless uri.is_a?(URI::HTTP) && uri.host.present?

    uri
  rescue URI::Error
    raise Error, 'source_url is invalid'
  end

  def update_heading_stack(stack, match)
    level = match[1].length
    stack.take_while { |entry| entry.fetch(:level) < level }.push({ level: level, text: clean_text(match[2]) })
  end

  def heading_record(match, stack)
    {
      'level' => match[1].length,
      'text' => clean_text(match[2]),
      'path' => heading_path(stack)
    }.freeze
  end

  def extract_links(line, heading_stack)
    line.to_enum(:scan, LINK).filter_map do
      match = Regexp.last_match
      label = clean_text(match[:label]).truncate(MAX_LABEL_LENGTH, omission: '')
      url = normalize_url(match[:destination])
      next if label.blank? || url.blank?
      next unless CTA_LABEL.match?(label) || CTA_DESTINATION.match?(url)

      {
        'label' => label,
        'url' => url,
        'heading_path' => heading_path(heading_stack).presence,
        'external' => external?(URI.parse(url))
      }.compact.freeze
    end
  end

  def normalize_url(value)
    raw = value.to_s.delete_prefix('<').delete_suffix('>')
    uri = URI.join(@source_uri.to_s, raw)
    return if !uri.is_a?(URI::HTTP) || uri.host.blank? || uri.userinfo.present? || uri.to_s.length > MAX_URL_LENGTH

    uri.fragment = uri.fragment.presence
    uri.to_s
  rescue URI::Error
    nil
  end

  def external?(uri)
    [uri.scheme.downcase, uri.host.downcase, uri.port] != [@source_uri.scheme.downcase, @source_uri.host.downcase, @source_uri.port]
  end

  def clean_text(value)
    value.to_s.gsub(/[`*_]/, '').gsub('\\_', '_').squish
  end

  def heading_path(stack)
    stack.pluck(:text).join(' > ')
  end

  def same_candidate?(left, right)
    left.fetch('label').casecmp?(right.fetch('label')) &&
      left.fetch('url') == right.fetch('url') &&
      left['heading_path'] == right['heading_path']
  end
end
