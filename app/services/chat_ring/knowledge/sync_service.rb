class ChatRing::Knowledge::SyncService
  POLL_INTERVAL = 10.seconds
  MAX_BUILD_AGE = 24.hours
  UPLOAD_CLAIM_TIMEOUT = 5.minutes
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

  def tick # rubocop:disable Metrics/CyclomaticComplexity
    return :complete unless ChatRing::KnowledgeIndex.exists?(@index.id)

    ensure_build_within_deadline!
    case @index.reload.status
    when 'building' then process_ingestion
    when 'ready', 'active', 'retired', 'failed', 'discarded' then :complete
    else raise Error, "Unknown provider-index status #{@index.status.inspect}"
    end
  rescue ChatRing::Knowledge::DocsGptClient::RequestError
    raise
  rescue StandardError => e
    unless @index.destroyed? || !ChatRing::KnowledgeIndex.exists?(@index.id) || @index.reload.status == 'failed'
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

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  def process_ingestion
    documents = @index.documents.order(:id).to_a
    raise ProviderIngestionError, 'Provider index contains no documents' if documents.empty?

    if documents.all? { |document| document.provider_task_id.blank? }
      return :retry if start_upload(documents) == :waiting

      documents = @index.documents.order(:id).to_a
    end
    raise ProviderIngestionError, 'DocsGPT upload is only partially recorded' if documents.any? { |document| document.reload.provider_task_id.blank? }

    task_status = docs_gpt.task_status(@index, documents.first.provider_task_id,
                                       documents.first.provider_source_id)['status'].to_s.upcase
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
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  def start_upload(documents)
    expected_source_id = docs_gpt.expected_source_id(@index)
    scope = { account_id: @index.account_id, index_id: @index.id, binding_digest: @index.provider_binding_digest }
    claim_state = @index.with_lock do
      current_documents = @index.documents.order(:id).to_a
      raise ProviderIngestionError, 'Provider index documents changed before upload' unless current_documents.map(&:id) == documents.map(&:id)
      next :complete if current_documents.any? { |document| document.provider_task_id.present? }
      if @index.provider_agent_creation_started_at.present? &&
         @index.provider_agent_creation_started_at > UPLOAD_CLAIM_TIMEOUT.ago
        next :waiting
      end

      @index.update!(provider_agent_creation_started_at: Time.current)
      current_documents.each { |document| document.update!(provider_source_id: expected_source_id) }
      :claimed
    end
    return claim_state unless claim_state == :claimed

    result = docs_gpt.upload_index(@index)
    unless ChatRing::KnowledgeIndex.exists?(@index.id)
      delete_removed_upload(result.fetch(:source_id), scope)
      return :complete
    end

    @index.with_lock do
      raise ProviderIngestionError, 'Provider index was removed before upload finalization' unless @index.status == 'building'

      current_documents = @index.documents.order(:id).to_a
      raise ProviderIngestionError, 'Provider index documents changed during upload' unless current_documents.map(&:id) == documents.map(&:id)

      current_documents.each do |document|
        document.update!(
          provider_task_id: result.fetch(:task_id),
          provider_source_id: result.fetch(:source_id),
          provider_status: 'processing'
        )
      end
      @index.update!(provider_agent_creation_started_at: nil)
    end
    :complete
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  def finalize_documents(documents)
    chunks = docs_gpt.chunks(@index, documents.first.provider_source_id)
    matches = ChatRing::Knowledge::ProviderChunkValidator.validate!(
      documents: documents,
      chunks: chunks,
      error_class: ProviderIngestionError
    )
    matches.each do |document, reference|
      document.update!(provider_status: 'ready', provider_source_reference: reference)
    end
  end

  def delete_removed_upload(source_id, scope)
    docs_gpt.delete_source(
      account_id: scope.fetch(:account_id),
      knowledge_index_id: scope.fetch(:index_id),
      binding_digest: scope.fetch(:binding_digest),
      source_id: source_id
    )
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
