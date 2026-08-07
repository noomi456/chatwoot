class ChatRing::Knowledge::FileSourceService
  Result = Data.define(:source, :reused)

  class Error < StandardError; end

  def self.create!(account:, inbox:, uploaded_file:, authority_class:, actor:)
    new(account: account, inbox: inbox, uploaded_file: uploaded_file, authority_class: authority_class, actor: actor).create!
  end

  def initialize(account:, inbox:, uploaded_file:, authority_class:, actor:)
    @account = account
    @inbox = inbox
    @uploaded_file = uploaded_file
    @authority_class = authority_class.to_s
    @actor = actor
  end

  def create! # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    raise Error, 'Inbox does not belong to account' unless @inbox.account_id == @account.id
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

    source = ChatRing::KnowledgeFileSource.create!(
      account: @account,
      inbox: @inbox,
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
    ChatRing::Knowledge::FileParseJob.perform_later(source.id)
    Result.new(source: source, reused: false)
  rescue ActiveRecord::RecordNotUnique
    reuse_existing_source(duplicate_source!(preflight.content_hash, parser_profile_digest), preflight)
  end

  private

  def duplicate_source(content_hash, parser_profile_digest)
    ChatRing::KnowledgeFileSource.find_by(
      account_id: @account.id,
      inbox_id: @inbox.id,
      raw_content_hash: content_hash,
      parser_profile_digest: parser_profile_digest
    )
  end

  def duplicate_source!(content_hash, parser_profile_digest)
    duplicate_source(content_hash, parser_profile_digest) || raise(Error, 'Duplicate knowledge source could not be loaded')
  end

  def reuse_existing_source(source, preflight)
    recovered = false
    source.with_lock do
      source.update!(authority_class: @authority_class, approved_by: @actor) if source.authority_class != @authority_class
      if source.status == 'disabled'
        source.update!(status: source.markdown.present? ? 'ready' : 'uploaded', disabled_at: nil)
        recovered = source.status == 'uploaded'
      end
      if source.status == 'failed' && !source.file.attached?
        attach_file!(source, preflight, destroy_source_on_failure: false)
        source.update!(status: 'uploaded', parse_started_at: nil, failure_code: nil, failure_message: nil)
        recovered = true
      end
    end
    ChatRing::Knowledge::FileParseJob.perform_later(source.id) if recovered
    Result.new(source: source, reused: true)
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
