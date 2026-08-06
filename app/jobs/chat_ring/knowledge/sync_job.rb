class ChatRing::Knowledge::SyncJob < ApplicationJob
  queue_as :default

  retry_on ChatRing::Knowledge::FirecrawlClient::RequestError,
           ChatRing::Knowledge::DocsGptClient::RequestError,
           wait: :polynomially_longer,
           attempts: 8 do |job, error|
    version = ChatRing::KnowledgeVersion.find_by(id: job.arguments.first)
    version&.fail!(code: error.class.name, message: error.message)
    ChatRing::Knowledge::ProviderCleanupScheduler.schedule_eligible!(account: version.account, inbox: version.inbox) if version
  end

  def perform(version_id)
    version = ChatRing::KnowledgeVersion.find(version_id)
    outcome = ChatRing::Knowledge::SyncService.new(version).tick
    self.class.set(wait: ChatRing::Knowledge::SyncService::POLL_INTERVAL).perform_later(version_id) if outcome == :retry
  end
end
