class ChatRing::Knowledge::LifecycleReconciliationJob < ApplicationJob
  queue_as :low

  def perform
    return unless ENV['CHATRING_KNOWLEDGE_LIFECYCLE_RECONCILIATION_ENABLED'] == 'true'

    ChatRing::Knowledge::FileSourceReconciler.call
    ChatRing::Knowledge::AbandonmentService.abandon_overdue_evaluation_failures!
    ChatRing::Knowledge::ProviderCleanupReconciler.call
  end
end
