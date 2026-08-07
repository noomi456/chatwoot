class ChatRing::Knowledge::ActivationJob < ApplicationJob
  queue_as :default

  retry_on ChatRing::Knowledge::ProviderValidator::Error, wait: :polynomially_longer, attempts: 5 do |job, error|
    version = ChatRing::KnowledgeVersion.find_by(id: job.arguments.first)
    version&.update!(failure_code: 'automatic_publication_failed', failure_message: error.message.to_s.truncate(1000))
  end

  discard_on ChatRing::Knowledge::PublicationService::Error do |job, error|
    version = ChatRing::KnowledgeVersion.find_by(id: job.arguments.first)
    version&.update!(failure_code: 'automatic_publication_rejected', failure_message: error.message.to_s.truncate(1000))
  end

  def perform(version_id)
    version = ChatRing::KnowledgeVersion.find(version_id)
    return unless version.config_snapshot['publish_on_ready']
    return if version.status == 'published'

    ChatRing::Knowledge::PublicationService.publish_verified!(version)
  end
end
