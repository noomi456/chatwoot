class ChatRing::Knowledge::ActivationJob < ApplicationJob
  queue_as :default

  retry_on ChatRing::Knowledge::IndexActivationService::Error,
           wait: :polynomially_longer,
           attempts: 5 do |job, error|
    index = ChatRing::KnowledgeIndex.find_by(id: job.arguments.first)
    index&.fail!(code: error.class.name, message: error.message) if index&.status == 'ready'
    ChatRing::Knowledge::SyncJob.mark_materials_failed(index)
    ChatRing::Knowledge::ProviderCleanupScheduler.schedule_eligible!(knowledge_base: index.knowledge_base) if index
  end

  def perform(index_id)
    index = ChatRing::KnowledgeIndex.find_by(id: index_id)
    return if index.nil?

    ChatRing::Knowledge::IndexActivationService.activate!(index)
  end
end
