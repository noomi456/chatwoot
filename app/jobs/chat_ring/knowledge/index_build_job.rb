class ChatRing::Knowledge::IndexBuildJob < ApplicationJob
  queue_as :default

  def perform(knowledge_base_id) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    knowledge_base = ChatRing::KnowledgeBase.find_by(id: knowledge_base_id)
    return if knowledge_base.nil?

    index = ChatRing::Knowledge::IndexBuilder.build!(knowledge_base)
    if index&.status == 'building'
      job = ChatRing::Knowledge::SyncJob.perform_later(index.id)
      raise 'Knowledge provider synchronization could not be queued' unless job.successfully_enqueued?
    elsif index&.status == 'ready'
      job = ChatRing::Knowledge::ActivationJob.perform_later(index.id)
      raise 'Knowledge activation could not be queued' unless job.successfully_enqueued?
    end
  rescue StandardError => e
    ChatRing::KnowledgeBase.transaction do
      knowledge_base&.lock!
      knowledge_base&.materials&.active&.where(status: %w[processing updating])&.find_each do |material|
        material.update!(status: knowledge_base.material_available?(material) ? 'refresh_failed' : 'failed')
      end
    end
    Rails.error.report(e, handled: false, context: { knowledge_base_id: knowledge_base_id })
    raise
  end
end
