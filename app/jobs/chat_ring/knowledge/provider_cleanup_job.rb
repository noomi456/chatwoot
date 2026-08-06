class ChatRing::Knowledge::ProviderCleanupJob < ApplicationJob
  queue_as :low

  retry_on ChatRing::Knowledge::DocsGptClient::Error,
           wait: :polynomially_longer,
           attempts: 10 do |job, error|
    cleanup = ChatRing::KnowledgeProviderCleanup.find_by(id: job.arguments.first)
    cleanup&.update!(status: 'failed', last_error: error.message.to_s.truncate(1000))
  end

  def perform(cleanup_id) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    cleanup = ChatRing::KnowledgeProviderCleanup.find(cleanup_id)
    return if cleanup.status == 'succeeded'

    version = cleanup.knowledge_version
    if ChatRing::Knowledge::ProviderCleanupScheduler.protected?(version)
      cleanup.update!(status: 'cancelled', last_error: 'knowledge version is retained by a publication pointer')
      return
    end
    if cleanup.eligible_at.future?
      self.class.set(wait_until: cleanup.eligible_at).perform_later(cleanup.id)
      return
    end

    cleanup.update!(status: 'retrying', attempts: cleanup.attempts + 1, last_error: nil)
    docs_gpt_client.delete_source(
      account_id: version.account_id,
      knowledge_version_id: version.id,
      binding_digest: cleanup.binding_digest,
      source_id: cleanup.provider_source_id
    )
    cleanup.update!(status: 'succeeded', cleaned_at: Time.current, last_error: nil)
  rescue ChatRing::Knowledge::DocsGptClient::Error => e
    cleanup&.update!(status: 'retrying', last_error: e.message.to_s.truncate(1000))
    raise
  end

  private

  def docs_gpt_client
    ChatRing::Knowledge::DocsGptClient.new(
      base_url: ENV.fetch('DOCSGPT_BASE_URL'),
      jwt_secret: ENV.fetch('DOCSGPT_JWT_SECRET'),
      internal_key: ENV.fetch('DOCSGPT_INTERNAL_KEY'),
      service_secret: ENV.fetch('DOCSGPT_SERVICE_SECRET')
    )
  end
end
