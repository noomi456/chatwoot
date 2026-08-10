class ChatRing::AiTurnRecoverySweepJob < ApplicationJob
  queue_as :scheduled_jobs

  BATCH_SIZE = 100

  def perform
    ChatRing::AiTurn.recovery_due.order(:updated_at, :id).limit(BATCH_SIZE).each do |turn|
      safely_enqueue(turn)
    end
  end

  private

  def safely_enqueue(turn)
    job = ChatRing::AiTurnRecoveryJob.perform_later(turn.id)
    return turn.update!(updated_at: Time.current) if job.respond_to?(:successfully_enqueued?) && job.successfully_enqueued?

    Rails.logger.warn("ChatRing AI recovery enqueue rejected turn_id=#{turn.id}")
  rescue StandardError => e
    Rails.logger.warn("ChatRing AI recovery enqueue failed turn_id=#{turn.id} class=#{e.class.name}")
  end
end
