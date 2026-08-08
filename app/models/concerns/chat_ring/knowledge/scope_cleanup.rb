# rubocop:disable Style/ClassAndModuleChildren
module ChatRing::Knowledge::ScopeCleanup
  module AccountExtension
    extend ActiveSupport::Concern

    included do
      has_one :chat_ring_workspace,
              class_name: 'ChatRing::Workspace',
              foreign_key: :chatwoot_account_id,
              inverse_of: :chatwoot_account,
              dependent: :destroy
      after_create :ensure_chat_ring_workspace
      before_destroy :prepare_chat_ring_knowledge_cleanup, prepend: true
      after_destroy_commit :enqueue_chat_ring_knowledge_cleanup
    end

    private

    def ensure_chat_ring_workspace
      ChatRing::KnowledgeBase.for_account!(self)
    end

    def prepare_chat_ring_knowledge_cleanup
      @chat_ring_knowledge_cleanup_ids = ChatRing::Knowledge::ProviderCleanupScheduler
                                         .prepare_account_deletion!(account_id: id).map(&:id)
    end

    def enqueue_chat_ring_knowledge_cleanup
      ChatRing::Knowledge::ProviderCleanupScheduler.enqueue!(@chat_ring_knowledge_cleanup_ids)
    end
  end
end
# rubocop:enable Style/ClassAndModuleChildren
