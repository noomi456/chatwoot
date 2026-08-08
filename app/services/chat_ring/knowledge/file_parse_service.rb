class ChatRing::Knowledge::FileParseService # rubocop:disable Metrics/ClassLength
  PARSE_STALE_AFTER = 15.minutes

  class Error < StandardError; end

  def initialize(source, client: nil, parse_token: nil)
    @source = source
    @client = client || ChatRing::Knowledge::FirecrawlParseClient.new(api_key: ENV.fetch('FIRECRAWL_API_KEY'))
    @parse_token = parse_token.presence
  end

  def call # rubocop:disable Metrics/MethodLength
    return :complete if @parse_token.blank?
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
  rescue ChatRing::Knowledge::FirecrawlParseClient::RequestError,
         ChatRing::Knowledge::FirecrawlParseClient::ResponseError, ChatRing::Knowledge::FilePreflight::Error,
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
  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  def self.rerun!(source)
    parse_token = SecureRandom.uuid
    ChatRing::KnowledgeMaterial.transaction do
      source.knowledge_base.lock!
      source.lock!
      raise Error, 'Deleted files must be uploaded again, not re-run' if source.status == 'deleted'
      if %w[parsing refreshing].include?(source.status) && source.parse_started_at.present? &&
         source.parse_started_at > PARSE_STALE_AFTER.ago
        raise Error, 'Another parse is already running'
      end
      raise Error, 'Knowledge file attachment is missing' unless source.file.attached?

      source.update!(
        status: source.materials.retrievable.exists? ? 'refreshing' : 'uploaded',
        parse_token: parse_token,
        parse_started_at: nil,
        failure_code: nil,
        failure_message: nil
      )
      source.materials.active.find_each do |material|
        material.update!(status: material.markdown.present? ? 'updating' : 'processing')
      end
    end
    begin
      job = ChatRing::Knowledge::FileParseJob.perform_later(source.id, parse_token)
      raise Error, 'File parsing could not be queued' unless job.successfully_enqueued?
    rescue StandardError => e
      source.with_lock do
        source.update!(status: source.materials.retrievable.exists? ? 'refresh_failed' : 'failed',
                       parse_token: nil, failure_code: e.class.name,
                       failure_message: 'File parsing could not be queued')
        source.materials.active.find_each do |material|
          material.update!(status: material.markdown.present? ? 'refresh_failed' : 'failed')
        end
      end
      raise
    end
    source
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  def self.restore_material!(source)
    raise Error, 'Only a parsed file can be restored' unless source.status == 'ready' && source.markdown.present?

    ChatRing::KnowledgeMaterial.transaction do
      source.knowledge_base.lock!
      source.lock!
      upsert_material!(source)
    end
    ChatRing::Knowledge::IndexBuilder.enqueue!(source.knowledge_base)
    source
  rescue StandardError => e
    mark_index_failure!(source, e)
    raise
  end

  def self.mark_index_failure!(source, error)
    ChatRing::KnowledgeMaterial.transaction do
      source.knowledge_base.lock!
      source.lock!
      material = source.materials.active.first
      live = material.present? && source.knowledge_base.material_available?(material)
      source.update!(status: live ? 'refresh_failed' : 'failed', failure_code: error.class.name,
                     failure_message: 'Knowledge indexing could not be queued')
      material&.update!(status: live ? 'refresh_failed' : 'failed')
    end
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

  def claim! # rubocop:disable Metrics/CyclomaticComplexity
    claimed = false
    @source.with_lock do
      next unless %w[uploaded refreshing].include?(@source.status)
      next unless @parse_token.present? && @source.parse_token == @parse_token
      next if @source.status == 'refreshing' && @source.parse_started_at.present?
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

  def finalize!(normalized) # rubocop:disable Metrics/MethodLength
    ChatRing::KnowledgeMaterial.transaction do
      @source.knowledge_base.lock!
      @source.lock!
      raise Error, 'Knowledge file parse was superseded before finalization' unless @source.parse_token == @parse_token
      raise Error, 'Knowledge file parse was superseded before finalization' unless %w[parsing refreshing].include?(@source.status)

      @source.update!(
        status: 'ready',
        parse_token: nil,
        markdown: normalized.fetch(:markdown),
        content_hash: normalized.fetch(:content_hash),
        metadata: normalized.fetch(:metadata).merge('title' => normalized.fetch(:title)),
        parsed_at: Time.current,
        failure_code: nil,
        failure_message: nil
      )
      self.class.upsert_material!(@source)
    end
    begin
      ChatRing::Knowledge::IndexBuilder.enqueue!(@source.knowledge_base)
    rescue StandardError => e
      self.class.mark_index_failure!(@source, e)
      raise
    end
  end

  # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  def record_failure!(error)
    @source.reload if @source.has_changes_to_save?
    @source.with_lock do
      next unless @source.parse_token == @parse_token
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
        parse_token: nil,
        failure_code: error.class.name,
        failure_message: error.message.to_s.truncate(1000)
      )
      @source.materials.active.find_each do |material|
        material.update!(status: material.markdown.present? ? 'refresh_failed' : 'failed')
      end
    end
  end
  # rubocop:enable Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
end
