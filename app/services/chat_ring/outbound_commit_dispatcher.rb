class ChatRing::OutboundCommitDispatcher
  def self.call(turn_id)
    new(turn_id).call
  end

  def initialize(turn_id)
    @turn_id = turn_id
  end

  def call
    return :gate_closed unless ChatRing::AssistantSpike::PUBLIC_AI_RELEASE_READY

    turn = ChatRing::AiTurn.find_by(id: turn_id)
    return :not_ready unless turn&.status_ready_to_commit?

    job = enqueue(turn.id)
    return :enqueued if job.respond_to?(:successfully_enqueued?) && job.successfully_enqueued?

    ChatRing::OutboundCommitJob.perform_now(turn.id)
    :performed_inline
  end

  private

  attr_reader :turn_id

  def enqueue(id)
    ChatRing::OutboundCommitJob.perform_later(id)
  rescue StandardError => e
    Rails.logger.warn("ChatRing outcome enqueue failed; committing inline (#{e.class.name})")
    nil
  end
end
