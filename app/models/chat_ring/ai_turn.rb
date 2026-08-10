class ChatRing::AiTurn < ApplicationRecord
  self.table_name = 'chat_ring_ai_turns'

  DEFAULT_DEADLINE = 2.minutes
  MAX_PROVIDER_ATTEMPTS = 3
  NONTERMINAL_STATUSES = %w[received eligible running awaiting_tool ready_to_commit].freeze

  enum status: {
    received: 0,
    eligible: 1,
    running: 2,
    awaiting_tool: 3,
    ready_to_commit: 4,
    committed: 5,
    ineligible: 6,
    superseded: 7,
    handed_off: 8,
    failed: 9,
    cancelled: 10
  }, _prefix: true

  enum runtime_mode: { internal: 0, external: 1, legacy: 2 }, _prefix: true

  belongs_to :workspace, class_name: 'ChatRing::Workspace', inverse_of: :ai_turns
  belongs_to :conversation, class_name: 'Conversation', foreign_key: :chatwoot_conversation_id, inverse_of: false
  belongs_to :trigger_message, class_name: 'Message', inverse_of: false
  belongs_to :inbox_assistant_binding,
             class_name: 'ChatRing::InboxAssistantBinding',
             inverse_of: :ai_turns
  belongs_to :assistant, class_name: 'ChatRing::Assistant', inverse_of: :ai_turns
  belongs_to :assistant_version, class_name: 'ChatRing::AssistantVersion', inverse_of: :ai_turns
  belongs_to :expected_agent_bot, class_name: 'AgentBot', inverse_of: false
  belongs_to :knowledge_index, class_name: 'ChatRing::KnowledgeIndex', optional: true
  has_many :attempts,
           class_name: 'ChatRing::AiTurnAttempt',
           inverse_of: :ai_turn,
           dependent: :destroy
  has_many :evidence,
           -> { order(:position) },
           class_name: 'ChatRing::AiTurnEvidence',
           inverse_of: :ai_turn,
           dependent: :destroy
  has_one :outbound_commit,
          class_name: 'ChatRing::OutboundCommit',
          inverse_of: :ai_turn,
          dependent: :destroy

  scope :nonterminal, -> { where(status: statuses.values_at(*NONTERMINAL_STATUSES)) }
  scope :recovery_due, lambda { |now = Time.current|
    nonterminal.where(
      '(status = :ready_to_commit) OR (deadline_at <= :now) OR (status IN (:queued) AND updated_at <= :stale_before)',
      ready_to_commit: statuses.fetch('ready_to_commit'),
      queued: statuses.values_at('received', 'eligible'),
      now: now,
      stale_before: now - 1.minute
    )
  }

  validates :binding_version, numericality: { only_integer: true, greater_than: 0 }
  validates :deadline_at, presence: true
  validates :context_digest, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
  validate :decision_payload_shape
  validate :context_metadata_shape
  validate :native_handling_snapshot_shape
  validate :conversation_ownership_matches
  validate :trigger_message_matches
  validate :binding_ownership_matches
  validate :assistant_snapshot_matches
  validate :expected_agent_bot_matches

  attr_readonly :workspace_id,
                :chatwoot_conversation_id,
                :trigger_message_id,
                :inbox_assistant_binding_id,
                :binding_version,
                :assistant_id,
                :assistant_version_id,
                :expected_agent_bot_id,
                :runtime_mode,
                :native_handling_snapshot,
                :deadline_at

  def fail_running_attempts!(failure_code)
    attempts.status_running.find_each do |attempt|
      attempt.update!(status: :failed, failure_code: failure_code, completed_at: Time.current)
    end
  end

  private

  def conversation_ownership_matches
    return if workspace.blank? || conversation.blank?

    errors.add(:conversation, 'must belong to the selected Workspace Account') unless conversation.account_id == workspace.chatwoot_account_id
  end

  def trigger_message_matches
    return if trigger_message.blank? || conversation.blank?

    errors.add(:trigger_message, 'must belong to the selected Conversation') unless trigger_message.conversation_id == chatwoot_conversation_id
  end

  def binding_ownership_matches
    return if workspace.blank? || inbox_assistant_binding.blank?

    errors.add(:inbox_assistant_binding, 'must belong to the selected Workspace') unless inbox_assistant_binding.workspace_id == workspace_id
  end

  def assistant_snapshot_matches
    return if assistant.blank? || assistant_version.blank? || inbox_assistant_binding.blank?

    errors.add(:assistant, 'must match the Inbox binding') unless assistant_id == inbox_assistant_binding.assistant_id
    errors.add(:assistant_version, 'must belong to the selected Assistant') unless assistant_version.assistant_id == assistant_id
  end

  def expected_agent_bot_matches
    return if expected_agent_bot.blank? || workspace.blank?
    return if expected_agent_bot.account_id == workspace.chatwoot_account_id

    errors.add(:expected_agent_bot, 'must be account-owned by the selected Workspace Account')
  end

  def decision_payload_shape
    errors.add(:decision_payload, 'must be an object') unless decision_payload.is_a?(Hash)
  end

  def context_metadata_shape
    errors.add(:context_metadata, 'must be an object') unless context_metadata.is_a?(Hash)
  end

  def native_handling_snapshot_shape
    return if native_handling_snapshot.is_a?(Hash)

    errors.add(:native_handling_snapshot, 'must be an object')
  end
end
