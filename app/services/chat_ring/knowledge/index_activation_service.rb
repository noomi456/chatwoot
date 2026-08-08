class ChatRing::Knowledge::IndexActivationService
  class Error < StandardError; end

  def self.activate!(index)
    old_index = nil
    outcome = ChatRing::KnowledgeBase.transaction do
      knowledge_base = index.knowledge_base
      knowledge_base.lock!
      index.lock!
      raise Error, "Provider index #{index.id} is not ready" unless index.status == 'ready'

      current_digest = ChatRing::Knowledge::IndexBuilder.catalog_digest(knowledge_base)
      if index.manifest_digest != current_digest
        discard!(index, 'material catalog changed while the provider index was building')
        next :stale
      end

      active = knowledge_base.active_knowledge_index
      if active&.manifest_digest == index.manifest_digest
        index.documents.includes(:knowledge_material).each do |document|
          document.knowledge_material.update!(status: 'available')
        end
        discard!(index, 'an identical provider index is already active')
        next :redundant
      end

      old_index = active
      old_index.update!(status: 'retired') if old_index&.status == 'active'
      index.update!(status: 'active', activated_at: Time.current)
      knowledge_base.update!(active_knowledge_index: index)
      index.documents.includes(:knowledge_material).each do |document|
        document.knowledge_material.update!(status: 'available')
      end
      :activated
    end

    ChatRing::Knowledge::ProviderCleanupScheduler.schedule_eligible!(knowledge_base: index.knowledge_base)
    outcome
  end

  def self.discard!(index, reason)
    index.update!(status: 'discarded', discarded_at: Time.current, discard_reason: reason)
  end
  private_class_method :discard!
end
