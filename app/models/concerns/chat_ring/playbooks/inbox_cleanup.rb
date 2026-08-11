module ChatRing::Playbooks::InboxCleanup
  extend ActiveSupport::Concern

  included do
    before_destroy :destroy_chat_ring_playbook_runtime_records, prepend: true
  end

  private

  # Native Inbox deletion cascades through Playbooks and immutable versions.
  # Runtime executions intentionally restrict ordinary version deletion, so
  # remove only this Inbox's subordinate runtime records before that cascade.
  def destroy_chat_ring_playbook_runtime_records
    workspace = account.chat_ring_workspace
    return unless workspace

    execution_ids = ChatRing::InboxPlaybookExecution
                    .joins(inbox_playbook_version: :inbox_playbook)
                    .where(
                      workspace_id: workspace.id,
                      chat_ring_inbox_playbooks: { chatwoot_inbox_id: id }
                    )
                    .select(:id)
    ChatRing::AiTurn.where(inbox_playbook_execution_id: execution_ids).delete_all
    ChatRing::InboxPlaybookExecution.where(id: execution_ids).delete_all
  end
end
