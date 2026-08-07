class ChatRing::Knowledge::FileParseService
  class Error < StandardError; end

  def initialize(source, client: nil)
    @source = source
    @client = client || ChatRing::Knowledge::FirecrawlParseClient.new(api_key: ENV.fetch('FIRECRAWL_API_KEY'))
    @provider_request_started = false
  end

  def call # rubocop:disable Metrics/MethodLength
    return :complete unless claim!

    @source.file.blob.open do |file|
      preflight = verify_stored_file!(file)
      @provider_request_started = true
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
    record_failure!(e.indeterminate? ? 'parse_indeterminate' : 'failed', e)
    :complete
  rescue ChatRing::Knowledge::FirecrawlParseClient::ResponseError, ChatRing::Knowledge::FilePreflight::Error,
         ChatRing::Knowledge::FileSnapshotNormalizer::Error => e
    record_failure!(@provider_request_started ? 'parse_indeterminate' : 'failed', e)
    :complete
  rescue StandardError => e
    record_failure!(@provider_request_started ? 'parse_indeterminate' : 'failed', e)
    Rails.error.report(e, handled: true, context: { knowledge_file_source_id: @source.id })
    :complete
  end

  def self.retry!(source)
    source.with_lock do
      raise Error, 'Only failed or indeterminate file parses can be retried' unless %w[failed parse_indeterminate].include?(source.status)
      raise Error, 'Knowledge file attachment is missing; upload the identical file again to recover it' unless source.file.attached?

      source.update!(
        status: 'uploaded',
        parse_started_at: nil,
        failure_code: nil,
        failure_message: nil
      )
    end
    ChatRing::Knowledge::FileParseJob.perform_later(source.id)
    source
  end

  private

  def claim!
    claimed = false
    @source.with_lock do
      next if %w[ready disabled].include?(@source.status)
      next unless @source.status == 'uploaded'

      raise Error, 'Knowledge file attachment is missing' unless @source.file.attached?

      @source.update!(
        status: 'parsing',
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
      raise ChatRing::Knowledge::FilePreflight::Error, 'Stored knowledge file no longer matches its immutable identity'
    end

    preflight
  end

  def finalize!(normalized)
    @source.with_lock do
      raise Error, 'Knowledge file parse was superseded before finalization' unless @source.status == 'parsing'

      @source.update!(
        status: 'ready',
        markdown: normalized.fetch(:markdown),
        content_hash: normalized.fetch(:content_hash),
        metadata: normalized.fetch(:metadata).merge('title' => normalized.fetch(:title)),
        parsed_at: Time.current,
        failure_code: nil,
        failure_message: nil
      )
    end
  end

  def record_failure!(status, error)
    @source.reload if @source.has_changes_to_save?
    @source.with_lock do
      next if %w[ready disabled].include?(@source.status)

      @source.update!(
        status: status,
        failure_code: error.class.name,
        failure_message: error.message.to_s.truncate(1000)
      )
    end
  end
end
