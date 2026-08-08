class ChatRing::AiTurnJob < ApplicationJob
  class CommitEnqueueError < StandardError; end

  queue_as :high

  retry_on ChatRing::Brain::Runner::RetryableError,
           wait: :polynomially_longer,
           attempts: 3 do |job, error|
    ChatRing::Brain::FailureFinalizer.call(job.arguments.first, error.code)
  end
  retry_on CommitEnqueueError, wait: :polynomially_longer, attempts: 3

  def perform(turn_id)
    turn = ChatRing::AiTurn.find_by(id: turn_id)
    return unless turn

    ChatRing::Brain::Runner.new(turn).call
    enqueue_commit!(turn.reload)
  end

  private

  def enqueue_commit!(turn)
    return unless ChatRing::AssistantSpike::PUBLIC_AI_RELEASE_READY
    return unless turn.status_ready_to_commit?

    job = ChatRing::OutboundCommitJob.perform_later(turn.id)
    raise CommitEnqueueError unless job&.successfully_enqueued?
  end
end
