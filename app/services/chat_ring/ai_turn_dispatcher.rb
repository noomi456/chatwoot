class ChatRing::AiTurnDispatcher
  Result = Data.define(:primary_enqueued, :recovery_enqueued)
  RECOVERY_GRACE = 15.seconds

  def self.call(turn)
    new(turn).call
  end

  def initialize(turn)
    @turn = turn
  end

  def call
    Result.new(
      primary_enqueued: safely_enqueue { ChatRing::AiTurnJob.perform_later(turn.id) },
      recovery_enqueued: safely_enqueue { schedule_recovery }
    )
  end

  private

  attr_reader :turn

  def schedule_recovery
    ChatRing::AiTurnRecoveryJob.set(wait_until: turn.deadline_at + RECOVERY_GRACE).perform_later(turn.id)
  end

  def safely_enqueue
    job = yield
    job.present? && job.successfully_enqueued?
  rescue StandardError => e
    Rails.logger.warn("ChatRing AI turn enqueue failed class=#{e.class.name}")
    false
  end
end
