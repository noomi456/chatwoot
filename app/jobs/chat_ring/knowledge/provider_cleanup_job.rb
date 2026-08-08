class ChatRing::Knowledge::ProviderCleanupJob < ApplicationJob
  queue_as :low

  retry_on ChatRing::Knowledge::DocsGptClient::Error,
           wait: :polynomially_longer,
           attempts: 10 do |job, error|
    cleanup = ChatRing::KnowledgeProviderCleanup.find_by(id: job.arguments.first)
    cleanup&.update!(status: 'failed', last_error: error.message.to_s.truncate(1000))
  end

  def perform(cleanup_id)
    cleanup = ChatRing::KnowledgeProviderCleanup.find_by(id: cleanup_id)
    return if cleanup.blank? || cleanup.status == 'succeeded'
    return cancel!(cleanup) if ChatRing::Knowledge::ProviderCleanupScheduler.protected?(cleanup.knowledge_index)

    cleanup.update!(status: 'retrying', attempts: cleanup.attempts + 1, last_error: nil)
    docs_gpt_client.delete_source(
      account_id: cleanup.account_id,
      knowledge_index_id: cleanup.knowledge_index_id,
      binding_digest: cleanup.binding_digest,
      source_id: cleanup.provider_source_id
    )
    cleanup.update!(status: 'succeeded', cleaned_at: Time.current, last_error: nil)
  end

  private

  def cancel!(cleanup)
    cleanup.update!(status: 'cancelled', last_error: 'provider index is active')
  end

  def docs_gpt_client
    ChatRing::Knowledge::DocsGptClient.new(
      base_url: ENV.fetch('DOCSGPT_BASE_URL'),
      jwt_secret: ENV.fetch('DOCSGPT_JWT_SECRET'),
      internal_key: ENV.fetch('DOCSGPT_INTERNAL_KEY'),
      service_secret: ENV.fetch('DOCSGPT_SERVICE_SECRET')
    )
  end
end
