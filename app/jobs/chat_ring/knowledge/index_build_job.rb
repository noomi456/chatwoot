class ChatRing::Knowledge::IndexBuildJob < ApplicationJob
  queue_as :default

  def perform(knowledge_base_id)
    knowledge_base = ChatRing::KnowledgeBase.find(knowledge_base_id)
    index = ChatRing::Knowledge::IndexBuilder.build!(knowledge_base)
    ChatRing::Knowledge::SyncJob.perform_later(index.id) if index
  rescue StandardError => e
    ChatRing::KnowledgeBase.transaction do
      knowledge_base&.lock!
      knowledge_base&.materials&.active&.where(status: %w[processing updating])&.find_each do |material|
        active_document = knowledge_base.active_knowledge_index&.documents&.exists?(knowledge_material_id: material.id)
        material.update!(status: active_document ? 'refresh_failed' : 'failed')
      end
    end
    Rails.error.report(e, handled: false, context: { knowledge_base_id: knowledge_base_id })
    raise
  end
end
