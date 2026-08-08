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

  def create! # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    unless ChatRing::KnowledgeFileSource::AUTHORITY_CLASSES.include?(@authority_class)
      raise Error, 'Knowledge authority class is invalid'
    end

    preflight = ChatRing::Knowledge::FilePreflight.call(
      io: @uploaded_file.tempfile,
      filename: @uploaded_file.original_filename,
      declared_content_type: @uploaded_file.content_type
    )
    parser_profile = ChatRing::Knowledge::FirecrawlParseClient.profile_for(preflight.source_kind)
    parser_profile_digest = ChatRing::Knowledge::FirecrawlParseClient.profile_digest(preflight.source_kind)
    existing = duplicate_source(preflight.content_hash, parser_profile_digest)
    return reuse_existing_source(existing, preflight) if existing

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
    ChatRing::Knowledge::FileParseJob.perform_later(source.id)
    Result.new(source: source, reused: false)
  rescue ActiveRecord::RecordNotUnique
    reuse_existing_source(duplicate_source!(preflight.content_hash, parser_profile_digest), preflight)
  end

  private

  def duplicate_source(content_hash, parser_profile_digest)
    @knowledge_base.file_sources.find_by(
      raw_content_hash: content_hash,
      parser_profile_digest: parser_profile_digest
    )
  end

  def duplicate_source!(content_hash, parser_profile_digest)
    duplicate_source(content_hash, parser_profile_digest) || raise(Error, 'Duplicate knowledge source could not be loaded')
  end

  def reuse_existing_source(source, preflight)
    needs_parse = false
    source.with_lock do
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
      end
    end

    if needs_parse
      restore_processing_material!(source)
      ChatRing::Knowledge::FileParseJob.perform_later(source.id)
    elsif source.status == 'ready'
      ChatRing::Knowledge::FileParseService.restore_material!(source)
    end
    Result.new(source: source, reused: true)
  end

  def restore_processing_material!(source)
    material = source.knowledge_base.materials.find_or_initialize_by(source_reference: source.source_reference)
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
end
