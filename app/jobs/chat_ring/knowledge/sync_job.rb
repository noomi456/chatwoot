class ChatRing::Knowledge::SyncJob < ApplicationJob
  queue_as :default

  retry_on ChatRing::Knowledge::DocsGptClient::RequestError,
           wait: :polynomially_longer,
           attempts: 8 do |job, error|
    index = ChatRing::KnowledgeIndex.find_by(id: job.arguments.first)
    index&.fail!(code: error.class.name, message: error.message)
    mark_materials_failed(index)
    ChatRing::Knowledge::ProviderCleanupScheduler.schedule_eligible!(knowledge_base: index.knowledge_base) if index
  end

  def perform(index_id)
    index = ChatRing::KnowledgeIndex.find(index_id)
    outcome = ChatRing::Knowledge::SyncService.new(index).tick
    self.class.set(wait: ChatRing::Knowledge::SyncService::POLL_INTERVAL).perform_later(index_id) if outcome == :retry
    return unless outcome == :complete && index.reload.status == 'ready'

    ChatRing::Knowledge::ActivationJob.perform_later(index.id)
  rescue ChatRing::Knowledge::DocsGptClient::ResponseError, ChatRing::Knowledge::SyncService::Error => e
    index&.fail!(code: e.class.name, message: e.message) unless index&.status == 'failed'
    self.class.mark_materials_failed(index)
    ChatRing::Knowledge::ProviderCleanupScheduler.schedule_eligible!(knowledge_base: index.knowledge_base) if index
    Rails.error.report(e, handled: false, context: { knowledge_index_id: index_id })
    raise
  end

  def self.mark_materials_failed(index)
    return if index.blank?

    ChatRing::KnowledgeMaterial.transaction do
      index.knowledge_base.lock!
      index.documents.includes(:knowledge_material).each do |document|
        material = document.knowledge_material
        material.lock!
        next unless material.active? && material.content_hash == document.content_hash

        active_document = index.knowledge_base.active_knowledge_index&.documents&.exists?(knowledge_material_id: material.id)
        material.update!(status: active_document ? 'refresh_failed' : 'failed')
      end
    end
  end
end
