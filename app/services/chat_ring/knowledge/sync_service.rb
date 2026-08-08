class ChatRing::Knowledge::SyncService
  POLL_INTERVAL = 10.seconds
  PROCESSING_LOCK_NAMESPACE = 0x434852
  MAX_BUILD_AGE = 24.hours
  TERMINAL_TASK_FAILURES = %w[FAILURE REVOKED].freeze
  ACTIVE_TASK_STATUSES = %w[PENDING STARTED PROGRESS RETRY].freeze

  class Error < StandardError; end
  class ProviderIngestionError < Error; end
  class BuildDeadlineExceeded < Error; end

  def self.configuration_snapshot
    {
      'docs_gpt_source_config' => ChatRing::Knowledge::DocsGptClient::SOURCE_CONFIG.deep_stringify_keys,
      'embedding_model' => 'huggingface_sentence-transformers/all-mpnet-base-v2',
      'retrieval' => {
        'strategy' => ChatRing::Knowledge::DocsGptProvider::RETRIEVAL_STRATEGY,
        'score_threshold' => Float(ENV.fetch('DOCSGPT_SCORE_THRESHOLD'))
      }
    }
  end

  def initialize(index, docs_gpt: nil)
    @index = index
    @docs_gpt = docs_gpt
  end

  def tick
    ActiveRecord::Base.connection_pool.with_connection do |connection|
      return :retry unless acquire_processing_lock(connection)

      begin
        ensure_build_within_deadline!
        case @index.reload.status
        when 'building' then process_ingestion
        when 'ready', 'active', 'retired', 'failed', 'discarded' then :complete
        else raise Error, "Unknown provider-index status #{@index.status.inspect}"
        end
      ensure
        release_processing_lock(connection)
      end
    end
  rescue ChatRing::Knowledge::DocsGptClient::RequestError
    raise
  rescue StandardError => e
    unless @index.reload.status == 'failed'
      @index.fail!(code: e.class.name, message: e.message)
      ChatRing::Knowledge::ProviderCleanupScheduler.schedule_eligible!(knowledge_base: @index.knowledge_base)
    end
    raise
  end

  private

  def ensure_build_within_deadline!
    return unless @index.status == 'building'
    return if @index.created_at > MAX_BUILD_AGE.ago

    raise BuildDeadlineExceeded, "Provider index #{@index.id} exceeded the #{MAX_BUILD_AGE.inspect} build deadline"
  end

  def acquire_processing_lock(connection)
    ActiveModel::Type::Boolean.new.cast(
      connection.select_value("SELECT pg_try_advisory_lock(#{processing_lock_key})")
    )
  end

  def release_processing_lock(connection)
    connection.select_value("SELECT pg_advisory_unlock(#{processing_lock_key})")
  end

  def processing_lock_key
    (PROCESSING_LOCK_NAMESPACE << 32) | (@index.id % (2**32))
  end

  def process_ingestion # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    documents = @index.documents.order(:id).to_a
    raise ProviderIngestionError, 'Provider index contains no documents' if documents.empty?

    start_upload(documents) if documents.all? { |document| document.provider_task_id.blank? }
    if documents.any? { |document| document.reload.provider_task_id.blank? }
      raise ProviderIngestionError, 'DocsGPT upload is only partially recorded'
    end

    task_status = docs_gpt.task_status(documents.first.provider_task_id)['status'].to_s.upcase
    return :retry if ACTIVE_TASK_STATUSES.include?(task_status)

    if TERMINAL_TASK_FAILURES.include?(task_status)
      documents.each { |document| document.update!(provider_status: 'failed') }
      raise ProviderIngestionError, "DocsGPT ingestion failed for provider index #{@index.id}"
    end
    raise ProviderIngestionError, "DocsGPT returned unknown task status #{task_status.inspect}" unless task_status == 'SUCCESS'

    finalize_documents(documents) if documents.any? { |document| document.provider_status != 'ready' }
    @index.update!(
      status: 'ready',
      provider_agent_id: nil,
      provider_agent_api_key: nil,
      provider_agent_creation_started_at: nil,
      ready_at: Time.current
    )
    :complete
  end

  def start_upload(documents)
    result = docs_gpt.upload_index(@index)
    documents.each do |document|
      document.update!(
        provider_task_id: result.fetch(:task_id),
        provider_source_id: result.fetch(:source_id),
        provider_status: 'processing'
      )
    end
  end

  def finalize_documents(documents)
    chunks = docs_gpt.chunks(documents.first.provider_source_id)
    matches = ChatRing::Knowledge::ProviderChunkValidator.validate!(
      documents: documents,
      chunks: chunks,
      error_class: ProviderIngestionError
    )
    matches.each do |document, reference|
      document.update!(provider_status: 'ready', provider_source_reference: reference)
    end
  end

  def docs_gpt
    @docs_gpt ||= ChatRing::Knowledge::DocsGptClient.new(
      base_url: ENV.fetch('DOCSGPT_BASE_URL'),
      jwt_secret: ENV.fetch('DOCSGPT_JWT_SECRET'),
      internal_key: ENV.fetch('DOCSGPT_INTERNAL_KEY'),
      service_secret: ENV.fetch('DOCSGPT_SERVICE_SECRET')
    )
  end
end
