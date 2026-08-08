class ChatRing::Knowledge::FileSourceService
  Result = Data.define(:source, :reused)

  class Error < StandardError; end

  def self.create!(account:, uploaded_file:, authority_class:, actor:)
    new(account: account, uploaded_file: uploaded_file, authority_class: authority_class, actor: actor).create!
  end

  def initialize(account:, uploaded_file:, authority_class:, actor:)
    @knowledge_base = ChatRing::KnowledgeBase.for_account!(account)
    @uploaded_file = uploaded_file
    @authority_class = authority_class.to_s
    @actor = actor
  end

  def create!
    raise Error, 'Knowledge authority class is invalid' unless ChatRing::KnowledgeFileSource::AUTHORITY_CLASSES.include?(@authority_class)

    preflight = ChatRing::Knowledge::FilePreflight.call(
      io: @uploaded_file.tempfile,
      filename: @uploaded_file.original_filename,
      declared_content_type: @uploaded_file.content_type
    )
    parser_profile = ChatRing::Knowledge::FirecrawlParseClient.profile_for(preflight.source_kind)
    parser_profile_digest = ChatRing::Knowledge::FirecrawlParseClient.profile_digest(preflight.source_kind)
    existing = duplicate_source(preflight.content_hash, parser_profile_digest)
    return reuse_existing_source(existing, preflight) if existing

    source, parse_token = create_source_and_material!(preflight, parser_profile, parser_profile_digest)
    enqueue_parse!(source, parse_token)
    Result.new(source: source, reused: false)
  rescue ActiveRecord::RecordNotUnique
    reuse_existing_source(duplicate_source!(preflight.content_hash, parser_profile_digest), preflight)
  end

  private

  def create_source_and_material!(preflight, parser_profile, parser_profile_digest) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    source = @knowledge_base.file_sources.create!(
      source_kind: preflight.source_kind,
      original_filename: preflight.filename,
      content_type: preflight.content_type,
      byte_size: preflight.byte_size,
      raw_content_hash: preflight.content_hash,
      authority_class: @authority_class,
      parser_profile: parser_profile,
      parser_profile_digest: parser_profile_digest,
      metadata: preflight.metadata,
      created_by: @actor,
      approved_by: @actor
    )
    parse_token = SecureRandom.uuid
    source.update!(parse_token: parse_token)
    attach_file!(source, preflight)
    source.knowledge_base.materials.create!(
      file_source: source,
      source_kind: source.source_kind,
      source_reference: source.source_reference,
      title: source.original_filename,
      status: 'processing',
      authority_class: source.authority_class,
      metadata: source.metadata
    )
    [source, parse_token]
  rescue StandardError
    source&.file&.purge if source&.file&.attached?
    source&.destroy! if source&.persisted?
    raise
  end

  def duplicate_source(content_hash, parser_profile_digest)
    @knowledge_base.file_sources.find_by(
      raw_content_hash: content_hash,
      parser_profile_digest: parser_profile_digest
    )
  end

  def duplicate_source!(content_hash, parser_profile_digest)
    duplicate_source(content_hash, parser_profile_digest) || raise(Error, 'Duplicate knowledge source could not be loaded')
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  def reuse_existing_source(source, preflight)
    needs_parse = false
    parse_token = nil
    ChatRing::KnowledgeMaterial.transaction do # rubocop:disable Metrics/BlockLength
      @knowledge_base.lock!
      source.lock!
      source.update!(authority_class: @authority_class, approved_by: @actor)
      if source.status == 'deleted'
        attach_file!(source, preflight, destroy_source_on_failure: false) unless source.file.attached?
        source.update!(
          status: source.markdown.present? ? 'ready' : 'uploaded',
          disabled_at: nil,
          failure_code: nil,
          failure_message: nil
        )
        needs_parse = source.status == 'uploaded'
      elsif %w[failed parse_indeterminate].include?(source.status)
        attach_file!(source, preflight, destroy_source_on_failure: false) unless source.file.attached?
        source.update!(status: 'uploaded', parse_started_at: nil, failure_code: nil, failure_message: nil)
        needs_parse = true
      elsif source.status == 'refresh_failed'
        if source.markdown.present?
          source.update!(status: 'ready', failure_code: nil, failure_message: nil)
        else
          attach_file!(source, preflight, destroy_source_on_failure: false) unless source.file.attached?
          source.update!(status: 'uploaded', parse_started_at: nil, failure_code: nil, failure_message: nil)
          needs_parse = true
        end
      elsif source.status == 'uploaded'
        needs_parse = true
      elsif source.status == 'parsing' && source.parse_started_at.present? &&
            source.parse_started_at <= ChatRing::Knowledge::FileParseService::PARSE_STALE_AFTER.ago
        source.update!(status: 'uploaded', parse_started_at: nil, failure_code: nil, failure_message: nil)
        needs_parse = true
      end
      if needs_parse
        parse_token = SecureRandom.uuid
        source.update!(parse_token: parse_token)
        restore_processing_material!(source)
      elsif source.status == 'ready'
        restore_ready_material!(source)
      end
    end

    if needs_parse
      enqueue_parse!(source, parse_token)
    elsif source.status == 'ready'
      begin
        ChatRing::Knowledge::IndexBuilder.enqueue!(@knowledge_base)
      rescue StandardError => e
        ChatRing::Knowledge::FileParseService.mark_index_failure!(source, e)
        raise
      end
    end
    Result.new(source: source, reused: true)
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  def restore_processing_material!(source)
    material = source.knowledge_base.materials.find_or_initialize_by(source_reference: source.source_reference)
    material.material_key = SecureRandom.uuid if material.persisted? && !material.active?
    material.assign_attributes(
      file_source: source,
      website_source: nil,
      source_kind: source.source_kind,
      title: source.original_filename,
      status: 'processing',
      authority_class: source.authority_class,
      metadata: source.metadata,
      deleted_at: nil
    )
    material.save!
  end

  def restore_ready_material!(source)
    material = source.knowledge_base.materials.find_or_initialize_by(source_reference: source.source_reference)
    material.update!(material_key: SecureRandom.uuid) if material.persisted? && !material.active?
    ChatRing::Knowledge::FileParseService.upsert_material!(source)
  end

  def attach_file!(source, preflight, destroy_source_on_failure: true)
    @uploaded_file.tempfile.rewind
    blob = ActiveStorage::Blob.create_and_upload!(
      io: @uploaded_file.tempfile,
      filename: preflight.filename,
      content_type: preflight.content_type,
      identify: false
    )
    source.file.attach(blob)
  rescue StandardError
    source.destroy! if destroy_source_on_failure
    blob&.purge
    raise
  end

  def enqueue_parse!(source, parse_token)
    job = ChatRing::Knowledge::FileParseJob.perform_later(source.id, parse_token)
    raise Error, 'File parsing could not be queued' unless job.successfully_enqueued?
  rescue StandardError => e
    source.with_lock do
      source.update!(status: 'failed', parse_token: nil, failure_code: e.class.name,
                     failure_message: 'File parsing could not be queued')
      source.materials.active.find_each do |material|
        material.update!(status: material.markdown.present? ? 'refresh_failed' : 'failed')
      end
    end
    raise
  end
end
