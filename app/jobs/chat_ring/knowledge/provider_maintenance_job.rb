class ChatRing::Knowledge::ProviderMaintenanceJob < ApplicationJob
  queue_as :low

  retry_on ChatRing::Knowledge::DocsGptClient::Error, wait: :polynomially_longer, attempts: 5

  def perform
    return unless ENV['CHATRING_KNOWLEDGE_LIFECYCLE_RECONCILIATION_ENABLED'] == 'true'

    docs_gpt_client.cleanup_expired_idempotency
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
