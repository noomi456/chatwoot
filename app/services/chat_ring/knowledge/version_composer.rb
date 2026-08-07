require 'digest'

# rubocop:disable Metrics/ClassLength
class ChatRing::Knowledge::VersionComposer
  FILE_SCORE_THRESHOLD = 0.31

  class Error < StandardError; end

  def self.compose!(account:, inbox:, base_version: nil, file_sources: [], **options)
    new(
      account: account,
      inbox: inbox,
      base_version: base_version,
      file_sources: file_sources,
      options: options
    ).compose!
  end

  def initialize(account:, inbox:, base_version:, file_sources:, options:)
    @account = account
    @inbox = inbox
    @base_version = base_version
    @file_sources = Array(file_sources).uniq(&:id).sort_by(&:id)
    @publish_on_ready = options.fetch(:publish_on_ready, false)
    @excluded_website_references = Array(options[:excluded_website_references]).to_set
  end

  def compose!
    validate_scope!
    version = ChatRing::KnowledgeVersion.transaction { build_version! }
    if version.documents.exists?
      ChatRing::Knowledge::SyncJob.perform_later(version.id)
    else
      ChatRing::Knowledge::PublicationService.clear!(account: @account, inbox: @inbox)
    end
    version
  end

  private

  def validate_scope!
    raise Error, 'Inbox does not belong to account' unless @inbox.account_id == @account.id
    raise Error, 'Select a base version, at least one ready file, or both' if @base_version.nil? && @file_sources.empty?
  end

  def lock_and_validate_sources!
    validate_base_version! if @base_version
    @file_sources.each { |source| validate_file_source!(source) }
  end

  def composed_manifest
    (base_manifest_entries + file_manifest_entries).sort_by do |entry|
      entry['url'].presence || entry.fetch('source_reference')
    end
  end

  def base_manifest_entries
    return [] unless @base_version

    @base_version.mapped_manifest.deep_dup.filter_map do |entry|
      next unless (entry['source_kind'].presence || 'website') == 'website'

      if @excluded_website_references.include?(entry['url'])
        entry.merge('included' => false, 'exclusion_reason' => 'administrator_removed')
      else
        entry
      end
    end
  end

  def file_manifest_entries
    @file_sources.map do |source|
      {
        'source_kind' => source.source_kind,
        'source_reference' => source.source_reference,
        'title' => source.metadata['title'].presence || source.original_filename,
        'included' => true,
        'authority_class' => source.authority_class,
        'content_hash' => source.content_hash,
        'parser_profile_digest' => source.parser_profile_digest
      }
    end
  end

  def copy_website_documents!(version)
    @base_version.documents.where(source_kind: 'website').where.not(source_reference: @excluded_website_references).find_each do |document|
      ChatRing::Knowledge::SyncService.verify_document_hash!(document)
      structure = ChatRing::Knowledge::MarkdownStructure.new(
        markdown: document.markdown,
        source_url: document.public_url
      ).call
      version.documents.create!(website_document_attributes(document, structure))
    end
  end

  def copy_file_documents!(version)
    @file_sources.each do |source|
      structure = ChatRing::Knowledge::MarkdownStructure.new(markdown: source.markdown).call
      version.documents.create!(file_document_attributes(source, structure))
    end
  end

  def build_version!
    lock_and_validate_sources!
    validate_corpus_size!
    version = ChatRing::KnowledgeVersion.create!(version_attributes)
    version.update!(manifest_digest: Digest::SHA256.hexdigest(version.reload.mapped_manifest.to_json))
    copy_website_documents!(version) if @base_version
    copy_file_documents!(version)
    version.update!(status: 'ready', ready_at: Time.current) unless version.documents.exists?

    version
  end

  def version_attributes
    {
      account: @account,
      inbox: @inbox,
      status: 'ingesting',
      root_url: @base_version&.root_url,
      provider: 'docs_gpt',
      provider_release: provider_release,
      config_snapshot: composed_config_snapshot,
      mapped_manifest: composed_manifest,
      manifest_digest: nil,
      crawl_errors: @base_version&.crawl_errors || []
    }
  end

  def composed_config_snapshot
    snapshot = ChatRing::Knowledge::SyncService.configuration_snapshot
    snapshot['retrieval']['score_threshold'] = FILE_SCORE_THRESHOLD if @file_sources.any?
    snapshot.merge(
      'build_mode' => empty_composition? ? 'empty_sources' : 'composed_sources',
      'source_knowledge_version_id' => @base_version&.id,
      'file_source_keys' => @file_sources.map(&:source_key).sort,
      'publish_on_ready' => @publish_on_ready
    ).compact
  end

  def provider_release
    ENV.fetch('DOCSGPT_RELEASE', @base_version&.provider_release || '616e6fe9c435bbc6bb472636db6b3ee2b9bcaf66')
  end

  def validate_base_version!
    @base_version.lock!
    unless @base_version.account_id == @account.id && @base_version.inbox_id == @inbox.id
      raise Error, 'Base version does not belong to the selected account and inbox'
    end
    raise Error, 'Base version must be complete before composition' unless valid_base_version?

    ChatRing::Knowledge::SyncService.verify_manifest_digest!(@base_version)
  end

  def valid_base_version?
    return false unless %w[ready published retired].include?(@base_version.status)

    @base_version.documents.exists? || @base_version.config_snapshot['build_mode'] == 'empty_sources'
  end

  def empty_composition?
    @file_sources.empty? && (@base_version.nil? ||
      @base_version.documents.where(source_kind: 'website').where.not(source_reference: @excluded_website_references).none?)
  end

  def validate_file_source!(source)
    source.lock!
    unless source.account_id == @account.id && source.inbox_id == @inbox.id
      raise Error, 'File source does not belong to the selected account and inbox'
    end
    raise Error, "File source #{source.original_filename} is not ready" unless source.status == 'ready'

    verify_file_source!(source)
  end

  def website_document_attributes(document, structure)
    {
      source_kind: document.source_kind,
      source_reference: document.source_reference,
      source_url: document.source_url,
      public_url: document.public_url,
      title: document.title,
      markdown: document.markdown,
      content_hash: document.content_hash,
      provider_file_name: document.provider_file_name,
      metadata: document.metadata.merge(structure),
      provider_status: 'pending'
    }
  end

  def file_document_attributes(source, structure)
    {
      source_kind: source.source_kind,
      source_reference: source.source_reference,
      public_url: nil,
      file_source: source,
      title: source.metadata['title'].presence || source.original_filename,
      markdown: source.markdown,
      content_hash: source.content_hash,
      provider_file_name: provider_file_name(source),
      metadata: source.metadata.merge(structure, file_source_metadata(source)),
      provider_status: 'pending'
    }
  end

  def file_source_metadata(source)
    {
      'authority_class' => source.authority_class,
      'original_filename' => source.original_filename,
      'raw_content_hash' => source.raw_content_hash,
      'parser_profile_digest' => source.parser_profile_digest
    }
  end

  def provider_file_name(source)
    "#{source.source_kind}-#{source.raw_content_hash.first(20)}-#{source.parser_profile_digest.first(8)}.md"
  end

  def validate_corpus_size!
    total_bytes = website_corpus_bytes + file_corpus_bytes
    return if total_bytes <= ChatRing::Knowledge::SourcePolicy::MAX_CORPUS_BYTES

    raise Error, "Combined knowledge corpus exceeds #{ChatRing::Knowledge::SourcePolicy::MAX_CORPUS_BYTES} bytes"
  end

  def website_corpus_bytes
    return 0 unless @base_version

    @base_version.documents.where(source_kind: 'website')
                 .where.not(source_reference: @excluded_website_references)
                 .sum { |document| document.markdown.bytesize }
  end

  def file_corpus_bytes
    @file_sources.sum { |source| source.markdown.to_s.bytesize }
  end

  def verify_file_source!(source)
    actual = Digest::SHA256.hexdigest(source.markdown.to_s)
    raise Error, "File source #{source.original_filename} does not match its content hash" unless actual == source.content_hash
    raise Error, "File source #{source.original_filename} has no private attachment" unless source.file.attached?
  end
end
# rubocop:enable Metrics/ClassLength
