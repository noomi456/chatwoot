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

  def perform(index_id) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    index = ChatRing::KnowledgeIndex.find_by(id: index_id)
    return if index.nil?

    outcome = ChatRing::Knowledge::SyncService.new(index).tick
    if outcome == :retry
      job = self.class.set(wait: ChatRing::Knowledge::SyncService::POLL_INTERVAL).perform_later(index_id)
      raise 'Knowledge provider polling could not be queued' unless job.successfully_enqueued?
    end
    return unless outcome == :complete && index.reload.status == 'ready'

    job = ChatRing::Knowledge::ActivationJob.perform_later(index.id)
    raise 'Knowledge activation could not be queued' unless job.successfully_enqueued?
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
      index.documents.includes(:knowledge_material).find_each do |document|
        material = document.knowledge_material
        material.lock!
        next unless material.active? && material.content_hash == document.content_hash

        material.update!(status: index.knowledge_base.material_available?(material) ? 'refresh_failed' : 'failed')
      end
    end
  end
end
