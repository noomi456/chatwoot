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
    cleanup.with_lock do
      next if cleanup.status == 'succeeded'

      version = cleanup.knowledge_version
      if version.present? && ChatRing::Knowledge::ProviderCleanupScheduler.protected?(version)
        cleanup.update!(status: 'cancelled', last_error: 'knowledge version is retained by a publication pointer')
        next
      end
      if cleanup.eligible_at.future?
        self.class.set(wait_until: cleanup.eligible_at).perform_later(cleanup.id)
        next
      end

      cleanup.update!(status: 'retrying', attempts: cleanup.attempts + 1, last_error: nil)
      docs_gpt_client.delete_source(
        account_id: cleanup.account_id,
        knowledge_version_id: cleanup.knowledge_version_id,
        binding_digest: cleanup.binding_digest,
        source_id: cleanup.provider_source_id
      )
      cleanup.update!(status: 'succeeded', cleaned_at: Time.current, last_error: nil)
    end
  rescue ChatRing::Knowledge::DocsGptClient::Error => e
    retry_cleanup = ChatRing::KnowledgeProviderCleanup.find_by(id: cleanup_id)
    retry_cleanup&.with_lock do
      retry_cleanup.update!(
        status: 'retrying',
        attempts: retry_cleanup.attempts + 1,
        last_error: e.message.to_s.truncate(1000)
      )
    end
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
