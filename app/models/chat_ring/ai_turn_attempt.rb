class ChatRing::AiTurnAttempt < ApplicationRecord
  self.table_name = 'chat_ring_ai_turn_attempts'

  enum status: { running: 0, succeeded: 1, failed: 2 }, _prefix: true

  belongs_to :ai_turn, class_name: 'ChatRing::AiTurn', inverse_of: :attempts

  validates :attempt_number, numericality: { only_integer: true, greater_than: 0 }
  validates :provider, :model, :request_digest, :started_at, presence: true
  validates :attempt_number, uniqueness: { scope: :ai_turn_id }

  attr_readonly :ai_turn_id, :attempt_number, :provider, :model, :request_digest, :started_at
end
