class ChatRing::NativeHandlingCompletion < ApplicationRecord
  self.table_name = 'chat_ring_native_handling_completions'

  belongs_to :trigger_message, class_name: 'Message', inverse_of: false
  belongs_to :ai_turn, class_name: 'ChatRing::AiTurn', optional: true, inverse_of: false

  validate :snapshots_are_objects

  after_update_commit :enqueue_released_turn, if: :saved_change_to_released_at?

  private

  def snapshots_are_objects
    errors.add(:template_snapshot, 'must be an object') unless template_snapshot.is_a?(Hash)
    errors.add(:automation_snapshot, 'must be an object') unless automation_snapshot.is_a?(Hash)
  end

  def enqueue_released_turn
    return unless ai_turn&.status_received?

    job = ChatRing::AiTurnJob.perform_later(ai_turn_id)
    ai_turn.update!(failure_code: 'turn_enqueue_failed') unless job&.successfully_enqueued?
  end
end
