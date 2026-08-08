class ChatRing::Knowledge::FileParseService
  class Error < StandardError; end

  def initialize(source, client: nil)
    @source = source
    @client = client || ChatRing::Knowledge::FirecrawlParseClient.new(api_key: ENV.fetch('FIRECRAWL_API_KEY'))
  end

  def call # rubocop:disable Metrics/MethodLength
    return :complete unless claim!

    @source.file.blob.open do |file|
      preflight = verify_stored_file!(file)
      payload = @client.parse(
        path: file.path,
        filename: @source.original_filename,
        content_type: @source.content_type,
        source_kind: @source.source_kind,
        profile: @source.parser_profile
      )
      normalized = ChatRing::Knowledge::FileSnapshotNormalizer.call(source: @source, payload: payload, preflight: preflight)
      finalize!(normalized)
    end
    :complete
  rescue ChatRing::Knowledge::FirecrawlParseClient::RequestError => e
    record_failure!(e)
    :complete
  rescue ChatRing::Knowledge::FirecrawlParseClient::ResponseError, ChatRing::Knowledge::FilePreflight::Error,
         ChatRing::Knowledge::FileSnapshotNormalizer::Error => e
    record_failure!(e)
    :complete
  rescue StandardError => e
    record_failure!(e)
    Rails.error.report(e, handled: true, context: { knowledge_file_source_id: @source.id })
    :complete
  end

  # Re-run always makes a new Firecrawl Parse request, even when the bytes are
  # identical. The old material remains active until this call succeeds.
  def self.rerun!(source)
    ChatRing::KnowledgeMaterial.transaction do
      source.knowledge_base.lock!
      source.lock!
      raise Error, 'Deleted files must be uploaded again, not re-run' if source.status == 'deleted'
      raise Error, 'Another parse is already running' if %w[parsing refreshing].include?(source.status)
      raise Error, 'Knowledge file attachment is missing' unless source.file.attached?

      source.update!(
        status: source.materials.retrievable.exists? ? 'refreshing' : 'uploaded',
        parse_started_at: nil,
        failure_code: nil,
        failure_message: nil
      )
      source.materials.active.find_each do |material|
        material.update!(status: material.markdown.present? ? 'updating' : 'processing')
      end
    end
    ChatRing::Knowledge::FileParseJob.perform_later(source.id)
    source
  end

  def self.restore_material!(source)
    raise Error, 'Only a parsed file can be restored' unless source.status == 'ready' && source.markdown.present?

    ChatRing::KnowledgeMaterial.transaction do
      source.knowledge_base.lock!
      source.lock!
      upsert_material!(source)
    end
    ChatRing::Knowledge::IndexBuilder.enqueue!(source.knowledge_base)
    source
  end

  def self.upsert_material!(source)
    material = source.knowledge_base.materials.find_or_initialize_by(source_reference: source.source_reference)
    replacing_live_content = material.markdown.present?
    material.assign_attributes(
      website_source: nil,
      file_source: source,
      source_kind: source.source_kind,
      title: source.metadata['title'].presence || source.original_filename,
      public_url: nil,
      markdown: source.markdown,
      content_hash: source.content_hash,
      authority_class: source.authority_class,
      metadata: source.metadata,
      risk_flags: Array(source.metadata['risk_flags']),
      extracted_at: source.parsed_at,
      status: replacing_live_content ? 'updating' : 'processing',
      deleted_at: nil
    )
    material.save!
    material
  end

  private

  def claim!
    claimed = false
    @source.with_lock do
      next unless %w[uploaded refreshing].include?(@source.status)
      raise Error, 'Knowledge file attachment is missing' unless @source.file.attached?

      refreshing = @source.status == 'refreshing'
      @source.update!(
        status: refreshing ? 'refreshing' : 'parsing',
        parse_started_at: Time.current,
        failure_code: nil,
        failure_message: nil
      )
      claimed = true
    end
    claimed
  end

  def verify_stored_file!(file)
    preflight = ChatRing::Knowledge::FilePreflight.call(
      io: file,
      filename: @source.original_filename,
      declared_content_type: @source.content_type
    )
    unless preflight.content_hash == @source.raw_content_hash &&
           preflight.byte_size == @source.byte_size &&
           preflight.source_kind == @source.source_kind
      raise ChatRing::Knowledge::FilePreflight::Error, 'Stored knowledge file no longer matches its identity'
    end
    preflight
  end

  def finalize!(normalized)
    ChatRing::KnowledgeMaterial.transaction do
      @source.knowledge_base.lock!
      @source.lock!
      unless %w[parsing refreshing].include?(@source.status)
        raise Error, 'Knowledge file parse was superseded before finalization'
      end

      @source.update!(
        status: 'ready',
        markdown: normalized.fetch(:markdown),
        content_hash: normalized.fetch(:content_hash),
        metadata: normalized.fetch(:metadata).merge('title' => normalized.fetch(:title)),
        parsed_at: Time.current,
        failure_code: nil,
        failure_message: nil
      )
      self.class.upsert_material!(@source)
    end
    ChatRing::Knowledge::IndexBuilder.enqueue!(@source.knowledge_base)
  end

  def record_failure!(error)
    @source.reload if @source.has_changes_to_save?
    @source.with_lock do
      next if @source.status == 'deleted'

      has_live_snapshot = @source.materials.retrievable.exists?
      status = if has_live_snapshot
                 'refresh_failed'
               elsif error.is_a?(ChatRing::Knowledge::FirecrawlParseClient::RequestError) && error.indeterminate?
                 'parse_indeterminate'
               else
                 'failed'
               end
      @source.update!(
        status: status,
        failure_code: error.class.name,
        failure_message: error.message.to_s.truncate(1000)
      )
      @source.materials.active.find_each do |material|
        material.update!(status: material.markdown.present? ? 'refresh_failed' : 'failed')
      end
    end
  end
end
