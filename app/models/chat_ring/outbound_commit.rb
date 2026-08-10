class ChatRing::OutboundCommit < ApplicationRecord
  self.table_name = 'chat_ring_outbound_commits'

  enum status: { pending: 0, committed: 1, rejected: 2 }, _prefix: true
  enum outcome_type: { reply: 0, handoff: 1 }, _prefix: true

  belongs_to :ai_turn, class_name: 'ChatRing::AiTurn', inverse_of: :outbound_commit
  belongs_to :message, class_name: 'Message', foreign_key: :chatwoot_message_id, inverse_of: false, optional: true

  validates :ai_turn_id, uniqueness: true
  validates :idempotency_key, uniqueness: true, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :failure_code, absence: true, if: :status_committed?
  validates :chatwoot_message_id, presence: true, if: -> { status_committed? && outcome_type_reply? }
  validates :chatwoot_message_id, absence: true, if: :outcome_type_handoff?

  attr_readonly :ai_turn_id, :idempotency_key, :outcome_type
end
