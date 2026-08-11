class ChatRing::InboxPlaybookExecution < ApplicationRecord
  self.table_name = 'chat_ring_inbox_playbook_executions'

  CONTROLLING_STATUSES = %w[active waiting_for_customer paused_for_side_question transitioning].freeze

  enum status: {
    active: 0,
    waiting_for_customer: 1,
    paused_for_side_question: 2,
    transitioning: 3,
    completed: 4,
    stopped: 5,
    handed_off: 6,
    superseded: 7,
    failed: 8
  }, _prefix: true

  belongs_to :workspace, class_name: 'ChatRing::Workspace', inverse_of: :inbox_playbook_executions
  belongs_to :inbox_playbook_version,
             class_name: 'ChatRing::InboxPlaybookVersion',
             inverse_of: :executions
  belongs_to :conversation,
             class_name: 'Conversation',
             foreign_key: :chatwoot_conversation_id,
             inverse_of: false
  belongs_to :last_trigger_message, class_name: 'Message', inverse_of: false, optional: true
  belongs_to :last_outcome_message, class_name: 'Message', inverse_of: false, optional: true
  has_many :ai_turns,
           class_name: 'ChatRing::AiTurn',
           inverse_of: :inbox_playbook_execution,
           dependent: :restrict_with_exception

  scope :controlling, -> { where(status: statuses.values_at(*CONTROLLING_STATUSES)) }

  validates :current_step_id, :started_at, presence: true
  validate :structured_state
  validate :native_scope_matches
  validate :current_step_exists

  attr_readonly :workspace_id, :inbox_playbook_version_id, :chatwoot_conversation_id, :started_at

  def current_step
    Array(inbox_playbook_version.definition['steps']).find { |step| step['id'] == current_step_id }
  end

  private

  def structured_state
    errors.add(:collected_fields, 'must be an object') unless collected_fields.is_a?(Hash)
    errors.add(:field_sources, 'must be an object') unless field_sources.is_a?(Hash)
    errors.add(:transition_history, 'must be an array') unless transition_history.is_a?(Array)
  end

  def native_scope_matches
    return if workspace.blank? || conversation.blank? || inbox_playbook_version.blank?

    playbook = inbox_playbook_version.inbox_playbook
    errors.add(:conversation, 'must belong to the Workspace Account') unless conversation.account_id == workspace.chatwoot_account_id
    errors.add(:inbox_playbook_version, 'must belong to the Workspace') unless playbook.workspace_id == workspace_id
    errors.add(:inbox_playbook_version, 'must belong to the Conversation Inbox') unless playbook.chatwoot_inbox_id == conversation.inbox_id
  end

  def current_step_exists
    return if inbox_playbook_version.blank? || current_step.present?

    errors.add(:current_step_id, 'must identify a step in the pinned Playbook version')
  end
end
