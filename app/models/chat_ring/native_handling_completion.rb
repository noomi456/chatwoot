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

    result = ChatRing::AiTurnDispatcher.call(ai_turn)
    failure_code = if result.primary_enqueued
                     nil
                   elsif result.recovery_enqueued
                     'turn_enqueue_failed_recovery_scheduled'
                   else
                     'turn_enqueue_and_recovery_failed'
                   end
    ai_turn.update!(failure_code: failure_code)
  end
end
