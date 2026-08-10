module ChatRing::AutomationConflictGuard
  extend ActiveSupport::Concern

  included do
    validate :validate_chat_ring_binding_conflict
  end

  private

  def validate_chat_ring_binding_conflict
    return unless active? && account.present?

    account.with_lock do
      conflicting_inbox = active_chat_ring_inboxes.find do |inbox|
        ChatRing::AutomationConflictClassifier.rule_conflicts?(self, inbox)
      end
      errors.add(:base, 'Automation conflicts with the active ChatRing Assistant') if conflicting_inbox
    end
  end

  def active_chat_ring_inboxes
    workspace = account.chat_ring_workspace
    return Inbox.none if workspace.blank?

    Inbox.where(
      id: workspace.inbox_assistant_bindings.active.select(:chatwoot_inbox_id)
    )
  end
end
