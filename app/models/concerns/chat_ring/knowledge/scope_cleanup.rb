module ChatRing::Knowledge::ScopeCleanup
  module AccountExtension
    extend ActiveSupport::Concern

    included do
      has_many :chat_ring_knowledge_file_sources,
               class_name: 'ChatRing::KnowledgeFileSource',
               dependent: :destroy,
               inverse_of: :account
      before_destroy :prepare_chat_ring_knowledge_cleanup
      after_destroy_commit :enqueue_chat_ring_knowledge_cleanup
    end

    private

    def prepare_chat_ring_knowledge_cleanup
      @chat_ring_knowledge_cleanup_ids = ChatRing::Knowledge::ProviderCleanupScheduler.prepare_scope_deletion!(account_id: id).map(&:id)
    end

    def enqueue_chat_ring_knowledge_cleanup
      ChatRing::Knowledge::ProviderCleanupScheduler.enqueue!(@chat_ring_knowledge_cleanup_ids)
    end
  end

  module InboxExtension
    extend ActiveSupport::Concern

    included do
      has_many :chat_ring_knowledge_file_sources,
               class_name: 'ChatRing::KnowledgeFileSource',
               dependent: :destroy,
               inverse_of: :inbox
      before_destroy :prepare_chat_ring_knowledge_cleanup
      after_destroy_commit :enqueue_chat_ring_knowledge_cleanup
    end

    private

    def prepare_chat_ring_knowledge_cleanup
      @chat_ring_knowledge_cleanup_ids = ChatRing::Knowledge::ProviderCleanupScheduler.prepare_scope_deletion!(
        account_id: account_id,
        inbox_id: id
      ).map(&:id)
    end

    def enqueue_chat_ring_knowledge_cleanup
      ChatRing::Knowledge::ProviderCleanupScheduler.enqueue!(@chat_ring_knowledge_cleanup_ids)
    end
  end
end
