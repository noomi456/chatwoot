require 'digest'

class ChatRing::Knowledge::FileSnapshotNormalizer
  MIN_MEANINGFUL_CHARACTERS = 80
  BASE64_IMAGE = %r{!\[[^\]]*\]\(data:image/[^;)]+;base64,[^)]+\)}i
  PROMPT_INJECTION = /(?:
    \bignore\s+(?:all\s+|any\s+)?(?:previous|prior)\s+instructions\b|
    \breveal\s+(?:the\s+)?system\s+prompt\b|
    \byou\s+are\s+now\s+(?:a|an)\b|
    \bdeveloper\s+message\s*:
  )/ix
  TABLE_SEPARATOR = /^\s*\|?(?:\s*:?-{3,}:?\s*\|)+(?:\s*:?-{3,}:?\s*)\|?\s*$/
  METADATA_KEYS = %w[title description language sourceFile numPages totalPages contentType].freeze

  class Error < StandardError; end

  def self.call(source:, payload:, preflight:)
    new(source: source, payload: payload, preflight: preflight).call
  end

  def initialize(source:, payload:, preflight:)
    @source = source
    @payload = payload.deep_stringify_keys
    @preflight = preflight
  end

  def call
    markdown = normalized_markdown
    metadata = @payload.fetch('metadata', {}).slice(*METADATA_KEYS)
    structure = ChatRing::Knowledge::MarkdownStructure.new(markdown: markdown).call

    {
      markdown: markdown,
      content_hash: Digest::SHA256.hexdigest(markdown),
      metadata: metadata.merge(
        @preflight.metadata,
        'authority_class' => @source.authority_class,
        'risk_flags' => PROMPT_INJECTION.match?(markdown) ? ['possible_prompt_injection'] : [],
        'headings' => structure.fetch('headings'),
        'cta_candidates' => structure.fetch('cta_candidates'),
        'table_count' => markdown.each_line.count { |line| TABLE_SEPARATOR.match?(line) }
      ),
      title: metadata['title'].to_s.squish.truncate(255).presence || @source.original_filename
    }
  end

  private

  def normalized_markdown
    markdown = @payload.fetch('markdown').to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
                       .gsub("\r\n", "\n")
                       .tr("\r", "\n")
                       .delete("\u0000")
                       .gsub(BASE64_IMAGE, '')
                       .strip
    raise Error, 'Parsed file contains too little meaningful content' if markdown.length < MIN_MEANINGFUL_CHARACTERS
    if markdown.bytesize > ChatRing::KnowledgeDocument::MAX_MARKDOWN_LENGTH
      raise Error, "Parsed file exceeds #{ChatRing::KnowledgeDocument::MAX_MARKDOWN_LENGTH / 1.megabyte} MB of Markdown"
    end

    markdown
  end
end
